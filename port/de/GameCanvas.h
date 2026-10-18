// The desktop engine requires at least 1024 x 720 logical units. Keep UIKit
// controls in device points; fit a separate game canvas to the actual window.
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
static inline CGSize DEGameCanvasSize(CGSize viewport) {
    if(viewport.width<=0||viewport.height<=0||!isfinite(viewport.width)||!isfinite(viewport.height))return CGSizeZero;
    CGFloat factor=fmax(1,fmax(1024/viewport.width,720/viewport.height));
    return CGSizeMake(ceil(viewport.width*factor),ceil(viewport.height*factor));
}
static inline CGFloat DEGameCanvasFit(CGSize viewport) {
    CGSize canvas=DEGameCanvasSize(viewport);
    return canvas.width>0&&canvas.height>0?fmin(viewport.width/canvas.width,viewport.height/canvas.height):1;
}
static inline CGPoint DEGamePointFromHost(CGPoint point,CGSize viewport) {
    CGSize canvas=DEGameCanvasSize(viewport);CGFloat scale=DEGameCanvasFit(viewport);
    return CGPointMake((point.x-(viewport.width-canvas.width*scale)/2)/scale,
                       (point.y-(viewport.height-canvas.height*scale)/2)/scale);
}
static inline CGPoint DEHostPointFromGame(CGPoint point,CGSize viewport) {
    CGSize canvas=DEGameCanvasSize(viewport);CGFloat scale=DEGameCanvasFit(viewport);
    return CGPointMake(point.x*scale+(viewport.width-canvas.width*scale)/2,
                       point.y*scale+(viewport.height-canvas.height*scale)/2);
}
static inline CGFloat DEGameCanvasBackingScale(CGSize viewport,CGFloat renderScale) {
    // Enlargement of logical coordinates must not multiply the native pixel
    // workload too. Scale 1 is the engine's minimum usable framebuffer.
    return fmax(1,renderScale*DEGameCanvasFit(viewport));
}
