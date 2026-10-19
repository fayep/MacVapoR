// The dashboard's panel (dashboard.h): laid out on a CoreGraphics canvas in the lounge's purple,
// cyan and silver, the title in chrome as the Vaporwave scene's name is, and redrawn only when
// what it shows changes (the state, or a pointer moving onto another button).

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

#include "dashboard.h"
#include "dashboard_metal.h"

// The panel: 0.8 x 0.5 m, its picture 2000 pixels a metre, about twice what the headset shows of it
// at a metre, so the text stays sharp as it's mipmapped down.
static const float kWidth = 0.8f, kHeight = 0.5f, kOpacity = 0.96f;
enum { CW = 1600, CH = 1000 };

typedef struct {
    CGFloat x, y, w, h;   // canvas pixels, from the top left
} box;

static struct {
    id<MTLDevice> dev;
    id<MTLCommandQueue> q;
    id<MTLRenderPipelineState> pso;
    id<MTLTexture> picture;
    NSString *shown;                         // what the picture shows, to know when to redraw it
    simd_float3 centre, right, up, normal;   // right, up and normal unit vectors; normal towards the user
    XrDashboardStateALVRXR st;
    float seated;
    int hover[2], held[2];   // each hand's button under its pointer, and the one it's pressing
    bool was_down[2];
} g = {.centre = {0, 1.5f, -1}, .right = {1, 0, 0}, .up = {0, 1, 0}, .normal = {0, 0, 1}, .seated = 1.2f};

const char *dash_button_name(int b) {
    static const char *names[DASH_BUTTONS] = {"none", "standing", "seated", "-5 cm", "+5 cm", "recenter", "quit", "close"};
    return b >= 0 && b < DASH_BUTTONS ? names[b] : "?";
}

bool dash_init(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    g.dev = dev;
    g.q = q;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(dashboard_metal) options:nil error:&err];
    if (!lib) { fprintf(stderr, "vapord: dashboard shader: %s\n", err.localizedDescription.UTF8String); return false; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"panel_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"panel_fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    // Premultiplied over, alpha included: over a game the compositor blends by what's left in alpha.
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    g.pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g.pso) { fprintf(stderr, "vapord: dashboard pipeline: %s\n", err.localizedDescription.UTF8String); return false; }
    return true;
}

void dash_place(simd_float3 head, simd_float3 forward) {
    // Level, whatever the head's pitch and roll; a little below the eyes, as reading is easier
    // looking slightly down.
    forward.y = 0;
    forward = simd_length(forward) > 1e-3f ? simd_normalize(forward) : simd_make_float3(0, 0, -1);
    g.up = simd_make_float3(0, 1, 0);
    g.right = simd_cross(forward, g.up);
    g.normal = -forward;
    g.centre = head + forward * 1.0f - g.up * 0.12f;
    // A trigger or pinch already held as it opens doesn't press what's under it.
    for (int h = 0; h < 2; h++) {
        g.was_down[h] = true;
        g.hover[h] = g.held[h] = DASH_NONE;
    }
}

void dash_set_state(const XrDashboardStateALVRXR *st, float seated) {
    g.st = *st;
    g.seated = seated;
}

// ------------------------------------------------------------------------------------- layout

static bool has_game(void) { return g.st.game_pid != 0; }
static bool is_seated(void) { return g.st.eye_height > 0; }

static bool shown_button(int b) { return b != DASH_QUIT || has_game(); }
static bool enabled(int b) { return shown_button(b) && ((b != DASH_LOWER && b != DASH_HIGHER) || is_seated()); }

static box button_box(int b) {
    switch (b) {
    case DASH_STANDING: return (box){80, 375, 560, 110};
    case DASH_SEATED: return (box){680, 375, 840, 110};
    case DASH_LOWER: return (box){80, 515, 270, 110};
    case DASH_HIGHER: return (box){370, 515, 270, 110};
    case DASH_RECENTER: return (box){680, 515, 840, 110};
    case DASH_QUIT: return (box){80, 700, 840, 110};
    case DASH_CLOSE: return has_game() ? (box){960, 700, 560, 110} : (box){80, 700, 1440, 110};
    }
    return (box){0, 0, 0, 0};
}

