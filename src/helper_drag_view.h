#import <AppKit/AppKit.h>

/// A native file-drag source for the bundled permission helper.
@interface MXHelperDragView : NSView <NSDraggingSource>
@property (nonatomic, copy) NSURL *helperURL;
@end
