// Draws the vaporwave scene's pictures into PNGs: the name in chrome, a palm, the beach ball's
// panels and the table's top. build.sh runs it into the built scene folder.
//
// Usage: pictures OUT_DIR

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static CGContextRef canvas(size_t w, size_t h) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextSetAllowsAntialiasing(c, true);
    CGContextSetShouldAntialias(c, true);
    return c;
}

static void save(CGContextRef c, NSString *dir, NSString *name) {
    CGImageRef img = CGBitmapContextCreateImage(c);
    NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(d, img, NULL);
    if (!CGImageDestinationFinalize(d)) { fprintf(stderr, "pictures: can't write %s\n", url.path.UTF8String); exit(1); }
    CFRelease(d);
    CGImageRelease(img);
    CGContextRelease(c);
}

static CGColorRef rgb(double r, double g, double b, double a) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[4] = {r, g, b, a};
    CGColorRef c = CGColorCreate(cs, comps);
    CGColorSpaceRelease(cs);
    return c;   // leaked: a handful, made once
}

static CGGradientRef gradient(int n, const CGFloat *colors, const CGFloat *stops) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, colors, stops, n);
    CGColorSpaceRelease(cs);
    return g;
}

// A line of text, sheared into an 80s italic, centred on (x, y). Lower case comes out as smaller
// capitals, for a font that has none (MacVapoR's M, V and R stay tall), as on the dashboard.
static CTLineRef text_line(NSString *s, NSString *font_name, CGFloat size, CGFloat kern) {
    CGAffineTransform shear = CGAffineTransformMake(1, 0, 0.22, 1, 0, 0);
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)font_name, size, &shear);
    CTFontRef small = CTFontCreateWithName((__bridge CFStringRef)font_name, size * 0.76, &shear);
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc]
        initWithString:s attributes:@{(id)kCTFontAttributeName : (__bridge id)font, (id)kCTKernAttributeName : @(kern)}];
    NSCharacterSet *lower = NSCharacterSet.lowercaseLetterCharacterSet;
    for (NSUInteger i = 0; i < s.length; i++) {
        if (![lower characterIsMember:[s characterAtIndex:i]]) continue;
        NSRange r = NSMakeRange(i, 1);
        [a replaceCharactersInRange:r withString:[s substringWithRange:r].uppercaseString];
        [a addAttribute:(id)kCTFontAttributeName value:(__bridge id)small range:r];
    }
    CFRelease(font);
    CFRelease(small);
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
}

static CGPoint centred(CGContextRef c, CTLineRef line, CGFloat x, CGFloat y) {
    CGRect b = CTLineGetImageBounds(line, c);
    return CGPointMake(x - b.size.width / 2 - b.origin.x, y - b.size.height / 2 - b.origin.y);
}

// "MacVapoR" in chrome, with a neon glow, and a smaller line under it.
static CGContextRef draw_name(void) {
    CGContextRef c = canvas(2048, 768);
    CTLineRef title = text_line(@"MacVapoR", @"Futura-CondensedExtraBold", 330, 10);
    CGPoint at = centred(c, title, 1024, 470);
    CGRect b = CTLineGetImageBounds(title, c);
    b.origin.x += at.x;
    b.origin.y += at.y;

    // Glow, then the chrome inside the letters, then a bright rim.
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextSetTextDrawingMode(c, kCGTextStroke);
    CGContextSetShadowWithColor(c, CGSizeZero, 40, rgb(0.0, 0.9, 1.0, 1.0));
    CGContextSetStrokeColorWithColor(c, rgb(0.0, 0.85, 1.0, 0.9));
    CGContextSetLineWidth(c, 14);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(title, c);
    CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);

    CGContextSaveGState(c);
    CGContextSetTextDrawingMode(c, kCGTextClip);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(title, c);
    // Chrome: a cyan floor, a sharp purple horizon, silver sky darkening to violet at the top.
    const CGFloat colors[] = {
        0.10, 0.75, 0.95, 1,   0.45, 0.95, 1.00, 1,   0.22, 0.05, 0.42, 1,   0.95, 0.96, 1.00, 1,
        0.80, 0.84, 0.95, 1,   0.42, 0.28, 0.80, 1,
    };
    const CGFloat stops[] = {0.0, 0.30, 0.47, 0.50, 0.70, 1.0};
    CGGradientRef g = gradient(6, colors, stops);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, b.origin.y), CGPointMake(0, b.origin.y + b.size.height), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(c);

    CGContextSetTextDrawingMode(c, kCGTextStroke);
    CGContextSetStrokeColorWithColor(c, rgb(0.92, 0.95, 1.0, 1.0));
    CGContextSetLineWidth(c, 3);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(title, c);
    CFRelease(title);

    CTLineRef sub = text_line(@"VISION PRO  ·  PC VR", @"AvenirNext-DemiBold", 92, 26);
    CGPoint sat = centred(c, sub, 1024, 150);
    CGContextSetTextDrawingMode(c, kCGTextFill);
    CGContextSetShadowWithColor(c, CGSizeZero, 24, rgb(0.62, 0.30, 0.95, 1.0));
    CGContextSetFillColorWithColor(c, rgb(0.0, 0.92, 1.0, 1.0));
    CGContextSetTextPosition(c, sat.x, sat.y);
    CTLineDraw(sub, c);
    CFRelease(sub);
    return c;
}