static int button_at(CGFloat x, CGFloat y) {
    for (int b = 1; b < DASH_BUTTONS; b++) {
        box r = button_box(b);
        if (enabled(b) && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return b;
    }
    return DASH_NONE;
}

simd_float3 dash_button_centre(int b) {
    box r = button_box(b);
    float x = (float)((r.x + r.w / 2) / CW - 0.5) * kWidth, y = (float)(0.5 - (r.y + r.h / 2) / CH) * kHeight;
    return g.centre + g.right * x + g.up * y;
}

// The game's name as its executable's, less ".exe".
static NSString *game_title(void) {
    if (!has_game()) return @"Lounge";
    char name[AXR_NAME_MAX + 1] = {0};
    memcpy(name, g.st.game_name, AXR_NAME_MAX);
    NSString *s = [NSString stringWithUTF8String:name] ?: @"";
    if ([s.lowercaseString hasSuffix:@".exe"]) s = [s substringToIndex:s.length - 4];
    return s.length ? s : @"Game";
}

// ------------------------------------------------------------------------------------- pointing

int dash_point(const dash_pointer p[2], dash_beam beams[2], int *hand) {
    int pressed = DASH_NONE;
    for (int h = 0; h < 2; h++) {
        beams[h] = (dash_beam){0};
        if (!p[h].valid) {
            g.hover[h] = g.held[h] = DASH_NONE;
            g.was_down[h] = true;   // back in view with the trigger held: not a press
            continue;
        }
        simd_float3 o = p[h].origin, d = p[h].dir;
        beams[h].show = true;
        beams[h].from = o;
        beams[h].to = o + d * 0.6f;
        g.hover[h] = DASH_NONE;
        float facing = simd_dot(d, g.normal);
        if (facing < -1e-4f) {
            float t = simd_dot(g.centre - o, g.normal) / facing;
            simd_float3 at = o + d * t;
            float x = simd_dot(at - g.centre, g.right), y = simd_dot(at - g.centre, g.up);
            if (t > 0 && fabsf(x) <= kWidth / 2 && fabsf(y) <= kHeight / 2) {
                beams[h].hit = true;
                beams[h].to = at + g.normal * 0.002f;   // just in front, so the dot isn't lost in it
                g.hover[h] = button_at((x / kWidth + 0.5f) * CW, (0.5f - y / kHeight) * CH);
            }
        }
        bool down = p[h].down;
        if (!down) g.held[h] = DASH_NONE;
        else if (!g.was_down[h] && g.hover[h] != DASH_NONE) {
            g.held[h] = g.hover[h];
            if (pressed == DASH_NONE) {
                pressed = g.hover[h];
                *hand = h;
            }
        }
        g.was_down[h] = down;
    }
    return pressed;
}

// ------------------------------------------------------------------------------------- drawing

static CGColorRef rgb(double r, double gr, double b, double a) {
    static NSMutableDictionary *cache;   // a handful of colours, kept
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%.3f %.3f %.3f %.3f", r, gr, b, a];
    id c = cache[key];
    if (!c) {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat comps[4] = {r, gr, b, a};
        CGColorRef made = CGColorCreate(cs, comps);
        CGColorSpaceRelease(cs);
        c = CFBridgingRelease(made);
        cache[key] = c;
    }
    return (__bridge CGColorRef)c;
}

#define CYAN(a) rgb(0.0, 0.90, 1.0, a)
#define PURPLE(a) rgb(0.62, 0.30, 0.95, a)
#define SILVER(a) rgb(0.88, 0.90, 0.96, a)
#define PINK(a) rgb(1.0, 0.36, 0.72, a)

static CGRect cg(box b) { return CGRectMake(b.x, CH - b.y - b.h, b.w, b.h); }

static CGPathRef rounded(box b, CGFloat r) { return CGPathCreateWithRoundedRect(cg(b), r, r, NULL); }

// A line of text: sheared into the lounge's 80s italic when slanted, cut short with an ellipsis
// to fit.
static CTLineRef text_line(NSString *s, NSString *font_name, CGFloat size, CGFloat kern, bool slanted, CGFloat fit) {
    CGAffineTransform shear = CGAffineTransformMake(1, 0, slanted ? 0.22 : 0, 1, 0, 0);
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)font_name, size, &shear);
    NSDictionary *attrs = @{(id)kCTFontAttributeName : (__bridge id)font, (id)kCTKernAttributeName : @(kern),
                            (id)kCTForegroundColorFromContextAttributeName : @YES};
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:s attributes:attrs]);
    if (fit > 0 && CTLineGetTypographicBounds(line, NULL, NULL, NULL) > fit) {
        CTLineRef dots = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:@"…" attributes:attrs]);
        CTLineRef cut = CTLineCreateTruncatedLine(line, fit, kCTLineTruncationEnd, dots);
        CFRelease(dots);
        if (cut) {
            CFRelease(line);
            line = cut;
        }
    }
    CFRelease(font);
    return line;
}

