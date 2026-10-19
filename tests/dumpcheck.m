// Decodes an ALVRXR_DUMP stream (Annex B HEVC or H.264, both eyes side by side, foveated) and
// prints, per frame, the mean colour of patches in each eye and the frame number read from
// xrclient's bar row. Decoding is ffmpeg's (a pipe of rgb24 frames): the stream is a plain
// elementary stream, and ffmpeg also copes with the cut-off tail a killed writer leaves.
//
//   dumpcheck FILE [--png DIR] [--png-every N] [--codec hevc|h264]
//
// "fill" is the eye's commonest colour (not black or white), "other" the next (a quad, say; -1 if
// none), "bars" the number from xrclient's bar row, or - if it doesn't read (none drawn, or covered).
// The stream is limited-range BT.709 without saying so, hence the scale filter below; colours then
// come out within a few levels of what was asked.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdio.h>
#include <string.h>

// xrclient's bar row, in pixels; keep in step with xrclient.m. ALVR squeezes the periphery, not
// the centre, so cells are read by their middles.
enum { CELL = 16, BAR_H = 64, BITS = 16 };

static NSString *run_capture(NSString *cmd) {
    FILE *p = popen(cmd.UTF8String, "r");
    NSMutableData *d = [NSMutableData data];
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, p)) > 0) [d appendBytes:buf length:n];
    pclose(p);
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static NSString *sh(NSString *s) { return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }

typedef struct { float r, g, b; } rgb;

static rgb mean_patch(const uint8_t *f, int stride, int x, int y, int w, int h) {
    double r = 0, g = 0, b = 0;
    for (int j = y; j < y + h; j++)
        for (int i = x; i < x + w; i++) {
            const uint8_t *p = f + j * stride + i * 3;
            r += p[0]; g += p[1]; b += p[2];
        }
    double n = w * h;
    return (rgb){r / n, g / n, b / n};
}

static float luma(rgb c) { return 0.299f * c.r + 0.587f * c.g + 0.114f * c.b; }

// The bar row: foveation moves the eye's centre about in the encoded image (and differently per eye)
// but keeps the centre region 1:1, so the row is found by its white sync cell, the leftmost near-white
// pixels in the eye, then read cell by cell.
static bool white_at(const uint8_t *f, int stride, int x, int y) {
    const uint8_t *p = f + y * stride + x * 3;
    return p[0] > 215 && p[1] > 215 && p[2] > 215;
}

static int read_bars(const uint8_t *f, int stride, int eye_x, int eye_w, int eye_h) {
    int sx = -1;
    for (int x = eye_x; x < eye_x + eye_w && sx < 0; x++)
        for (int y = 0; y < eye_h; y += 2)
            if (white_at(f, stride, x, y)) { sx = x; break; }
    if (sx < 0) return -1;
    // The sync cell's vertical middle: the white run down the column a few pixels in.
    int top = -1, bot = -1;
    for (int y = 0; y < eye_h; y++)
        if (white_at(f, stride, sx + 4, y)) { if (top < 0) top = y; bot = y; }
    if (top < 0 || bot - top < BAR_H / 2 || bot - top > BAR_H * 2) return -1;
    int y = (top + bot) / 2, x0 = sx;
    if (x0 + (BITS + 2) * CELL > eye_x + eye_w) return -1;
    float hi = luma(mean_patch(f, stride, x0 + 4, y - 8, CELL - 8, 16));                       // sync, white
    float lo = luma(mean_patch(f, stride, x0 + (BITS + 1) * CELL + 4, y - 8, CELL - 8, 16));   // end, black
    if (hi - lo < 100) return -1;
    int v = 0;
    for (int b = 0; b < BITS; b++)
        v = v << 1 | (luma(mean_patch(f, stride, x0 + (1 + b) * CELL + 4, y - 8, CELL - 8, 16)) > (hi + lo) / 2);
    return v;
}