// A palm in silhouette against the sunset, edged in cyan.
static CGContextRef draw_palm(void) {
    CGContextRef c = canvas(512, 1024);
    CGColorRef dark = rgb(0.06, 0.01, 0.12, 1.0), rim = rgb(0.0, 0.9, 1.0, 0.55);
    CGPoint crown = CGPointMake(300, 800);

    CGMutablePathRef trunk = CGPathCreateMutable();
    CGPathMoveToPoint(trunk, NULL, 226, 0);
    CGPathAddQuadCurveToPoint(trunk, NULL, 200, 470, crown.x - 10, crown.y);
    CGPathAddLineToPoint(trunk, NULL, crown.x + 10, crown.y);
    CGPathAddQuadCurveToPoint(trunk, NULL, 236, 470, 282, 0);
    CGPathCloseSubpath(trunk);

    CGMutablePathRef fronds = CGPathCreateMutable();
    const CGFloat tips[][2] = {{40, 640}, {80, 820}, {190, 960}, {330, 990}, {470, 880}, {500, 700}, {420, 560},
                               {150, 560}};
    for (size_t i = 0; i < sizeof tips / sizeof tips[0]; i++) {
        CGPoint tip = CGPointMake(tips[i][0], tips[i][1]);
        // The leaf arches up out of the crown and droops to its tip.
        CGPoint ctrl = CGPointMake((crown.x + tip.x) / 2, MAX(crown.y, tip.y) + 70);
        CGFloat dx = tip.y - crown.y, dy = crown.x - tip.x, n = hypot(dx, dy);
        dx = dx / n * 26;
        dy = dy / n * 26;
        CGPathMoveToPoint(fronds, NULL, crown.x, crown.y);
        CGPathAddQuadCurveToPoint(fronds, NULL, ctrl.x + dx, ctrl.y + dy, tip.x, tip.y);
        CGPathAddQuadCurveToPoint(fronds, NULL, ctrl.x - dx, ctrl.y - dy, crown.x, crown.y);
        CGPathCloseSubpath(fronds);
    }
    for (int pass = 0; pass < 2; pass++) {
        CGContextAddPath(c, trunk);
        CGContextAddPath(c, fronds);
        if (pass == 0) {
            CGContextSetStrokeColorWithColor(c, rim);
            CGContextSetLineWidth(c, 6);
            CGContextStrokePath(c);
        } else {
            CGContextSetFillColorWithColor(c, dark);
            CGContextFillPath(c);
        }
    }
    CGPathRelease(trunk);
    CGPathRelease(fronds);
    return c;
}

// The beach ball: six panels, purple, cyan and silver, with white caps.
static CGContextRef draw_ball(void) {
    CGContextRef c = canvas(512, 256);
    CGColorRef panels[3] = {rgb(0.55, 0.22, 0.90, 1), rgb(0.0, 0.85, 0.95, 1), rgb(0.88, 0.90, 0.96, 1)};
    for (int i = 0; i < 6; i++) {
        CGContextSetFillColorWithColor(c, panels[i % 3]);
        CGContextFillRect(c, CGRectMake(i * 512.0 / 6, 0, 512.0 / 6 + 1, 256));
    }
    CGContextSetFillColorWithColor(c, rgb(0.97, 0.97, 1.0, 1));
    CGContextFillRect(c, CGRectMake(0, 0, 512, 22));
    CGContextFillRect(c, CGRectMake(0, 234, 512, 22));
    return c;
}

// The table: dark purple, edged in neon.
static CGContextRef draw_table(void) {
    CGContextRef c = canvas(256, 256);
    CGContextSetFillColorWithColor(c, rgb(0.10, 0.03, 0.20, 1));
    CGContextFillRect(c, CGRectMake(0, 0, 256, 256));
    CGContextSetStrokeColorWithColor(c, rgb(0.0, 0.92, 1.0, 1));
    CGContextSetLineWidth(c, 14);
    CGContextStrokeRect(c, CGRectMake(7, 7, 242, 242));
    CGContextSetStrokeColorWithColor(c, rgb(0.62, 0.30, 0.95, 1));
    CGContextSetLineWidth(c, 4);
    CGContextStrokeRect(c, CGRectMake(24, 24, 208, 208));
    return c;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: pictures OUT_DIR\n"); return 2; }
        NSString *dir = @(argv[1]);
        save(draw_name(), dir, @"name.png");
        save(draw_palm(), dir, @"palm.png");
        save(draw_ball(), dir, @"ball.png");
        save(draw_table(), dir, @"table.png");
    }
    return 0;
}
