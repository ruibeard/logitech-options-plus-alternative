#import "import_options.h"
#import <sqlite3.h>

static NSDictionary *MXDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static BOOL MXEqual(id value, NSString *expected) { return [value isKindOfClass:NSString.class] && [value isEqual:expected]; }
static NSDictionary *MXFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"MXOptionsImport" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
static int MXMacKey(NSInteger usage) {
    static const int letters[] = {0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6};
    static const int digits[] = {18,19,20,21,23,22,26,28,25,29};
    static const int function[] = {122,120,99,118,96,97,98,100,101,109,103,111};
    if (usage >= 4 && usage <= 29) return letters[usage-4];
    if (usage >= 30 && usage <= 39) return digits[usage-30];
    if (usage >= 58 && usage <= 69) return function[usage-58];
    switch (usage) {
        case 40:return 36; case 41:return 53; case 42:return 51; case 43:return 48; case 44:return 49;
        case 45:return 27; case 46:return 24; case 47:return 33; case 48:return 30; case 49:return 42;
        case 51:return 41; case 52:return 39; case 53:return 50; case 54:return 43; case 55:return 47;
        case 56:return 44; case 57:return 57; case 73:return 114; case 74:return 115; case 75:return 116;
        case 76:return 117; case 77:return 119; case 78:return 121; case 79:return 124; case 80:return 123;
        case 81:return 125; case 82:return 126;
        case 104:return 105; case 105:return 107; case 106:return 113; case 107:return 106;
        case 108:return 64; case 109:return 79; case 110:return 80; case 111:return 90;
        case 83:return 71; case 84:return 75; case 85:return 67; case 86:return 78; case 87:return 69;
        case 88:return 76; case 89:return 83; case 90:return 84; case 91:return 85; case 92:return 86;
        case 93:return 87; case 94:return 88; case 95:return 89; case 96:return 91; case 97:return 92;
        case 98:return 82; case 99:return 65; case 103:return 81;
        default:return -1;
    }
}
static NSDictionary *MXBinding(NSDictionary *card, NSString *button) {
    NSDictionary *macro=MXDict(card[@"macro"]), *mouse=MXDict(macro[@"mouse"]);
    int key=-1; NSUInteger flags=0;
    if (MXEqual(card[@"id"], @"card_global_presets_mode_shift") && [button isEqual:@"top"])
        return @{@"mode":@0,@"keyCode":@0,@"modifiers":@0};
    if (MXEqual(macro[@"type"],@"MOUSE")) {
        if (MXEqual(mouse[@"action"],@"BUTTON") && [mouse[@"hidUsage"] isEqual:@3] && [button isEqual:@"middle"])
            return @{@"mode":@0,@"keyCode":@0,@"modifiers":@0};
        if (MXEqual(mouse[@"action"],@"OSX_GESTURE_BACK")) {key=33;flags=1<<20;}
        if (MXEqual(mouse[@"action"],@"OSX_GESTURE_FORWARD")) {key=30;flags=1<<20;}
    } else if (MXEqual(macro[@"type"],@"SCREEN_CAPTURE")) {
        NSDictionary *capture=MXDict(macro[@"screenCapture"]);
        if (MXEqual(capture[@"areatocapture"],@"CAPTURE_REGION") && MXEqual(capture[@"destinationfolder"],@"CAPTURE_FILE")) {key=21;flags=(1<<20)|(1<<17);}
    } else if (MXEqual(macro[@"type"],@"KEYSTROKE")) {
        NSDictionary *stroke=MXDict(macro[@"keystroke"]); id code=stroke[@"code"], modifiers=stroke[@"modifiers"];
        if (![code isKindOfClass:NSNumber.class] || ![modifiers isKindOfClass:NSArray.class] || [code doubleValue] != [code integerValue]) return nil;
        key=MXMacKey([code integerValue]);
        for (id modifier in modifiers) {
            if (![modifier isKindOfClass:NSNumber.class] || [modifier doubleValue] != [modifier integerValue]) return nil;
            switch ([modifier integerValue]) {
                case 224:case 228:flags|=1<<18;break;
                case 225:case 229:flags|=1<<17;break;
                case 226:case 230:flags|=1<<19;break;
                case 227:case 231:flags|=1<<20;break;
                default:return nil;
            }
        }
    }
    return key < 0 ? nil : @{@"mode":@1,@"keyCode":@(key),@"modifiers":@(flags)};
}
NSDictionary *MXReadOptionsImport(NSString *databasePath, NSDictionary *current, NSError **error) {
    if (error) *error=nil;
    sqlite3 *database=NULL; sqlite3_stmt *statement=NULL;
    int status=sqlite3_open_v2(databasePath.fileSystemRepresentation,&database,SQLITE_OPEN_READONLY,NULL);
    if (status!=SQLITE_OK) {if(database)sqlite3_close(database);return MXFail(error,@"Could not open the Options+ settings database for reading.");}
    sqlite3_busy_timeout(database,500);
    status=sqlite3_prepare_v2(database,"SELECT CASE WHEN length(file) <= 33554432 THEN file ELSE NULL END FROM data ORDER BY _id DESC LIMIT 1",-1,&statement,NULL);
    NSData *data=nil;
    if (status==SQLITE_OK && sqlite3_step(statement)==SQLITE_ROW) {
        int size=sqlite3_column_bytes(statement,0);
        if(size>0 && size<=32*1024*1024) data=[NSData dataWithBytes:sqlite3_column_blob(statement,0) length:(NSUInteger)size];
    }
    if(statement)sqlite3_finalize(statement);sqlite3_close(database);
    if(!data)return MXFail(error,@"The Options+ database has no readable settings document, or it exceeds the 32 MiB limit.");
    id parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(![parsed isKindOfClass:NSDictionary.class])return MXFail(error,@"The Options+ settings document is not a valid JSON object.");
    NSDictionary *root=parsed,*profile=nil;
    id keys=root[@"profile_keys"];
    if([keys isKindOfClass:NSArray.class])for(id profileKey in keys) {
        if(![profileKey isKindOfClass:NSString.class])continue;
        NSDictionary *candidate=MXDict(root[profileKey]);
        if(!MXEqual(candidate[@"name"],@"PROFILE_NAME_DEFAULT"))continue;
        id assignments=candidate[@"assignments"];
        if(![assignments isKindOfClass:NSArray.class])continue;
        for(id item in assignments) {
            id slot=MXDict(item)[@"slotId"];
            if([slot isKindOfClass:NSString.class] && [slot hasPrefix:@"mx-master-3-6b023_"]) {profile=candidate;break;}
        }
        if(profile)break;
    }
    if(!profile)return MXFail(error,@"No global default profile for the supported MX Master 3 was found in Options+.");
    NSMutableDictionary *settings=[MXDict(current) mutableCopy],*buttons=[MXDict(settings[@"buttons"]) mutableCopy];
    NSMutableArray *warnings=[NSMutableArray new]; NSUInteger count=0;
    NSDictionary *slots=@{@"c82":@"middle",@"c83":@"back",@"c86":@"forward",@"c195":@"thumb",@"c196":@"top"};
    for(id item in profile[@"assignments"]) {
        NSDictionary *assignment=MXDict(item); id slot=assignment[@"slotId"];
        if(![slot isKindOfClass:NSString.class] || ![slot hasPrefix:@"mx-master-3-6b023_"])continue;
        NSString *suffix=[slot substringFromIndex:[@"mx-master-3-6b023_" length]];
        NSDictionary *card=MXDict(assignment[@"card"]); NSString *button=slots[suffix];
        if(button) {
            NSDictionary *binding=MXBinding(card,button);
            if(binding){buttons[button]=binding;count++;}
            else [warnings addObject:[NSString stringWithFormat:@"%@ button: unsupported Options+ action; current binding retained.",button.capitalizedString]];
        } else if([suffix isEqual:@"mouse_scroll_wheel_settings"] || [suffix isEqual:@"mouse_thumb_wheel_settings"]) {
            BOOL vertical=[suffix isEqual:@"mouse_scroll_wheel_settings"];
            NSDictionary *wheel=MXDict(card[vertical?@"mouseScrollWheelSettings":@"mouseThumbWheelSettings"]);
            if(MXEqual(wheel[@"dir"],@"STANDARD")){settings[vertical?@"invertVertical":@"invertHorizontal"]=@NO;count++;}
            else if(wheel[@"dir"]) [warnings addObject:@"Unrecognized wheel direction; current direction retained."];
            if(wheel[@"smartshift"]) [warnings addObject:@"Options+ SmartShift settings are not compatible; current wheel mode retained."];
            if(wheel[@"isSmooth"]) [warnings addObject:@"Per-wheel smoothing cannot be mapped to the shared smoothing setting; current setting retained."];
            if(wheel[@"speed"] || wheel[@"sensitivity"]) [warnings addObject:@"Options+ wheel speed cannot be converted reliably; current speed retained."];
        } else if([suffix isEqual:@"mouse_settings"]) {
            [warnings addObject:@"Options+ pointer-speed levels do not specify a verified DPI value; current DPI retained."];
        }
    }
    settings[@"buttons"]=buttons;
    return @{@"settings":settings,@"summary":[NSString stringWithFormat:@"Imported %lu supported settings from the Options+ global MX Master 3 profile.",(unsigned long)count],@"warnings":warnings,@"importedCount":@(count)};
}
