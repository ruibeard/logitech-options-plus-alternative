#import "logi_controls.h"
#import <libproc.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>

@implementation MXLogiControls
+ (NSArray<NSString *> *)installationPaths {
    return @[@"/Applications/logioptionsplus.app",
             [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/logioptionsplus.app"],
             @"/Library/Application Support/Logitech.localized/LogiOptionsPlus",
             @"/Library/Application Support/Logitech/LogiOptionsPlus"];
}
+ (BOOL)installed {
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *path in self.installationPaths) {
        if ([path.pathExtension.lowercaseString isEqualToString:@"app"]) {
            NSBundle *bundle = [NSBundle bundleWithPath:path];
            if ([bundle.bundleIdentifier isEqualToString:@"com.logi.optionsplus"] &&
                [manager isExecutableFileAtPath:bundle.executablePath]) return YES;
        } else {
            NSString *executable = [path stringByAppendingPathComponent:@"logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent"];
            if ([manager isExecutableFileAtPath:executable]) return YES;
        }
    }
    return NO;
}
+ (NSArray<NSNumber *> *)agentPIDs {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)bytes + 4096];
    bytes = proc_listpids(PROC_ALL_PIDS, 0, data.mutableBytes, (int)data.length);
    pid_t *pids = data.mutableBytes;
    NSMutableArray *result = [NSMutableArray array];
    NSArray *paths = @[@"/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent",
                      @"/Library/Application Support/Logitech/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent"];
    for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (pids[i] > 0 && proc_pidpath(pids[i], path, sizeof(path)) > 0 &&
            [paths containsObject:[NSString stringWithUTF8String:path]]) [result addObject:@(pids[i])];
    }
    return result;
}
+ (BOOL)running {
    return self.agentPIDs.count > 0 || [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.logi.optionsplus"].count > 0;
}
+ (void)quitOptionsWithCompletion:(void (^)(NSString *error))completion {
    for (NSString *identifier in @[@"com.logi.optionsplus", @"com.logi.cp-dev-mgr"])
        for (NSRunningApplication *application in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier])
            [application terminate];
    // Unload only this login session's agent; login or launching Options+ can start it again.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *bootout = [NSTask new];
        bootout.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
        bootout.arguments = @[@"bootout", [NSString stringWithFormat:@"gui/%u/com.logi.cp-dev-mgr", getuid()]];
        bootout.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        bootout.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSError *launchError = nil;
        if ([bootout launchAndReturnError:&launchError]) [bootout waitUntilExit];
        BOOL denied = NO;
        for (NSNumber *process in self.agentPIDs) {
            // Revalidate the exact executable immediately before signalling a PID.
            if ([self.agentPIDs containsObject:process] && kill(process.intValue, SIGTERM) != 0 && errno != ESRCH) denied = YES;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            completion(denied ? @"macOS did not allow Options+ to quit. Quit it from Options+ or Activity Monitor." :
                       self.running ? @"Options+ is still running or restarted automatically. Quit it in Options+ and disable its background activity in System Settings if needed." : nil);
        });
    });
}

+ (BOOL)openUninstallerWithError:(NSError **)error {
    NSMutableArray<NSString *> *roots = [self.installationPaths mutableCopy];
    [roots addObjectsFromArray:@[@"/Applications/Utilities", @"/Library/Application Support/LogiOptionsPlus"]];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:[NSURL fileURLWithPath:root]
                                         includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *url in enumerator) {
            if (enumerator.level > 7) { [enumerator skipDescendants]; continue; }
            NSString *name = url.lastPathComponent.lowercaseString;
            BOOL optionsName = [name containsString:@"options"] || [root containsString:@"LogiOptionsPlus"] || [root.lowercaseString containsString:@"logioptionsplus.app"];
            if ([url.pathExtension.lowercaseString isEqualToString:@"app"] && [name containsString:@"uninstall"] && optionsName) {
                if ([NSWorkspace.sharedWorkspace openURL:url]) return YES;
            }
        }
    }
    for (NSString *root in self.installationPaths) {
        NSString *path = [root stringByAppendingPathComponent:@"logioptionsplus_agent.app/Contents/Frameworks/logioptionsplus_updater.app"];
        if (![manager fileExistsAtPath:path]) continue;
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.arguments = @[@"--uninstall"];
        configuration.createsNewApplicationInstance = YES;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:path] configuration:configuration
                                      completionHandler:^(NSRunningApplication *application, NSError *launchError) {
            (void)application;
            if (launchError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [NSAlert new];
                    alert.messageText = @"Could not open the Options+ uninstaller";
                    alert.informativeText = launchError.localizedDescription;
                    [alert runModal];
                });
            }
        }];
        return YES;
    }
    if (error) *error = [NSError errorWithDomain:@"MXLogiControls" code:1 userInfo:@{NSLocalizedDescriptionKey:
        @"The official Options+ uninstaller was not found. Open Options+ and use its uninstall option, or reinstall Options+ to restore its uninstaller."}];
    return NO;
}
@end
