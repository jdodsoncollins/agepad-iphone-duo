// Opt-in reduced render scale for memory-limited devices. The original
// engine sizes its drawable and render targets from the reported backing
// scale; every backing-scale answer uses this one value so input mapping and
// presentation stay consistent. Core Animation upscales the result.
#pragma once
#import <UIKit/UIKit.h>
#include "HostGeometry.h"
#include <stdio.h>
#include <stdlib.h>
static inline CGFloat DERenderScaleFromNative(CGFloat native) {
    if (native<=0) native=1;
    const char *value=getenv("AGEPAD_DEVICE_RENDER_SCALE");
    if (!value) return native;
    double requested=atof(value);
    CGFloat scale=(requested>=1.0 && requested<native)?(CGFloat)requested:native;
    static int logged;
    if (!logged) { logged=1; fprintf(stderr,"DE_RENDER_SCALE native=%g requested=%s used=%g\n",native,value,scale); }
    return scale;
}
static inline CGFloat DERenderScaleForView(UIView *view) {
    CGFloat native=view.traitCollection.displayScale;
    if (native<=0) native=(view.window.windowScene.screen ?: view.window.screen).scale;
    CGSize viewport=DEHostBoundsForScreen(view.window.windowScene.screen ?: view.window.screen).size;
    return DEGameCanvasBackingScale(viewport,DERenderScaleFromNative(native));
}
static inline CGFloat DERenderScaleForWindow(UIWindow *window) {
    return DERenderScaleForView(window.rootViewController.viewIfLoaded ?: window);
}
static inline CGFloat DERenderScale(UIScreen *screen) {
    UIWindow *window=DEHostWindow();
    UIScreen *hostScreen=window.windowScene.screen ?: window.screen;
    return window && screen==hostScreen?DERenderScaleForWindow(window):DERenderScaleFromNative(screen.scale);
}