// The two commonest colours in an eye (a coarse grid of pixels, in 16-level buckets), leaving out
// black and white, which the bars use: the client's fill and, if there is one, a quad on it.
static void dominant(const uint8_t *f, int stride, int eye_x, int eye_w, int eye_h, rgb out[2], int *n_out) {
    enum { B = 16 };
    static double sum[B * B * B][3];
    static int count[B * B * B];
    memset(sum, 0, sizeof sum);
    memset(count, 0, sizeof count);
    int total = 0;
    for (int y = 0; y < eye_h; y += 8)
        for (int x = eye_x; x < eye_x + eye_w; x += 8) {
            const uint8_t *p = f + y * stride + x * 3;
            int k = (p[0] >> 4) * B * B + (p[1] >> 4) * B + (p[2] >> 4);
            sum[k][0] += p[0]; sum[k][1] += p[1]; sum[k][2] += p[2];
            count[k]++;
            total++;
        }
    *n_out = 0;
    for (int rank = 0; rank < 2; rank++) {
        int best = -1;
        for (int k = 0; k < B * B * B; k++) {
            rgb c = {sum[k][0] / (count[k] ?: 1), sum[k][1] / (count[k] ?: 1), sum[k][2] / (count[k] ?: 1)};
            float l = luma(c);
            if (count[k] && l > 20 && l < 235 && (best < 0 || count[k] > count[best])) best = k;
        }
        if (best < 0 || count[best] < total / 60) break;
        out[rank] = (rgb){sum[best][0] / count[best], sum[best][1] / count[best], sum[best][2] / count[best]};
        (*n_out)++;
        // Neighbouring buckets of one flat colour (compression noise) go with it.
        for (int k = 0; k < B * B * B; k++) {
            if (!count[k]) continue;
            int dr = abs((k / (B * B)) - (best / (B * B))), dg = abs((k / B % B) - (best / B % B)), db = abs((k % B) - (best % B));
            if (dr <= 1 && dg <= 1 && db <= 1) { count[k] = 0; }
        }
    }
}

static void write_png(const uint8_t *f, int w, int h, NSString *path) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, f, (size_t)w * h * 3, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, 24, w * 3, cs, kCGBitmapByteOrderDefault, dp, NULL, false, kCGRenderingIntentDefault);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                              (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(d, img, NULL);
    CGImageDestinationFinalize(d);
    CFRelease(d);
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
}

static int usage(void) {
    fprintf(stderr, "usage: dumpcheck FILE [--png DIR] [--png-every N] [--codec hevc|h264]\n");
    return 2;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *file = nil, *png = nil, *codec = @"hevc";
        int png_every = 15;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--png") && i + 1 < argc) png = @(argv[++i]);
            else if (!strcmp(argv[i], "--png-every") && i + 1 < argc) png_every = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--codec") && i + 1 < argc) codec = @(argv[++i]);
            else if (argv[i][0] != '-' && !file) file = @(argv[i]);
            else return usage();
        }
        if (!file) return usage();
        NSString *ffmpeg = @"/opt/homebrew/bin/ffmpeg", *ffprobe = @"/opt/homebrew/bin/ffprobe";
        NSString *info = run_capture([NSString stringWithFormat:@"%@ -v error -f %@ -i %@ -select_streams v:0 -show_entries stream=width,height "
                                                                 "-of csv=p=0:s=x 2>/dev/null",
                                                                ffprobe, codec, sh(file)]);
        int W = 0, H = 0;
        if (sscanf(info.UTF8String, "%dx%d", &W, &H) != 2 || W <= 0) { fprintf(stderr, "dumpcheck: can't read the stream's size from %s\n", file.UTF8String); return 1; }
        if (png) [NSFileManager.defaultManager createDirectoryAtPath:png withIntermediateDirectories:YES attributes:nil error:nil];
        printf("stream %dx%d (%d per eye)\n", W, H, W / 2);
        FILE *p = popen([NSString stringWithFormat:@"%@ -v error -f %@ -i %@ -fps_mode passthrough -vf scale=in_range=tv:in_color_matrix=bt709 -f rawvideo -pix_fmt rgb24 - 2>/dev/null",
                                                   ffmpeg, codec, sh(file)].UTF8String, "r");
        size_t fsz = (size_t)W * H * 3;
        uint8_t *f = malloc(fsz);
        int index = 0, ew = W / 2, stride = W * 3;
        while (fread(f, 1, fsz, p) == fsz) {
            char line[512];
            int len = snprintf(line, sizeof line, "frame %d", index);
            for (int e = 0; e < 2; e++) {
                int ex = e * ew;
                rgb dom[2];
                int nd;
                dominant(f, stride, ex, ew, H, dom, &nd);
                rgb fill = nd > 0 ? dom[0] : (rgb){0, 0, 0}, quad = nd > 1 ? dom[1] : (rgb){-1, -1, -1};
                int bars = read_bars(f, stride, ex, ew, H);
                char bs[16];
                snprintf(bs, sizeof bs, bars < 0 ? "-" : "%d", bars);
                len += snprintf(line + len, sizeof line - len, "  %c fill %.0f,%.0f,%.0f other %.0f,%.0f,%.0f bars %s", e ? 'R' : 'L',
                                fill.r, fill.g, fill.b, quad.r, quad.g, quad.b, bs);
            }
            puts(line);
            if (png && index % png_every == 0) write_png(f, W, H, [png stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%04d.png", index]]);
            index++;
        }
        pclose(p);
        printf("decoded %d frames\n", index);
        return index ? 0 : 1;
    }
}
