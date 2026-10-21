#import <Foundation/Foundation.h>
#import "../Sources/LumenHelper/LumenDisplayDrawing.h"
#include <assert.h>
#include <string.h>

// Regression: drawing an unchanged dirty region must not move any existing pixel,
// including with fractional window scaling and high-frequency text-like detail.
int main(void) {
    const size_t sw = 1920, sh = 1080, dw = 1009, dh = 679;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    uint32_t *source = calloc(sw * sh, 4);
    for (size_t y = 0; y < sh; y++) for (size_t x = 0; x < sw; x++)
        source[y * sw + x] = 0xff000000 | ((x * 29 + y * 71) & 0xffffff);
    CGContextRef src = CGBitmapContextCreate(source, sw, sh, 8, sw * 4, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef image = CGBitmapContextCreateImage(src);
    for (int smooth = 0; smooth <= 1; smooth++) {
        uint8_t *pixels = calloc(dw * dh, 4), *baseline = malloc(dw * dh * 4);
        CGContextRef ctx = CGBitmapContextCreate(pixels, dw, dh, 8, dw * 4, cs,
            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
        CGContextScaleCTM(ctx, (double)dw / sw, (double)dh / sh);
        CGContextSetShouldAntialias(ctx, false);
        CGRect bounds = CGRectMake(0, 0, sw, sh);
        LumenDrawFramebuffer(ctx, image, bounds, smooth);
        memcpy(baseline, pixels, dw * dh * 4);
        for (int n = 0; n < 120; n++) {
            CGRect dirty = CGRectMake(200.35 + n * 2.13, 400.43, 70.41, 37.61);
            CGContextSaveGState(ctx);
            CGContextClipToRect(ctx, dirty);
            LumenDrawFramebuffer(ctx, image, bounds, smooth);
            CGContextRestoreGState(ctx);
        }
        assert(memcmp(baseline, pixels, dw * dh * 4) == 0);
        // Demonstrate that this input catches the previous cropped-image path.
        CGRect dirty = CGRectMake(200.35, 400.43, 70.41, 37.61);
        CGImageRef crop = CGImageCreateWithImageInRect(image,
            CGRectMake(dirty.origin.x, sh - CGRectGetMaxY(dirty), dirty.size.width, dirty.size.height));
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, dirty);
        CGContextDrawImage(ctx, dirty, crop);
        CGContextRestoreGState(ctx);
        assert(memcmp(baseline, pixels, dw * dh * 4) != 0);
        CGImageRelease(crop);
        CGContextRelease(ctx); free(pixels); free(baseline);
    }
    CGImageRelease(image); CGContextRelease(src); CGColorSpaceRelease(cs); free(source);
    puts("PASS: fractional dirty redraws preserve every pixel with smoothing on/off; old crop path reproduces corruption");
}
