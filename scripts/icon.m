#import <AppKit/AppKit.h>
#import <math.h>

static void DrawMouseIcon(void) {
    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(60,60,904,904) xRadius:202 yRadius:202];
    NSGradient *background = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.98 alpha:1] endingColor:[NSColor colorWithCalibratedWhite:0.84 alpha:1]];
    [background drawInBezierPath:tile angle:90];
    [[NSColor colorWithCalibratedWhite:1 alpha:0.8] setStroke];
    tile.lineWidth = 4;
    [tile stroke];

    // The broad silhouette and wheel remain clear at menu and Finder sizes.
    NSBezierPath *body = [NSBezierPath bezierPath];
    [body moveToPoint:NSMakePoint(512,188)];
    [body curveToPoint:NSMakePoint(730,420) controlPoint1:NSMakePoint(664,188) controlPoint2:NSMakePoint(730,282)];
    [body lineToPoint:NSMakePoint(730,625)];
    [body curveToPoint:NSMakePoint(512,842) controlPoint1:NSMakePoint(730,773) controlPoint2:NSMakePoint(649,842)];
    [body curveToPoint:NSMakePoint(294,625) controlPoint1:NSMakePoint(375,842) controlPoint2:NSMakePoint(294,773)];
    [body lineToPoint:NSMakePoint(294,420)];
    [body curveToPoint:NSMakePoint(512,188) controlPoint1:NSMakePoint(294,282) controlPoint2:NSMakePoint(360,188)];
    [body closePath];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithCalibratedWhite:0 alpha:0.24];
    shadow.shadowBlurRadius = 26;
    shadow.shadowOffset = NSMakeSize(0,-17);
    [shadow set];
    [[NSColor colorWithCalibratedWhite:0.17 alpha:1] setFill];
    [body fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient *shell = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.34 alpha:1] endingColor:[NSColor colorWithCalibratedWhite:0.13 alpha:1]];
    [shell drawInBezierPath:body angle:0];
    [[NSColor colorWithCalibratedWhite:0.08 alpha:1] setStroke];
    body.lineWidth = 6;
    [body stroke];

    NSBezierPath *split = [NSBezierPath bezierPath];
    [split moveToPoint:NSMakePoint(512,192)];
    [split lineToPoint:NSMakePoint(512,460)];
    [split moveToPoint:NSMakePoint(300,459)];
    [split curveToPoint:NSMakePoint(724,459) controlPoint1:NSMakePoint(420,492) controlPoint2:NSMakePoint(604,492)];
    split.lineWidth = 10;
    split.lineCapStyle = NSLineCapStyleRound;
    [[NSColor colorWithCalibratedWhite:0.07 alpha:1] setStroke];
    [split stroke];

    NSBezierPath *wheelWell = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(470,282,84,150) xRadius:34 yRadius:34];
    [[NSColor colorWithCalibratedWhite:0.06 alpha:1] setFill];
    [wheelWell fill];
    NSBezierPath *wheel = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(485,292,54,126) xRadius:20 yRadius:20];
    NSGradient *metal = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithCalibratedWhite:0.65 alpha:1],0.0,[NSColor colorWithCalibratedWhite:0.96 alpha:1],0.45,[NSColor colorWithCalibratedWhite:0.53 alpha:1],1.0,nil];
    [metal drawInBezierPath:wheel angle:0];
}

static void DrawHelperBadge(void) {
    NSPoint center = NSMakePoint(729, 733);
    NSBezierPath *gear = [NSBezierPath bezierPath];
    for (NSInteger point = 0; point < 48; ++point) {
        CGFloat angle = point * M_PI / 24.0 - M_PI / 2.0;
        CGFloat radius = (point % 6 == 0 || point % 6 == 5) ? 123 : 148;
        NSPoint vertex = NSMakePoint(center.x + cos(angle) * radius, center.y + sin(angle) * radius);
        if (point == 0) [gear moveToPoint:vertex];
        else [gear lineToPoint:vertex];
    }
    [gear closePath];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithCalibratedWhite:0 alpha:0.28];
    shadow.shadowBlurRadius = 16;
    shadow.shadowOffset = NSMakeSize(0, -8);
    [shadow set];
    [[NSColor colorWithCalibratedWhite:0.9 alpha:1] setFill];
    [gear fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient *metal = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.99 alpha:1] endingColor:[NSColor colorWithCalibratedWhite:0.68 alpha:1]];
    [metal drawInBezierPath:gear angle:90];
    [[NSColor colorWithCalibratedWhite:0.25 alpha:1] setStroke];
    gear.lineWidth = 10;
    gear.lineJoinStyle = NSLineJoinStyleRound;
    [gear stroke];
    NSBezierPath *hub = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - 55, center.y - 55, 110, 110)];
    [[NSColor colorWithCalibratedWhite:0.23 alpha:1] setFill];
    [hub fill];
    [[NSColor colorWithCalibratedWhite:1 alpha:0.65] setStroke];
    hub.lineWidth = 5;
    [hub stroke];
}

static NSBitmapImageRep *RenderIcon(BOOL helper) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *bitmapContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:bitmapContext];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:0 yBy:1024];
    [transform scaleXBy:1 yBy:-1];
    [transform concat];
    DrawMouseIcon();
    if (helper) DrawHelperBadge();
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

static BOOL WriteIconset(NSString *directory, BOOL helper) {
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    NSBitmapImageRep *master = RenderIcon(helper);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1024, 1024)];
    [image addRepresentation:master];
    NSArray<NSNumber *> *sizes = @[@16, @32, @128, @256, @512];
    for (NSNumber *size in sizes) {
        for (NSInteger resolution = 1; resolution <= 2; ++resolution) {
            NSInteger pixels = size.integerValue * resolution;
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            [NSGraphicsContext setCurrentContext:context];
            context.imageInterpolation = NSImageInterpolationHigh;
            [image drawInRect:NSMakeRect(0, 0, pixels, pixels) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:NO hints:nil];
            [NSGraphicsContext restoreGraphicsState];
            NSString *name = [NSString stringWithFormat:@"icon_%ldx%ld%@.png", (long)size.integerValue, (long)size.integerValue, resolution == 2 ? @"@2x" : @""];
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if (![png writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                return NO;
            }
        }
    }
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 && argc != 3) {
            fprintf(stderr, "Usage: %s settings.iconset [helper.iconset]\n", argv[0]);
            return 64;
        }
        if (!WriteIconset(@(argv[1]), NO)) return 1;
        if (argc == 3 && !WriteIconset(@(argv[2]), YES)) return 1;
    }
    return 0;
}
