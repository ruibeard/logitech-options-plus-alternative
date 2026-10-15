#import "helper_drag_view.h"

@interface MXHelperDragView ()
@property (strong) NSImage *helperIcon;
@property NSPoint mouseDownPoint;
@property BOOL trackingMouse;
@end

@implementation MXHelperDragView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.helperURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Library/LoginItems/MX Mouse Helper.app"];
        self.toolTip = @"Drag MX Mouse Helper into the permission list in System Settings.";
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = @"MX Mouse Helper";
        self.accessibilityHelp = @"Drag this app into the Accessibility or Input Monitoring list in System Settings.";
    }
    return self;
}

- (void)setHelperURL:(NSURL *)helperURL {
    _helperURL = [helperURL copy];
    self.helperIcon = helperURL.isFileURL ? [[NSWorkspace.sharedWorkspace iconForFile:helperURL.path] copy] : nil;
    self.helperIcon.size = NSMakeSize(32, 32);
    self.needsDisplay = YES;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor]; }
- (NSSize)intrinsicContentSize { return NSMakeSize(240, 58); }

- (NSRect)iconRect {
    return NSMakeRect(12, floor((NSHeight(self.bounds) - 32) / 2), 32, 32);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:8 yRadius:8];
    [NSColor.controlBackgroundColor setFill];
    [background fill];
    [[NSColor.separatorColor colorWithAlphaComponent:0.65] setStroke];
    background.lineWidth = 1;
    [background stroke];
    [self.helperIcon drawInRect:self.iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];

    CGFloat textX = NSMaxX(self.iconRect) + 10;
    CGFloat textY = floor((NSHeight(self.bounds) - 32) / 2);
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    [@"MX Mouse Helper" drawInRect:NSMakeRect(textX, textY, MAX(0, NSWidth(self.bounds) - textX - 12), 16)
                   withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:NSColor.labelColor, NSParagraphStyleAttributeName:paragraph}];
    [@"Drag into System Settings" drawInRect:NSMakeRect(textX, textY + 18, MAX(0, NSWidth(self.bounds) - textX - 12), 15)
                            withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11.5], NSForegroundColorAttributeName:NSColor.secondaryLabelColor, NSParagraphStyleAttributeName:paragraph}];
}

- (void)mouseDown:(NSEvent *)event {
    self.mouseDownPoint = [self convertPoint:event.locationInWindow fromView:nil];
    self.trackingMouse = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.trackingMouse || !self.helperURL.isFileURL || !self.helperIcon) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat deltaX = point.x - self.mouseDownPoint.x;
    CGFloat deltaY = point.y - self.mouseDownPoint.y;
    if (deltaX * deltaX + deltaY * deltaY < 16) return;
    self.trackingMouse = NO;
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:self.helperURL];
    [item setDraggingFrame:self.iconRect contents:self.helperIcon];
    [self beginDraggingSessionWithItems:@[item] event:event source:self];
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    self.trackingMouse = NO;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    (void)context;
    return NSDragOperationCopy;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session {
    (void)session;
    return YES;
}

@end
