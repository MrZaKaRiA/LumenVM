#import <CoreGraphics/CoreGraphics.h>

// Always use the full framebuffer transform. Cropping each dirty rectangle to
// integer source pixels and then stretching it into fractional view coordinates
// shifts pixels at the edges of cursor/hover updates. The context already clips
// drawing to AppKit's damage region, so this does not require a full repaint.
static inline void LumenDrawFramebuffer(CGContextRef context, CGImageRef image,
                                       CGRect bounds, bool smooth) {
    CGContextSaveGState(context);
    CGContextSetInterpolationQuality(context, smooth ? kCGInterpolationLow : kCGInterpolationNone);
    CGContextSetShouldAntialias(context, false);
    CGContextDrawImage(context, bounds, image);
    CGContextRestoreGState(context);
}
