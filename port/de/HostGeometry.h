// The game uses one UIKit host window. Its size can change independently of
// the physical display (folding, multitasking or iPhone Mirroring).
#pragma once
#import <UIKit/UIKit.h>
#include "GameCanvas.h"

static inline UIWindow *DEHostWindow(void) {
    id<UIApplicationDelegate> delegate=UIApplication.sharedApplication.delegate;
    if ([delegate respondsToSelector:@selector(window)] && delegate.window)
        return delegate.window;
    UIWindow *candidate=nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            (scene.activationState!=UISceneActivationStateForegroundActive &&
             scene.activationState!=UISceneActivationStateForegroundInactive)) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
            if (!candidate && !window.hidden && window.rootViewController) candidate=window;
        }
    }
    return candidate;
}

static inline UIScreen *DEHostScreen(void) {
    UIWindow *window=DEHostWindow();
    return window.windowScene.screen ?: window.screen;
}

static inline NSArray<UIScreen *> *DEHostScreens(void) {
    UIScreen *host=DEHostScreen();
    NSMutableArray<UIScreen *> *screens=[NSMutableArray new];
    if(host)[screens addObject:host];
    for(UIScreen *screen in UIScreen.screens)if(screen!=host)[screens addObject:screen];
    return screens;
}

static inline CGRect DEHostBoundsForScreen(UIScreen *screen) {
    if (!screen) return CGRectZero;
    UIWindow *window=DEHostWindow();
    UIScreen *hostScreen=window.windowScene.screen ?: window.screen;
    if (window && hostScreen==screen) {
        UIView *root=window.rootViewController.viewIfLoaded;
        CGSize size=root?root.bounds.size:window.bounds.size;
        return (CGRect){CGPointZero,size};
    }
    // Display enumeration can include a display without a game window.
    return screen?screen.bounds:CGRectZero;
}
static inline CGRect DEGameBoundsForScreen(UIScreen *screen) {
    return (CGRect){CGPointZero,DEGameCanvasSize(DEHostBoundsForScreen(screen).size)};
}
