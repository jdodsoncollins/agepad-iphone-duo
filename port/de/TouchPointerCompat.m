// App-owned pointer state. Initial center is an explicit touch-control policy,
// not a query of the host Mac cursor. UIKit gestures update the stored point.
#import <UIKit/UIKit.h>
#include "UnsupportedBoundary.h"
#include "OrderedPointerOwnership.h"
#include "HostGeometry.h"
@interface DEPointerTracker : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic) CGPoint position;
@property(nonatomic) NSTimeInterval pinnedUntil;
@property(nonatomic,weak) UIWindow *window;
@end
@implementation DEPointerTracker
- (void)track:(UIGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) return;
    // Apple Pencil hover ends when the tip leaves hover range; UIKit then
    // reports (0,0). Keep the last hovered position instead of jumping to the
    // top-left corner. Touch (long-press) end locations remain real points.
    if ([gesture isKindOfClass:UIHoverGestureRecognizer.class] && gesture.state==UIGestureRecognizerStateEnded) return;
    CGPoint local=[gesture locationInView:self.window];
    if([gesture isKindOfClass:UILongPressGestureRecognizer.class] && (gesture.state!=UIGestureRecognizerStateChanged || getenv("AGEPAD_INPUT_VERBOSE"))){UIView *hit=[self.window hitTest:local withEvent:nil];fprintf(stderr,"DE_TOUCH_HIT state=%ld view=%s super=%s\n",(long)gesture.state,object_getClassName(hit),object_getClassName(hit.superview));}
    // The compatibility display is the host window's logical viewport.
    // Keep both polled and delivered input in window points, independent of
    // physical panel origin, panel scale and the window's multitasking offset.
    // A tap's click is sent just after the tip lifts; Pencil hover from that
    // moment on must not move the pointer away from where the tap landed.
    if(NSProcessInfo.processInfo.systemUptime<self.pinnedUntil)return;
    if(DEOrderedMousePointerIsHeld()) {
        if(getenv("AGEPAD_INPUT_TIMING"))fprintf(stderr,"DE_POINTER_UIKIT_DEFERRED x=%g y=%g ordered_button_active=1\n",local.x,local.y);
        return;
    }
    @synchronized(self) { self.position=local; }
    if(getenv("AGEPAD_INPUT_VERBOSE"))fprintf(stderr,"DE_POINTER_UIKIT_UPDATE x=%g y=%g\n",local.x,local.y);
}
- (void)hostGeometryChanged:(NSNotification *)notification {
    CGRect bounds=self.window.bounds;
    if (CGRectIsEmpty(bounds)) return;
    @synchronized(self) {
        self.position=CGPointMake(MAX(CGRectGetMinX(bounds),MIN(self.position.x,CGRectGetMaxX(bounds)-1)),
                                  MAX(CGRectGetMinY(bounds),MIN(self.position.y,CGRectGetMaxY(bounds)-1)));
        self.pinnedUntil=0;
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }
@end
static DEPointerTracker *DEPointer;
void DEInstallTouchPointer(void) {
    if (!getenv("AGEPAD_POINTER_STATE") || DEPointer) return;
    if (!NSThread.isMainThread) DEUnsupported("pointer installation requires main thread");
    UIWindow *window=DEHostWindow();
    if (!window) DEUnsupported("pointer requires an actual UIKit window");
    DEPointer=[DEPointerTracker new];DEPointer.window=window;
    DEPointer.position=CGPointMake(CGRectGetMidX(window.bounds),CGRectGetMidY(window.bounds));
    [NSNotificationCenter.defaultCenter addObserver:DEPointer selector:@selector(hostGeometryChanged:) name:@"DEUIKitDisplayGeometryDidChange" object:nil];
    UILongPressGestureRecognizer *touch=[[UILongPressGestureRecognizer alloc] initWithTarget:DEPointer action:@selector(track:)];
    touch.minimumPressDuration=0;touch.allowableMovement=CGFLOAT_MAX;touch.cancelsTouchesInView=NO;touch.delaysTouchesBegan=NO;touch.delaysTouchesEnded=NO;touch.delegate=DEPointer;
    [window addGestureRecognizer:touch];
    UIHoverGestureRecognizer *hover=[[UIHoverGestureRecognizer alloc] initWithTarget:DEPointer action:@selector(track:)];
    hover.cancelsTouchesInView=NO;hover.delegate=DEPointer;[window addGestureRecognizer:hover];
    fprintf(stderr,"DE_POINTER_INITIALIZED policy=window-center x=%g y=%g; touch/hover observers installed\n",DEPointer.position.x,DEPointer.position.y);
}
CGPoint DEUIKitPointerPosition(void) {
    if (!getenv("AGEPAD_POINTER_STATE") || !DEPointer) DEUnsupported("uninitialized UIKit pointer state");
    @synchronized(DEPointer) { return DEPointer.position; }
}

// Reposition the app's logical pointer. Never moves the host Mac cursor.
void DEUIKitSetPointerPosition(CGPoint point) {
    if (!getenv("AGEPAD_POINTER_STATE") || !DEPointer)
        DEUnsupported("warp requires initialized UIKit pointer");
    @synchronized(DEPointer) { DEPointer.position=point; }
    fprintf(stderr,"DE_POINTER_WARP x=%g y=%g domain=app\n",point.x,point.y);
}
// Hold the pointer at a window point for a short time (a Pencil tap's click).
void DEUIKitPinPointer(CGPoint windowPoint,NSTimeInterval seconds) {
    if (!DEPointer) return;
    @synchronized(DEPointer) { DEPointer.position=windowPoint;DEPointer.pinnedUntil=NSProcessInfo.processInfo.systemUptime+seconds; }
}