// Where a line starts so it sits in b: its capitals centred top to bottom; align 0 left, 1
// centred, 2 right.
static CGPoint place(CTLineRef line, box b, int align, CGFloat size) {
    CGFloat w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGFloat x = align == 0 ? b.x : align == 1 ? b.x + (b.w - w) / 2 : b.x + b.w - w;
    CGFloat cap = size * 0.70;   // near enough every font's cap height here
    return CGPointMake(x, CH - (b.y + b.h / 2) - cap / 2);
}

static void text(CGContextRef c, NSString *s, NSString *font, CGFloat size, box b, int align, CGColorRef colour) {
    CTLineRef line = text_line(s, font, size, 0, false, b.w);
    CGPoint at = place(line, b, align, size);
    CGContextSetTextDrawingMode(c, kCGTextFill);
    CGContextSetFillColorWithColor(c, colour);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(line, c);
    CFRelease(line);
}

// Chrome lettering, as the Vaporwave scene's name: a cyan glow, a gradient of cyan floor, purple
// horizon and silver sky inside the letters, and a bright rim.
static void chrome(CGContextRef c, NSString *s, CGFloat size, box b, int align) {
    CTLineRef line = text_line(s, @"Futura-CondensedExtraBold", size, size * 0.03, true, b.w);
    CGPoint at = place(line, b, align, size);
    CGRect ink = CTLineGetImageBounds(line, c);
    ink.origin.x += at.x;
    ink.origin.y += at.y;

    CGContextSaveGState(c);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextSetTextDrawingMode(c, kCGTextStroke);
    CGContextSetShadowWithColor(c, CGSizeZero, size * 0.12, CYAN(1));
    CGContextSetStrokeColorWithColor(c, CYAN(0.9));
    CGContextSetLineWidth(c, size * 0.04);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(line, c);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CGContextSetTextDrawingMode(c, kCGTextClip);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(line, c);
    const CGFloat colors[] = {
        0.10, 0.75, 0.95, 1,   0.45, 0.95, 1.00, 1,   0.22, 0.05, 0.42, 1,   0.95, 0.96, 1.00, 1,
        0.80, 0.84, 0.95, 1,   0.42, 0.28, 0.80, 1,
    };
    const CGFloat stops[] = {0.0, 0.30, 0.47, 0.50, 0.70, 1.0};
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, colors, stops, 6);
    CGColorSpaceRelease(cs);
    CGContextDrawLinearGradient(c, grad, CGPointMake(0, ink.origin.y), CGPointMake(0, ink.origin.y + ink.size.height), 0);
    CGGradientRelease(grad);
    CGContextRestoreGState(c);

    CGContextSetTextDrawingMode(c, kCGTextStroke);
    CGContextSetStrokeColorWithColor(c, rgb(0.92, 0.95, 1.0, 1.0));
    CGContextSetLineWidth(c, MAX(size * 0.01, 1.5));
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(line, c);
    CFRelease(line);
}

