#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import "import_options.h"
#import "storage.h"

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static NSString *WriteDatabase(NSString *directory, NSString *name, NSData *json) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    sqlite3 *database = NULL;
    Check(sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK, @"create fixture");
    Check(sqlite3_exec(database, "CREATE TABLE data (_id INTEGER PRIMARY KEY, file BLOB)", NULL, NULL, NULL) == SQLITE_OK, @"create fixture table");
    sqlite3_stmt *statement = NULL;
    Check(sqlite3_prepare_v2(database, "INSERT INTO data (file) VALUES (?)", -1, &statement, NULL) == SQLITE_OK, @"prepare fixture");
    sqlite3_bind_blob(statement, 1, json.bytes, (int)json.length, SQLITE_TRANSIENT);
    Check(sqlite3_step(statement) == SQLITE_DONE, @"write fixture");
    sqlite3_finalize(statement);
    sqlite3_close(database);
    return path;
}
static NSDictionary *Assignment(NSString *slot, NSDictionary *macro, NSString *cardID) {
    return @{@"slotId": [@"mx-master-3-6b023_" stringByAppendingString:slot],
             @"card": @{@"attribute": @"MACRO_PLAYBACK", @"id": cardID, @"macro": macro}};
}
static NSDictionary *Root(NSArray *assignments, NSString *profileName) {
    return @{@"profile_keys": @[@"profile-test"], @"profile-test":
        @{@"name": profileName, @"applicationId": @"test", @"activeForApplication": @YES, @"assignments": assignments}};
}
static NSString *Fixture(NSString *directory, NSString *name, NSDictionary *root) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:root options:0 error:&error];
    Check(json != nil && error == nil, @"serialize fixture");
    return WriteDatabase(directory, name, json);
}
int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        Check([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL], @"create temp directory");
        NSDictionary *current = @{@"unknown": @{@"keep": @YES}, @"buttons": @{
            @"middle": @{@"mode": @2, @"keyCode": @12, @"modifiers": @0},
            @"thumb": @{@"mode": @0, @"keyCode": @0, @"modifiers": @0}}};
        NSDictionary *currentCopy = [current copy];
        NSDictionary *capture = Assignment(@"c195", @{@"type": @"SCREEN_CAPTURE", @"actionName": @"screencapture_default", @"screenCapture": @{@"areatocapture": @"CAPTURE_REGION", @"destinationfolder": @"CAPTURE_FILE"}}, @"card_global_presets_osx_screen_capture");
        NSDictionary *keystroke = Assignment(@"c82", @{@"type": @"KEYSTROKE", @"keystroke": @{@"code": @4, @"modifiers": @[@227]}}, @"card_global_presets_keystroke");
        NSDictionary *back = Assignment(@"c83", @{@"type": @"MOUSE", @"mouse": @{@"action": @"OSX_GESTURE_BACK"}}, @"mouse_back");
        NSDictionary *forward = Assignment(@"c86", @{@"type": @"MOUSE", @"mouse": @{@"action": @"OSX_GESTURE_FORWARD"}}, @"mouse_forward");
        NSDictionary *top = Assignment(@"c196", @{}, @"card_global_presets_mode_shift");
        NSString *path = Fixture(directory, @"valid.db", Root(@[capture, keystroke, back, forward, top], @"PROFILE_NAME_DEFAULT"));
        NSData *before = [NSData dataWithContentsOfFile:path];
        NSError *error = nil;
        NSDictionary *result = MXReadOptionsImport(path, current, &error);
        Check(result != nil && error == nil, @"valid import succeeds");
        NSDictionary *settings = result[@"settings"];
        Check([settings[@"buttons"][@"thumb"][@"mode"] intValue] == 1, @"capture is shortcut");
        Check([settings[@"buttons"][@"thumb"][@"keyCode"] intValue] == 21, @"region capture uses Mac 4");
        Check([settings[@"buttons"][@"thumb"][@"modifiers"] unsignedLongLongValue] == ((1ULL << 20) | (1ULL << 17)), @"region capture uses command shift");
        Check([settings[@"buttons"][@"middle"][@"keyCode"] intValue] == 0, @"HID A maps to Mac A");
        Check([settings[@"buttons"][@"middle"][@"modifiers"] unsignedLongLongValue] == (1ULL << 20), @"HID command maps to Mac flag");
        Check([settings[@"buttons"][@"back"][@"keyCode"] intValue] == 33, @"back maps to command left bracket");
        Check([settings[@"buttons"][@"forward"][@"keyCode"] intValue] == 30, @"forward maps to command right bracket");
        Check([settings[@"buttons"][@"top"][@"mode"] intValue] == 0, @"mode shift remains native");
        Check([settings[@"unknown"] isEqual:current[@"unknown"]], @"unknown settings preserved");
        Check([result[@"importedCount"] intValue] == 5, @"counts imported assignments");
        Check([before isEqual:[NSData dataWithContentsOfFile:path]], @"source database byte identical");
        Check([current isEqual:currentCopy], @"current settings unchanged");
        NSDictionary *customThumb = Assignment(@"c195", @{@"type": @"KEYSTROKE", @"keystroke": @{@"code": @4, @"modifiers": @[@224, @227]}}, @"custom_thumb");
        path = Fixture(directory, @"storage-roundtrip.db", Root(@[customThumb], @"PROFILE_NAME_DEFAULT"));
        result = MXReadOptionsImport(path, current, &error);
        Check(result != nil, @"custom thumb imports");
        char settingsPath[PATH_MAX], storageError[256];
        MXConfig config;
        Check(mx_path(settingsPath, "settings.plist"), @"resolve isolated settings path");
        Check(mx_write_plist(settingsPath, (__bridge CFDictionaryRef)result[@"settings"]), @"write merged imported settings");
        Check(mx_load_config(&config, storageError, sizeof(storageError)), @"load imported settings through production storage");
        Check(config.buttons[3].action == MX_SHORTCUT && config.buttons[3].key == 0 && config.buttons[3].modifiers == ((1ULL << 18) | (1ULL << 20)), @"custom thumb HID A and control command round trip through production storage");
        NSDictionary *unsupported = Assignment(@"c82", @{@"type": @"KEYSTROKE", @"keystroke": @{@"code": @65535, @"modifiers": @[]}}, @"card_global_presets_keystroke");
        path = Fixture(directory, @"unsupported.db", Root(@[unsupported, capture], @"PROFILE_NAME_DEFAULT"));
        result = MXReadOptionsImport(path, current, &error);
        Check(result != nil, @"unsupported assignment permits other imports");
        Check([result[@"settings"][@"buttons"][@"middle"] isEqual:current[@"buttons"][@"middle"]], @"unsupported HID preserves existing binding");
        Check([result[@"warnings"] count] > 0, @"unsupported HID produces warning");
        NSDictionary *nativeMiddle = Assignment(@"c82", @{@"type": @"MOUSE", @"mouse": @{@"action": @"BUTTON", @"hidUsage": @3}}, @"middle_native");
        path = Fixture(directory, @"native.db", Root(@[nativeMiddle], @"PROFILE_NAME_DEFAULT"));
        result = MXReadOptionsImport(path, current, &error);
        Check(result != nil && [result[@"settings"][@"buttons"][@"middle"][@"mode"] intValue] == 0, @"middle mouse click remains native");
        path = WriteDatabase(directory, @"corrupt.db", [@"{invalid JSON" dataUsingEncoding:NSUTF8StringEncoding]);
        error = nil;
        Check(MXReadOptionsImport(path, current, &error) == nil && error != nil, @"corrupt JSON fails with error");
        path = [directory stringByAppendingPathComponent:@"missing.db"];
        error = nil;
        Check(MXReadOptionsImport(path, current, &error) == nil && error != nil, @"missing database fails");
        Check(![[NSFileManager defaultManager] fileExistsAtPath:path], @"missing database is never created");
        path = Fixture(directory, @"application.db", Root(@[capture], @"Some application"));
        error = nil;
        result = MXReadOptionsImport(path, current, &error);
        Check(result == nil || [result[@"importedCount"] intValue] == 0, @"application profile never used as global fallback");
        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
        puts("Options+ import tests passed");
    }
    return 0;
}
