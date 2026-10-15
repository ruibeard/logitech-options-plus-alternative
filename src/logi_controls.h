#import <AppKit/AppKit.h>

@interface MXLogiControls : NSObject
+ (BOOL)installed;
+ (BOOL)running;
+ (void)quitOptionsWithCompletion:(void (^)(NSString *error))completion;
+ (BOOL)openUninstallerWithError:(NSError **)error;
@end