// A neon rule across the panel, cyan fading into purple.
static void rule(CGContextRef c, CGFloat y) {
    CGContextSaveGState(c);
    CGContextClipToRect(c, cg((box){80, y - 2, 1440, 4}));
    const CGFloat colors[] = {0.0, 0.90, 1.0, 1, 0.62, 0.30, 0.95, 1, 0.62, 0.30, 0.95, 0};
    const CGFloat stops[] = {0, 0.6, 1};
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, colors, stops, 3);
    CGColorSpaceRelease(cs);
    CGContextDrawLinearGradient(c, grad, CGPointMake(80, 0), CGPointMake(1520, 0), 0);
    CGGradientRelease(grad);
    CGContextRestoreGState(c);
}

// A battery: its outline, filled to its charge (pink when low), a bolt over it while charging;
// then its percentage. Returns where the next thing goes.
static CGFloat battery(CGContextRef c, NSString *label, float level, bool charging, CGFloat x, CGFloat y) {
    CGFloat size = 42;
    CTLineRef l = text_line(label, @"AvenirNext-DemiBold", size, 1, false, 0);
    CGFloat lw = CTLineGetTypographicBounds(l, NULL, NULL, NULL);
    CFRelease(l);
    text(c, label, @"AvenirNext-DemiBold", size, (box){x, y, lw + 4, 60}, 0, CYAN(1));
    x += lw + 16;
    box body = {x, y + 16, 62, 28};
    if (level < 0) {
        text(c, @"–", @"AvenirNext-DemiBold", size, (box){x, y, 60, 60}, 0, SILVER(0.6));
        return x + 60 + 44;
    }
    float f = fminf(fmaxf(level, 0), 1);
    CGColorRef fill = f <= 0.2f && !charging ? PINK(1) : CYAN(1);
    CGPathRef outline = rounded(body, 6);
    CGContextAddPath(c, outline);
    CGContextSetStrokeColorWithColor(c, SILVER(0.9));
    CGContextSetLineWidth(c, 3);
    CGContextStrokePath(c);
    CGPathRelease(outline);
    CGContextSetFillColorWithColor(c, SILVER(0.9));
    CGContextFillRect(c, cg((box){body.x + body.w + 2, body.y + 8, 5, 12}));
    if (f > 0) {
        CGPathRef level_path = rounded((box){body.x + 5, body.y + 5, (body.w - 10) * f, body.h - 10}, 3);
        CGContextAddPath(c, level_path);
        CGContextSetFillColorWithColor(c, fill);
        CGContextFillPath(c);
        CGPathRelease(level_path);
    }
    if (charging) {
        // A bolt across the middle, edged dark so it reads over the fill.
        CGFloat cx = body.x + body.w / 2, cy = CH - (body.y + body.h / 2);
        CGMutablePathRef bolt = CGPathCreateMutable();
        const CGFloat pts[][2] = {{4, 17}, {-9, -2}, {0, -2}, {-4, -17}, {9, 2}, {0, 2}};
        CGPathMoveToPoint(bolt, NULL, cx + pts[0][0], cy + pts[0][1]);
        for (int i = 1; i < 6; i++) CGPathAddLineToPoint(bolt, NULL, cx + pts[i][0], cy + pts[i][1]);
        CGPathCloseSubpath(bolt);
        CGContextAddPath(c, bolt);
        CGContextSetStrokeColorWithColor(c, rgb(0.06, 0.01, 0.12, 1));
        CGContextSetLineWidth(c, 4);
        CGContextStrokePath(c);
        CGContextAddPath(c, bolt);
        CGContextSetFillColorWithColor(c, rgb(1.0, 0.95, 0.55, 1));
        CGContextFillPath(c);
        CGPathRelease(bolt);
    }
    x += body.w + 18;
    NSString *pct = [NSString stringWithFormat:@"%d%%", (int)lroundf(f * 100)];
    text(c, pct, @"AvenirNext-DemiBold", size, (box){x, y, 120, 60}, 0, SILVER(1));
    return x + 120 + 30;
}

