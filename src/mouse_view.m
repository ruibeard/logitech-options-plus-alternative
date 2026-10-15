#import "mouse_view.h"

static NSColor *MXGray(CGFloat value) {
    return [NSColor colorWithCalibratedWhite:value alpha:1];
}

static void MXFill(NSBezierPath *path, CGFloat light, CGFloat dark, CGFloat angle) {
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:MXGray(light) endingColor:MXGray(dark)];
    [gradient drawInBezierPath:path angle:angle];
}

static NSBezierPath *MXRound(CGFloat x, CGFloat y, CGFloat width, CGFloat height, CGFloat radius) {
    return [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,y,width,height) xRadius:radius yRadius:radius];
}

@interface MXMouseView ()
@property (strong) NSImage *mouseImage;
@property (strong) NSImage *compactImage;
@end

@implementation MXMouseView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        NSString *compactPath=[NSBundle.mainBundle pathForResource:@"m705" ofType:@"png"];
        if(compactPath) self.compactImage=[[NSImage alloc] initWithContentsOfFile:compactPath];
        NSString *path = [NSBundle.mainBundle pathForResource:@"mx-master-3" ofType:@"png"];
        if (path) {
            self.mouseImage = [[NSImage alloc] initWithContentsOfFile:path];
            self.mouseImage.size = NSMakeSize(636, 1024);
        }
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (self.compactMouse && self.compactImage) {
        NSSize source=self.compactImage.size;
        CGFloat scale=MIN(self.bounds.size.width/source.width,self.bounds.size.height/source.height);
        NSRect target=NSMakeRect((self.bounds.size.width-source.width*scale)/2,
            (self.bounds.size.height-source.height*scale)/2,source.width*scale,source.height*scale);
        [self.compactImage drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
            fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
        return;
    }
    if (self.compactMouse) {
        [NSGraphicsContext saveGraphicsState];
        CGFloat scale=MIN(self.bounds.size.width/270, self.bounds.size.height/430);
        NSAffineTransform *fit=[NSAffineTransform transform];
        [fit translateXBy:(self.bounds.size.width-270*scale)/2 yBy:(self.bounds.size.height-430*scale)/2];
        [fit scaleBy:scale]; [fit concat];
        // Original compact ergonomic silhouette, independent of bundled artwork.
        NSBezierPath *body=[NSBezierPath bezierPath];
        [body moveToPoint:NSMakePoint(140,45)];
        [body curveToPoint:NSMakePoint(231,170) controlPoint1:NSMakePoint(200,45) controlPoint2:NSMakePoint(231,99)];
        [body curveToPoint:NSMakePoint(201,365) controlPoint1:NSMakePoint(240,251) controlPoint2:NSMakePoint(238,335)];
        [body curveToPoint:NSMakePoint(63,349) controlPoint1:NSMakePoint(166,400) controlPoint2:NSMakePoint(85,393)];
        [body curveToPoint:NSMakePoint(52,210) controlPoint1:NSMakePoint(32,311) controlPoint2:NSMakePoint(39,251)];
        [body curveToPoint:NSMakePoint(140,45) controlPoint1:NSMakePoint(62,112) controlPoint2:NSMakePoint(88,45)];
        [body closePath]; MXFill(body,0.36,0.12,0);
        [MXGray(0.09) setStroke]; body.lineWidth=2; [body stroke];
        NSBezierPath *seam=[NSBezierPath bezierPath];
        [seam moveToPoint:NSMakePoint(141,49)]; [seam lineToPoint:NSMakePoint(141,189)];
        [seam moveToPoint:NSMakePoint(62,185)]; [seam curveToPoint:NSMakePoint(230,185) controlPoint1:NSMakePoint(120,211) controlPoint2:NSMakePoint(182,210)];
        seam.lineWidth=2; [seam stroke];
        MXFill(MXRound(128,91,27,65,11),0.77,0.35,0);
        MXFill(MXRound(54,212,17,35,6),0.45,0.22,0);
        MXFill(MXRound(47,255,17,35,6),0.42,0.18,0);
        MXFill(MXRound(46,305,30,30,10),0.3,0.14,0);
        [NSGraphicsContext restoreGraphicsState];
        return;
    }
    if (self.mouseImage) {
        // Preserve the original PNG's proportions and transparent silhouette.
        NSRect source = NSMakeRect(0, 0, 636, 1024);
        CGFloat factor = MIN(self.bounds.size.width / source.size.width, self.bounds.size.height / source.size.height);
        NSSize size = NSMakeSize(source.size.width * factor, source.size.height * factor);
        NSRect target = NSMakeRect((self.bounds.size.width - size.width) / 2, (self.bounds.size.height - size.height) / 2, size.width, size.height);
        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithCalibratedWhite:0 alpha:0.20];
        shadow.shadowBlurRadius = 18;
        shadow.shadowOffset = NSMakeSize(3, -14);
        [shadow set];
        [self.mouseImage drawInRect:target fromRect:source operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
        return;
    }
    [NSGraphicsContext saveGraphicsState];
    CGFloat scale = MIN(self.bounds.size.width / 300.0, self.bounds.size.height / 440.0);
    NSAffineTransform *fit = [NSAffineTransform transform];
    [fit translateXBy:(self.bounds.size.width - 300 * scale) / 2 yBy:(self.bounds.size.height - 440 * scale) / 2];
    [fit scaleBy:scale];
    [fit concat];

    // A broad sculpted thumb rest and a tall, slightly angled upper shell.
    NSBezierPath *body = [NSBezierPath bezierPath];
    [body moveToPoint:NSMakePoint(165, 32)];
    [body curveToPoint:NSMakePoint(237, 102) controlPoint1:NSMakePoint(202, 24) controlPoint2:NSMakePoint(225, 61)];
    [body curveToPoint:NSMakePoint(261, 290) controlPoint1:NSMakePoint(251, 147) controlPoint2:NSMakePoint(274, 239)];
    [body curveToPoint:NSMakePoint(202, 398) controlPoint1:NSMakePoint(252, 348) controlPoint2:NSMakePoint(232, 386)];
    [body curveToPoint:NSMakePoint(76, 367) controlPoint1:NSMakePoint(173, 413) controlPoint2:NSMakePoint(110, 391)];
    [body curveToPoint:NSMakePoint(38, 296) controlPoint1:NSMakePoint(48, 346) controlPoint2:NSMakePoint(29, 320)];
    [body curveToPoint:NSMakePoint(92, 191) controlPoint1:NSMakePoint(45, 268) controlPoint2:NSMakePoint(74, 227)];
    [body curveToPoint:NSMakePoint(165, 32) controlPoint1:NSMakePoint(111, 149) controlPoint2:NSMakePoint(123, 43)];
    [body closePath];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithCalibratedWhite:0 alpha:0.18];
    shadow.shadowBlurRadius = 17;
    shadow.shadowOffset = NSMakeSize(1, -12);
    [shadow set];
    [MXGray(0.10) setFill]; [body fill];
    [NSGraphicsContext restoreGraphicsState];
    MXFill(body, 0.27, 0.08, 30);
    [MXGray(0.06) setStroke]; body.lineWidth = 1.3; [body stroke];

    NSBezierPath *thumb = [NSBezierPath bezierPath];
    [thumb moveToPoint:NSMakePoint(101, 185)];
    [thumb curveToPoint:NSMakePoint(67, 302) controlPoint1:NSMakePoint(100, 224) controlPoint2:NSMakePoint(74, 267)];
    [thumb curveToPoint:NSMakePoint(93, 351) controlPoint1:NSMakePoint(63, 324) controlPoint2:NSMakePoint(71, 340)];
    [thumb curveToPoint:NSMakePoint(170, 374) controlPoint1:NSMakePoint(113, 362) controlPoint2:NSMakePoint(144, 369)];
    [thumb curveToPoint:NSMakePoint(125, 244) controlPoint1:NSMakePoint(132, 350) controlPoint2:NSMakePoint(113, 297)];
    [thumb curveToPoint:NSMakePoint(101, 185) controlPoint1:NSMakePoint(132, 221) controlPoint2:NSMakePoint(118, 201)];
    [thumb closePath];
    MXFill(thumb, 0.19, 0.105, 0);
    [NSGraphicsContext saveGraphicsState]; [thumb addClip];
    for (NSInteger i = 0; i < 22; ++i) {
        NSBezierPath *rib = [NSBezierPath bezierPath];
        [rib moveToPoint:NSMakePoint(46, 255 + i * 7)];
        [rib curveToPoint:NSMakePoint(173, 332 + i * 7) controlPoint1:NSMakePoint(88, 277 + i * 7) controlPoint2:NSMakePoint(123, 314 + i * 7)];
        [[NSColor colorWithCalibratedWhite:0.38 alpha:0.18] setStroke]; rib.lineWidth = 1.2; [rib stroke];
    }
    [NSGraphicsContext restoreGraphicsState];

    NSBezierPath *deck = [NSBezierPath bezierPath];
    [deck moveToPoint:NSMakePoint(166, 36)];
    [deck curveToPoint:NSMakePoint(232, 105) controlPoint1:NSMakePoint(199, 30) controlPoint2:NSMakePoint(221, 65)];
    [deck curveToPoint:NSMakePoint(252, 282) controlPoint1:NSMakePoint(248, 157) controlPoint2:NSMakePoint(264, 225)];
    [deck curveToPoint:NSMakePoint(200, 380) controlPoint1:NSMakePoint(244, 336) controlPoint2:NSMakePoint(226, 370)];
    [deck curveToPoint:NSMakePoint(124, 307) controlPoint1:NSMakePoint(175, 389) controlPoint2:NSMakePoint(128, 351)];
    [deck curveToPoint:NSMakePoint(117, 155) controlPoint1:NSMakePoint(118, 267) controlPoint2:NSMakePoint(108, 198)];
    [deck curveToPoint:NSMakePoint(166, 36) controlPoint1:NSMakePoint(127, 109) controlPoint2:NSMakePoint(138, 42)];
    [deck closePath];
    MXFill(deck, 0.30, 0.115, 5);
    [[NSColor colorWithCalibratedWhite:0.48 alpha:0.28] setStroke]; deck.lineWidth = 0.8; [deck stroke];

    // Split primary buttons, with a recessed metal wheel between them.
    NSBezierPath *split = [NSBezierPath bezierPath];
    [split moveToPoint:NSMakePoint(173, 40)];
    [split curveToPoint:NSMakePoint(174, 166) controlPoint1:NSMakePoint(165, 75) controlPoint2:NSMakePoint(165, 124)];
    [MXGray(0.065) setStroke]; split.lineWidth = 2.1; [split stroke];
    NSBezierPath *buttonSeam = [NSBezierPath bezierPath];
    [buttonSeam moveToPoint:NSMakePoint(118, 169)];
    [buttonSeam curveToPoint:NSMakePoint(246, 194) controlPoint1:NSMakePoint(160, 183) controlPoint2:NSMakePoint(203, 192)];
    [MXGray(0.09) setStroke]; buttonSeam.lineWidth = 1.3; [buttonSeam stroke];
    NSBezierPath *well = MXRound(155, 78, 35, 81, 12);
    [MXGray(0.065) setFill]; [well fill];
    NSBezierPath *wheel = MXRound(162, 85, 21, 66, 9);
    MXFill(wheel, 0.80, 0.33, 0);
    [NSGraphicsContext saveGraphicsState]; [wheel addClip];
    for (NSInteger y = 89; y < 150; y += 4) {
        [MXGray(0.27) setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(162,y)]; [line lineToPoint:NSMakePoint(183,y)]; line.lineWidth = 1; [line stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    MXFill(MXRound(173, 171, 17, 27, 6), 0.21, 0.11, 0);
    [MXGray(0.07) setStroke]; [MXRound(173,171,17,27,6) stroke];

    // The horizontal thumb wheel and the two narrow navigation keys.
    NSBezierPath *sideWheel = MXRound(96, 178, 22, 48, 7);
    MXFill(sideWheel, 0.69, 0.26, 0);
    [NSGraphicsContext saveGraphicsState]; [sideWheel addClip];
    for (NSInteger y = 182; y < 225; y += 4) {
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(96,y)]; [line lineToPoint:NSMakePoint(118,y)];
        [MXGray(0.25) setStroke]; [line stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    MXFill(MXRound(87, 235, 14, 28, 6), 0.28, 0.12, 0);
    MXFill(MXRound(80, 267, 14, 28, 6), 0.25, 0.105, 0);
    NSBezierPath *paddle = [NSBezierPath bezierPath];
    [paddle moveToPoint:NSMakePoint(47, 304)];
    [paddle curveToPoint:NSMakePoint(81, 340) controlPoint1:NSMakePoint(50, 322) controlPoint2:NSMakePoint(63, 333)];
    [paddle curveToPoint:NSMakePoint(98, 338) controlPoint1:NSMakePoint(88, 344) controlPoint2:NSMakePoint(96, 342)];
    [paddle curveToPoint:NSMakePoint(59, 299) controlPoint1:NSMakePoint(82, 330) controlPoint2:NSMakePoint(69, 315)];
    [paddle closePath]; MXFill(paddle, 0.23, 0.12, 0);

    // A restrained indicator and a small embossed product mark.
    [[NSColor colorWithCalibratedRed:0.46 green:0.84 blue:0.56 alpha:1] setFill];
    [MXRound(127, 236, 3, 12, 1.5) fill];
    NSDictionary *mark = @{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                           NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.6 alpha:0.32]};
    [@"MX" drawAtPoint:NSMakePoint(182, 285) withAttributes:mark];
    [NSGraphicsContext restoreGraphicsState];
}
@end