static NSString *button_label(int b) {
    switch (b) {
    case DASH_STANDING: return @"Standing";
    case DASH_SEATED: return @"Seated (set from here)";
    case DASH_LOWER: return @"−5 cm";
    case DASH_HIGHER: return @"+5 cm";
    case DASH_RECENTER: return @"Recenter";
    case DASH_QUIT: return [@"Quit " stringByAppendingString:game_title()];
    case DASH_CLOSE: return @"Close";
    }
    return @"";
}

static void button(CGContextRef c, int b, bool hover, bool held) {
    box r = button_box(b);
    bool on = enabled(b);
    bool selected = (b == DASH_STANDING && !is_seated()) || (b == DASH_SEATED && is_seated());
    CGColorRef edge = b == DASH_QUIT ? PINK(1) : PURPLE(1);
    CGPathRef path = rounded(r, 22);
    CGContextSaveGState(c);
    CGContextAddPath(c, path);
    CGContextSetFillColorWithColor(c, held ? rgb(0.55, 0.22, 0.90, 1) : hover ? rgb(0.02, 0.33, 0.44, 1) : rgb(0.15, 0.05, 0.28, 1));
    CGContextFillPath(c);
    CGContextAddPath(c, path);
    if (hover || held) CGContextSetShadowWithColor(c, CGSizeZero, 22, CYAN(1));
    CGContextSetStrokeColorWithColor(c, !on ? rgb(0.62, 0.30, 0.95, 0.3) : hover || held ? CYAN(1) : edge);
    CGContextSetLineWidth(c, hover || held ? 6 : 4);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    CGPathRelease(path);
    box label = {r.x + 30, r.y, r.w - 60, r.h};
    if (selected) {
        // The mode in use: a lit bar at the button's left.
        CGPathRef bar = rounded((box){r.x + 22, r.y + 26, 10, r.h - 52}, 5);
        CGContextAddPath(c, bar);
        CGContextSetFillColorWithColor(c, CYAN(1));
        CGContextFillPath(c);
        CGPathRelease(bar);
    }
    text(c, button_label(b), @"AvenirNext-DemiBold", 52, label, 1,
         !on ? SILVER(0.3) : hover || held ? rgb(1, 1, 1, 1) : selected ? CYAN(1) : SILVER(1));
}

static NSString *content_key(void) {
    int hover = 0, held = 0;
    for (int h = 0; h < 2; h++) {
        hover |= 1 << g.hover[h];
        held |= 1 << g.held[h];
    }
    return [NSString stringWithFormat:@"%@|%d %d %d|%d %d %d|%d %.1f|%d %d|%d %d", game_title(),
            (int)lroundf(g.st.battery[0] * 100), (int)lroundf(g.st.battery[1] * 100), (int)lroundf(g.st.battery[2] * 100),
            g.st.charging[0], g.st.charging[1], g.st.charging[2], (int)lroundf(g.st.fps), g.st.mbps,
            (int)lroundf(g.st.eye_height * 100), (int)lroundf(g.seated * 100), hover & ~1, held & ~1];
}

static id<MTLTexture> draw_picture(void) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, CW, CH, 8, CW * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextSetAllowsAntialiasing(c, true);
    CGContextSetShouldAntialias(c, true);

    // The panel: deep purple, darker at the foot, with a faint grid like the lounge's floor, and
    // a neon edge. Inset, so the edge's glow fits.
    box panel = {20, 20, CW - 40, CH - 40};
    CGPathRef shape = rounded(panel, 44);
    CGContextSaveGState(c);
    CGContextAddPath(c, shape);
    CGContextClip(c);
    const CGFloat colors[] = {0.13, 0.04, 0.25, 1, 0.05, 0.01, 0.11, 1};
    const CGFloat stops[] = {0, 1};
    cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, colors, stops, 2);
    CGColorSpaceRelease(cs);
    CGContextDrawLinearGradient(c, grad, CGPointMake(0, CH), CGPointMake(0, 0), 0);
    CGGradientRelease(grad);
    CGContextSetStrokeColorWithColor(c, PURPLE(0.10));
    CGContextSetLineWidth(c, 2);
    for (int x = 20; x < CW; x += 80) {
        CGContextMoveToPoint(c, x, 0);
        CGContextAddLineToPoint(c, x, CH);
    }
    for (int y = 20; y < CH; y += 80) {
        CGContextMoveToPoint(c, 0, y);
        CGContextAddLineToPoint(c, CW, y);
    }
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    CGContextAddPath(c, shape);
    CGContextSetShadowWithColor(c, CGSizeZero, 18, CYAN(1));
    CGContextSetStrokeColorWithColor(c, CYAN(1));
    CGContextSetLineWidth(c, 5);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    CGPathRelease(shape);

    // The status: what's running in chrome, the stream on the right, then the batteries.
    chrome(c, game_title().uppercaseString, 96, (box){80, 50, 900, 120}, 0);
    NSString *stream = g.st.fps > 0 ? [NSString stringWithFormat:@"%d fps  ·  %.1f Mbps", (int)lroundf(g.st.fps), g.st.mbps]
                                     : @"no stream";
    text(c, stream, @"AvenirNext-DemiBold", 42, (box){1000, 80, 520, 60}, 2, CYAN(1));
    CGFloat x = 80;
    NSString *labels[3] = {@"Headset", @"Left", @"Right"};
    for (int i = 0; i < 3; i++) x = battery(c, labels[i], g.st.battery[i], g.st.charging[i] != 0, x, 170);
    rule(c, 258);

    // Height.
    text(c, @"HEIGHT", @"AvenirNext-Bold", 34, (box){80, 285, 200, 60}, 0, CYAN(1));
    NSString *height = is_seated() ? [NSString stringWithFormat:@"Seated, eyes at %.2f m", g.st.eye_height] : @"Standing";
    text(c, height, @"AvenirNext-DemiBold", 48, (box){260, 285, 1000, 60}, 0, SILVER(1));
    for (int b = 1; b < DASH_BUTTONS; b++) {
        if (!shown_button(b)) continue;
        bool hover = g.hover[0] == b || g.hover[1] == b, held = g.held[0] == b || g.held[1] == b;
        button(c, b, hover, held);
    }
    rule(c, 665);
    text(c, @"Press the system button to close", @"AvenirNext-Medium", 36, (box){80, 860, 900, 60}, 0, SILVER(0.55));
    chrome(c, @"MACVAPOR", 48, (box){1100, 855, 420, 70}, 2);

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                                                 width:CW height:CH mipmapped:YES];
    id<MTLTexture> t = [g.dev newTextureWithDescriptor:d];
    [t replaceRegion:MTLRegionMake2D(0, 0, CW, CH) mipmapLevel:0 withBytes:CGBitmapContextGetData(c) bytesPerRow:CW * 4];
    CGContextRelease(c);
    id<MTLCommandBuffer> cmd = [g.q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit generateMipmapsForTexture:t];
    [blit endEncoding];
    [cmd commit];   // queued ahead of the frame that draws it
    return t;
}

void dash_draw(id<MTLRenderCommandEncoder> enc, const simd_float4x4 camera[2], id<MTLDepthStencilState> depth) {
    NSString *key = content_key();
    if (!g.picture || ![key isEqualToString:g.shown]) {
        g.picture = draw_picture();
        g.shown = key;
    }
    struct {
        simd_float4 centre, right, up, opacity;
    } panel = {simd_make_float4(g.centre, 1), simd_make_float4(g.right * (kWidth / 2), 0),
               simd_make_float4(g.up * (kHeight / 2), 0), simd_make_float4(kOpacity, 0, 0, 0)};
    [enc setRenderPipelineState:g.pso];
    [enc setDepthStencilState:depth];
    [enc setVertexBytes:&panel length:sizeof panel atIndex:0];
    [enc setVertexBytes:camera length:sizeof(simd_float4x4) * 2 atIndex:1];
    [enc setFragmentBytes:&panel length:sizeof panel atIndex:0];
    [enc setFragmentTexture:g.picture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}
