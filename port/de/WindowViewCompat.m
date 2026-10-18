// UIKit hosting for original AppKit window/view objects. Original engine
// layers are attached directly; this does not draw substitute game content.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#include "UnsupportedBoundary.h"
#include "ExistingMethod.h"
#include <dlfcn.h>
#include "RenderScale.h"
#include "WindowPresentation.h"
#include "DrawablePresentationCompat.m"
#include "TouchCommandWheelView.m"
#include "HUDInputRegions.h"
@class NSWindow, DEGameTrackingController;
extern id DEUIKitScreenObject(UIScreen *screen);
@protocol DEColorObject
- (CGColorRef)CGColor;
@end
@protocol DEGameMouseEvent
@property(nonatomic) NSUInteger type,modifierFlags;
@property(nonatomic) CGPoint locationInWindow;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic) NSInteger windowNumber,buttonNumber,clickCount,eventNumber;
@property(nonatomic) CGFloat deltaX,deltaY;
@property(nonatomic) float pressure;
@property(nonatomic,weak) id window;
@property(nonatomic) unsigned short keyCode;
@property(nonatomic,copy) NSString *characters,*charactersIgnoringModifiers;
@property(nonatomic,getter=isARepeat) BOOL ARepeat;
@end
@interface DEPendingTouchClick : NSObject
@property(nonatomic,strong) UITouch *touch;
@property(nonatomic) CGPoint point;
@property(nonatomic) BOOL secondary,cancelled,releaseQueued;
@property(nonatomic,copy) NSString *HUDProfileIdentity;
@end
@implementation DEPendingTouchClick @end
#include "OrderedMouseDelivery.h"
@interface DEGameViewHost : UIView <UIGestureRecognizerDelegate>
@property(nonatomic,strong) CALayer *gameLayer;
@property(nonatomic,weak) id originalView;
@property(nonatomic,strong) UITouch *gameTouch;
@property(nonatomic,strong) NSMutableArray<DEPendingTouchClick *> *pendingClicks;
@property(nonatomic,strong) DEPendingTouchClick *pendingClickContext;
@property(nonatomic) BOOL pendingClickDelivery;
@property(nonatomic,strong) NSHashTable<UITouch *> *HUDTouches;
@property(nonatomic) BOOL gameTouchIsHUD,HUDInputConsumed;
@property(nonatomic) CGRect HUDContactRegion;
@property(nonatomic,copy) NSString *HUDContactIdentity,*lastInputHUDIdentity;
@property(nonatomic) NSInteger gameClickCount;
@property(nonatomic) UIEventButtonMask gameButtonMask;
@property(nonatomic) CGPoint previousTouchPoint;
@property(nonatomic,strong) UIButton *touchOrderButton;
@property(nonatomic,strong) NSArray<UIButton *> *touchShortcutButtons;
@property(nonatomic,strong) UIButton *commandWheelButton;
@property(nonatomic,strong) UIButton *commandBackButton;
@property(nonatomic) BOOL windowedPresentation;
@property(nonatomic,strong) DETouchCommandWheelView *commandWheel;
@property(nonatomic) BOOL wheelConsumed,wheelTouchDriven;
@property(nonatomic) NSUInteger wheelGeneration;
@property(nonatomic) CGPoint wheelAnchor;
@property(nonatomic) CGRect lastInputBounds;
@property(nonatomic) UIEdgeInsets lastInputInsets;
@property(nonatomic,copy) NSArray<NSValue *> *lastInputReservedRects;
@property(nonatomic,strong) NSTimer *reservedRegionTimer;
@property(nonatomic) BOOL touchCommandMode;
// Apple Pencil sticky orders (AGEPAD_PENCIL_STICKY_ORDER), gameplay only.
@property(nonatomic) BOOL pencilPending,pendingIsPencil,pencilDragging,forceSecondary,overrideActive;
@property(nonatomic) CGPoint pencilStart,overridePoint;
@property(nonatomic) NSTimeInterval pencilStartTime,lastDragSent;
@property(nonatomic,strong) NSTimer *zoomTimer;
@property(nonatomic,weak) UIGestureRecognizer *orderTap,*zoomPinch,*mapPan;
// Two-finger tap (right click), recognised here rather than by a UIKit tap
// recognizer, which gave up on slow or slightly moving taps.
@property(nonatomic) BOOL twoFingerCandidate,twoFingerFailed;
@property(nonatomic) CGPoint twoFingerPoint;
@property(nonatomic) NSTimeInterval twoFingerStart;
@property(nonatomic) NSUInteger twoFingerCount;
@property(nonatomic,strong) NSMutableDictionary<NSValue *,NSValue *> *twoFingerStarts;
- (void)refreshTouchCommandButton;
- (void)installNativeGestures;
- (void)startTestInput;
- (NSSet<UITouch *> *)mapTouches:(UIEvent *)event;
- (BOOL)mapTouchesAllUp:(UIEvent *)event;
- (void)pencilDeselect:(const char *)how;
- (void)nativeMapScrollPhase:(NSInteger)phase point:(CGPoint)point;
- (void)nativeMouse:(NSUInteger)type point:(CGPoint)point wheel:(CGFloat)wheel;
- (BOOL)usesCompactTouchControls;
- (CGFloat)touchCoordinateScale;
- (BOOL)canBeginTouchCommandWheel;
- (void)beginTouchCommandWheel:(BOOL)touchDriven;
- (void)updateTouchCommandWheel;
- (void)performWheelAction:(DECommandWheelAction)action;
- (void)cancelTouchCommandWheel;
- (void)cancelHostInput:(NSNotification *)note;
- (void)cancelNativeGestures;
- (NSArray<NSValue *> *)HUDInputRegions;
- (BOOL)pointInHUDInputRegion:(CGPoint)windowPoint;
- (NSSet<UITouch *> *)hostTouches:(UIEvent *)event;
- (BOOL)hostTouchesAllUp:(UIEvent *)event;
- (BOOL)HUDContactIsValid;
@end
static void DEPostGameKey(unsigned short macKey, NSString *characters, BOOL pressed);
static void DEGameHostDidLayout(DEGameViewHost *host);
static BOOL DEGlobalTouchCommandMode;
// Pencil: a tap or drag-box on the map selects and arms orders; further map
// taps are right-click orders; a hold is a left click that disarms. HUD taps
// (top bar, bottom panel/minimap) stay left clicks and disarm, so a build
// button followed by a map tap places the building.
static BOOL DEPencilOrderArmed;
// MENU button toggle: F10 opens DE's game menu; the second press sends Escape,
// which closes it. Gameplay gestures (orders, drag boxes, scrolls) prove the
// menu is closed, so they reset the toggle.
static BOOL DEMenuOpen;
// Something may be selected (a map tap or box, IDLE, TOWN). A Pencil
// double-tap sends Escape only then: Escape with nothing selected opens the
// game menu. Kept once per process, because this code is loaded in two copies.
static void DESetMaybeSelected(BOOL value) { NSThread.mainThread.threadDictionary[@"AgePadMaybeSelected"]=@(value); }
static BOOL DEMaybeSelected(void) { return [NSThread.mainThread.threadDictionary[@"AgePadMaybeSelected"] boolValue]; }
// Longest gap between the two fingers of a two-finger order tap; a single
// finger held still in a match waits this long before its press begins.
static const NSTimeInterval DETwoFingerWindow=0.45;
// High-rate pointer events (move/drag, up to 240 Hz from Apple Pencil) are
// only logged with AGEPAD_INPUT_VERBOSE; the logging itself added latency.
static BOOL DEInputVerbose(NSUInteger type) {
    static int verbose=-1;if (verbose<0) verbose=getenv("AGEPAD_INPUT_VERBOSE")!=NULL;
    return verbose || (type!=5 && type!=6 && type!=7 && type!=27);
}
static BOOL DEPencilMatchActive(void) {
    static int (*active)(void);static BOOL looked;
    if (!looked) { looked=YES;active=(int(*)(void))dlsym(RTLD_DEFAULT,"DEGameMatchActive"); }
    return active && active();
}
static NSHashTable<DEGameViewHost *> *DETouchCommandHosts;
static void DERefreshTouchCommandButtons(void) {
    for (DEGameViewHost *host in DETouchCommandHosts.allObjects) {
        host.touchCommandMode=DEGlobalTouchCommandMode;
        [host refreshTouchCommandButton];
    }
}
static void DELogHostGeometry(NSString *phase, UIView *host) {
    if (!getenv("AGEPAD_HOST_GEOMETRY_TRACE") || !host) return;
    UIWindow *window=host.window;
    UIView *root=window.rootViewController.view;
    UIScreen *screen=window.windowScene.screen ?: window.screen;
    UIWindowScene *scene=window.windowScene;
    UIInterfaceOrientation orientation=scene ? scene.interfaceOrientation : UIInterfaceOrientationUnknown;
    fprintf(stderr,
        "DE_HOST_GEOMETRY phase=%s orientation=%ld scale=%g screen=%s native=%s coordinate=%s window=%s root_frame=%s root_bounds=%s host_frame=%s host_bounds=%s layer_frame=%s layer_bounds=%s layer_transform=%g,%g,%g,%g\n",
        phase.UTF8String,(long)orientation,screen.scale,
        NSStringFromCGRect(screen.bounds).UTF8String,NSStringFromCGRect(screen.nativeBounds).UTF8String,
        NSStringFromCGRect(screen.coordinateSpace.bounds).UTF8String,
        NSStringFromCGRect(window.bounds).UTF8String,NSStringFromCGRect(root.frame).UTF8String,
        NSStringFromCGRect(root.bounds).UTF8String,NSStringFromCGRect(host.frame).UTF8String,
        NSStringFromCGRect(host.bounds).UTF8String,NSStringFromCGRect(host.layer.frame).UTF8String,
        NSStringFromCGRect(host.layer.bounds).UTF8String,host.layer.affineTransform.a,host.layer.affineTransform.b,
        host.layer.affineTransform.c,host.layer.affineTransform.d);
}
// Inspect existing methods without invoking the diagnostic resolveInstanceMethod.
static BOOL DEHasMouseHandler(Class cls,SEL action) {
 for(;cls;cls=class_getSuperclass(cls)){unsigned count=0;Method *methods=class_copyMethodList(cls,&count);BOOL found=NO;for(unsigned i=0;i<count;i++)if(method_getName(methods[i])==action){found=YES;break;}free(methods);if(found)return YES;}return NO;
}
static void DELogTouchDetail(UITouch *touch, NSUInteger type) {
    if (!getenv("AGEPAD_TOUCH_DETAIL_TRACE") || !touch) return;
    CGPoint precise=[touch preciseLocationInView:touch.view];
    fprintf(stderr,
        "DE_TOUCH_DETAIL type=%lu phase=%lu touch_type=%lu taps=%lu timestamp=%.6f force=%g max_force=%g major=%g tolerance=%g precise=%g,%g\n",
        (unsigned long)type,(unsigned long)touch.phase,(unsigned long)touch.type,
        (unsigned long)touch.tapCount,touch.timestamp,touch.force,
        touch.maximumPossibleForce,touch.majorRadius,touch.majorRadiusTolerance,
        precise.x,precise.y);
}
static void DELogButtonMask(UIEvent *event, NSUInteger type, UIEventButtonMask mask) {
    if (!getenv("AGEPAD_BUTTON_MASK_TRACE") || !event) return;
    fprintf(stderr,"DE_BUTTON_MASK type=%lu event_type=%ld mask=%lu primary=%d secondary=%d\n",
        (unsigned long)type,(long)event.type,(unsigned long)mask,
        (mask & UIEventButtonMaskPrimary) != 0,
        (mask & UIEventButtonMaskSecondary) != 0);
}
static void DELogSynthesizedMouse(NSUInteger phase, id<DEGameMouseEvent> event, UIEventButtonMask mask, SEL action) {
    if (!getenv("AGEPAD_BUTTON_MASK_TRACE") || !event) return;
    fprintf(stderr,"DE_SYNTH_MOUSE phase=%lu event_type=%lu button_number=%ld mask=%lu action=%s\n",
        (unsigned long)phase,(unsigned long)event.type,(long)event.buttonNumber,
        (unsigned long)mask,sel_getName(action));
}
@implementation DEGameViewHost
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame]) && getenv("AGEPAD_TOUCH_COMMAND_OVERLAY")) {
        if (!DETouchCommandHosts) DETouchCommandHosts=[NSHashTable weakObjectsHashTable];
        [DETouchCommandHosts addObject:self];
        _touchOrderButton=[UIButton buttonWithType:UIButtonTypeSystem];
        [_touchOrderButton addTarget:self action:@selector(toggleTouchCommand:) forControlEvents:UIControlEventTouchUpInside];
        _touchOrderButton.accessibilityLabel=@"Right-click mode";
        [self addSubview:_touchOrderButton];
        NSMutableArray<UIButton *> *shortcuts=[NSMutableArray new];
        NSArray *titles=@[@"IDLE",@"TOWN",@"ZOOM +",@"ZOOM −",@"MENU"];
        for(NSUInteger i=0;i<titles.count;i++) {
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
            button.tag=i;[button setTitle:titles[i] forState:UIControlStateNormal];
            [button addTarget:self action:@selector(touchShortcut:) forControlEvents:UIControlEventTouchUpInside];
            if(i==2 || i==3) {
                // Zoom repeats while the button is held.
                [button addTarget:self action:@selector(zoomHoldBegan:) forControlEvents:UIControlEventTouchDown];
                [button addTarget:self action:@selector(zoomHoldEnded:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
            }
            [self addSubview:button];[shortcuts addObject:button];
        }
        self.touchShortcutButtons=shortcuts;
        _commandWheelButton=[UIButton buttonWithType:UIButtonTypeSystem];
        [_commandWheelButton setTitle:@"COMMANDS" forState:UIControlStateNormal];
        [_commandWheelButton addTarget:self action:@selector(showTouchCommandWheel:) forControlEvents:UIControlEventTouchUpInside];
        _commandWheelButton.accessibilityLabel=@"Game commands";
        _commandWheelButton.accessibilityHint=@"Open commands. You can also hold the map, slide to a command, and release.";
        _commandWheelButton.titleLabel.numberOfLines=2;
        _commandWheelButton.titleLabel.textAlignment=NSTextAlignmentCenter;
        [self addSubview:_commandWheelButton];
        _commandBackButton=[UIButton buttonWithType:UIButtonTypeSystem];
        [_commandBackButton setTitle:@"BACK" forState:UIControlStateNormal];
        [_commandBackButton addTarget:self action:@selector(touchBack:) forControlEvents:UIControlEventTouchUpInside];
        _commandBackButton.accessibilityLabel=@"Deselect or go back";
        _commandBackButton.accessibilityHint=@"Cancel an order or selection, or close the game menu.";
        [self addSubview:_commandBackButton];
        for(UIButton *button in [@[_touchOrderButton,_commandWheelButton,_commandBackButton] arrayByAddingObjectsFromArray:shortcuts]) {
            [button setTitleColor:[UIColor colorWithRed:0.98 green:0.85 blue:0.56 alpha:1] forState:UIControlStateNormal];
            button.backgroundColor=[UIColor colorWithRed:0.38 green:0.055 blue:0.035 alpha:0.96];
            button.layer.borderColor=[UIColor colorWithRed:0.75 green:0.55 blue:0.23 alpha:1].CGColor;
            button.layer.borderWidth=2;button.layer.cornerRadius=2;
            button.titleLabel.font=[UIFont fontWithName:@"Georgia-Bold" size:14];
        }
        _touchOrderButton.accessibilityHint=@"The next tap is a right click (move, gather, attack). Two-finger tap does the same.";
        shortcuts[0].accessibilityLabel=@"Select idle villager";
        shortcuts[1].accessibilityLabel=@"Select town center";
        shortcuts[2].accessibilityLabel=@"Zoom in";
        shortcuts[3].accessibilityLabel=@"Zoom out";
        shortcuts[4].accessibilityLabel=@"Game menu";
        [self refreshTouchCommandButton];
        [self installNativeGestures];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelHostInput:) name:@"DEUIKitHostGeometryWillChange" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelHostInput:) name:UIApplicationWillResignActiveNotification object:nil];
        fprintf(stderr,"DE_TOUCH_COMMAND_OVERLAY installed style=gold-red-side-strip\n");
    }
    return self;
}
- (void)zoomHoldBegan:(UIButton *)button {
    CGFloat wheel=button.tag==2?1:-1;
    CGPoint center=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds));
    [self nativeMouse:22 point:center wheel:wheel];
    [self.zoomTimer invalidate];
    __weak DEGameViewHost *weakSelf=self;
    // One step on touch-down; after 0.35 s held, repeat every 0.12 s.
    self.zoomTimer=[[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:0.35] interval:0.12 repeats:YES block:^(NSTimer *timer){
        DEGameViewHost *host=weakSelf;if(!host){[timer invalidate];return;}
        [host nativeMouse:22 point:center wheel:wheel];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.zoomTimer forMode:NSRunLoopCommonModes];
}
- (void)zoomHoldEnded:(UIButton *)button { [self.zoomTimer invalidate];self.zoomTimer=nil; }
- (void)touchShortcut:(UIButton *)button {
    if(button.tag==2 || button.tag==3) {
        return; // Zoom is sent on touch-down and repeated while held.
    }
    if(button.tag==4 && DEMenuOpen) {
        DEMenuOpen=NO;DEGlobalTouchCommandMode=NO;DERefreshTouchCommandButtons();
        fprintf(stderr,"DE_MENU_TOGGLE action=close key=escape\n");
        DEPostGameKey(53,@"\e",YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{DEPostGameKey(53,@"\e",NO);});
        return;
    }
    if(button.tag==4){DEMenuOpen=YES;fprintf(stderr,"DE_MENU_TOGGLE action=open key=f10\n");}
    unsigned short key=button.tag==0?47:button.tag==1?4:109;
    NSString *characters=button.tag==0?@".":button.tag==1?@"h":@"\uF70D";
    DEGlobalTouchCommandMode=NO;DERefreshTouchCommandButtons();
    DEPencilOrderArmed=button.tag==0 || button.tag==1; // IDLE/TOWN select units; MENU does not.
    if(button.tag==0 || button.tag==1) DESetMaybeSelected(YES);
    DEPostGameKey(key,characters,YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{DEPostGameKey(key,characters,NO);});
}
- (void)touchBack:(UIButton *)button {
    [self cancelHostInput:nil];
    // Reuse the guarded Escape path: an unguarded second Escape can open
    // the game menu when the player only wanted to clear their selection.
    [self pencilDeselect:"touch-back"];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)refreshTouchCommandButton {
    if (!self.touchOrderButton) return;
    [self.touchOrderButton setTitle:DEGlobalTouchCommandMode?@"CANCEL":@"R-CLICK" forState:UIControlStateNormal];
    [self.commandWheelButton setTitle:DEGlobalTouchCommandMode?@"CANCEL\nORDER":@"COMMANDS" forState:UIControlStateNormal];
    self.commandWheelButton.accessibilityLabel=DEGlobalTouchCommandMode?@"Cancel right-click mode":@"Game commands";
}
- (void)toggleTouchCommand:(UIButton *)sender {
    DEGlobalTouchCommandMode=!DEGlobalTouchCommandMode;
    DERefreshTouchCommandButtons();
    fprintf(stderr,"DE_TOUCH_COMMAND_MODE mode=%s\n",DEGlobalTouchCommandMode?"order":"select");
}
- (void)sendGameMouse:(NSUInteger)type touch:(UITouch *)touch cancelled:(BOOL)cancelled {
 id owner=self.originalView;
 BOOL verbose=DEInputVerbose(type);
 if(verbose)DELogTouchDetail(touch,type);
 if(verbose)fprintf(stderr,"DE_GAME_TOUCH_HOST host=%s owner=%s type=%lu\n",object_getClassName(self),object_getClassName(owner),(unsigned long)type);
 SEL action=NSSelectorFromString(type==1?@"mouseDown:":type==2?@"mouseUp:":type==5?@"mouseMoved:":@"mouseDragged:");
 // UIKit clears buttonMask on release. Use the mask captured at touchesBegan
 // for the whole gesture, including drag and release, just like ORDER mode.
 BOOL secondary=(self.pendingClickDelivery?self.forceSecondary:(self.forceSecondary || DEGlobalTouchCommandMode || (self.gameButtonMask & UIEventButtonMaskSecondary))) && (type==1 || type==2 || type==6);
 NSUInteger eventType=type==1?(secondary?3:1):type==2?(secondary?4:2):type==6?(secondary?7:6):type;
 id<DEGameMouseEvent> e=[NSClassFromString(@"NSEvent") new];
 CGPoint point=cancelled?CGPointMake(-100,-100):self.overrideActive?self.overridePoint:[touch locationInView:self.window];
 e.type=eventType;e.locationInWindow=point;e.timestamp=self.overrideActive?NSProcessInfo.processInfo.systemUptime:touch.timestamp;e.modifierFlags=0;e.buttonNumber=secondary?1:0;e.clickCount=type==5?0:self.gameClickCount;e.pressure=(type==2 || type==5)?0:1;
 e.window=((id(*)(id,SEL))objc_msgSend)(owner,sel_registerName("window"));
 e.windowNumber=((NSInteger(*)(id,SEL))objc_msgSend)(e.window,sel_registerName("windowNumber"));
 id content=((id(*)(id,SEL))objc_msgSend)(e.window,sel_registerName("contentView"));
 UIView *contentHost=((id(*)(id,SEL))objc_msgSend)(content,sel_registerName("deHost"));
 CGPoint contentPoint=cancelled?CGPointMake(-100,-100):self.overrideActive?[self.window convertPoint:self.overridePoint toView:contentHost]:[touch locationInView:contentHost];
 e.locationInWindow=CGPointMake(contentPoint.x-contentHost.bounds.origin.x,CGRectGetMaxY(contentHost.bounds)-contentPoint.y);
 e.deltaX=type==6?(point.x-self.previousTouchPoint.x):0;e.deltaY=type==6?(point.y-self.previousTouchPoint.y):0;
 static NSInteger sequence=0;e.eventNumber=++sequence;self.previousTouchPoint=point;
 if(verbose)DELogSynthesizedMouse(type,e,self.gameButtonMask,action);
 if (secondary) fprintf(stderr,"DE_TOUCH_COMMAND_EVENT phase=%lu event_type=%lu button_number=%ld\n",(unsigned long)type,(unsigned long)eventType,(long)e.buttonNumber);
 if(verbose)fprintf(stderr,"DE_GAME_TOUCH type=%lu action=%s view=%s x=%g y=%g taps=%lu cancelled=%d\n",(unsigned long)type,sel_getName(action),object_getClassName(owner),point.x,point.y,(unsigned long)touch.tapCount,cancelled);
 id app=((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"NSApplication"),sel_registerName("sharedApplication"));
 DEPendingTouchClick *click=self.pendingClickContext;
 CGPoint cancelledPoint=CGPointMake(-100,CGRectGetMaxY(contentHost.bounds)+100);
 void (^post)(void)=^{
     // Ordered delivery may retain an event past the click's 60 ms timer.
     // Recheck at posting, including a down queued behind an earlier click.
     if(click.HUDProfileIdentity && ![click.HUDProfileIdentity isEqual:DEHUDInputRegionsIdentityForBounds(self.bounds)])click.cancelled=YES;
     if(click.cancelled){e.locationInWindow=cancelledPoint;e.deltaX=0;e.deltaY=0;}
     ((void(*)(id,SEL,id,BOOL))objc_msgSend)(app,sel_registerName("postEvent:atStart:"),e,NO);
     if(click && type==2)[self.pendingClicks removeObjectIdenticalTo:click];
     if(verbose)fprintf(stderr,"DE_GAME_TOUCH_ENQUEUED type=%lu\n",(unsigned long)type);
 };
 DEPostOrderedMouseEvent((id)e,self.gameLayer,post);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
 if(!self.HUDTouches)self.HUDTouches=[NSHashTable weakObjectsHashTable];
 for(UITouch *touch in touches) {
     [self.HUDTouches removeObject:touch];
     if([self pointInHUDInputRegion:[touch locationInView:self.window]])[self.HUDTouches addObject:touch];
 }
 NSSet<UITouch *> *hostTouches=[self hostTouches:event];
 if(self.HUDInputConsumed) {
     BOOL older=NO;for(UITouch *touch in hostTouches)
         if(![touches containsObject:touch] && touch.phase!=UITouchPhaseEnded && touch.phase!=UITouchPhaseCancelled)older=YES;
     if(older)return;self.HUDInputConsumed=NO;
 }
 NSUInteger activeCount=0;BOOL hasHUD=NO;UITouch *HUDTouch=nil;
 for(UITouch *touch in hostTouches)if(touch.phase!=UITouchPhaseEnded && touch.phase!=UITouchPhaseCancelled) {
     activeCount++;if([self.HUDTouches containsObject:touch]){hasHUD=YES;HUDTouch=touch;}
 }
 if(hasHUD && activeCount>1) {
     [self cancelHostInput:nil];self.HUDInputConsumed=YES;return;
 }
 if(HUDTouch && !self.gameTouch) {
     [self cancelNativeGestures];DEGlobalTouchCommandMode=NO;DEPencilOrderArmed=NO;DERefreshTouchCommandButtons();
     self.gameTouch=HUDTouch;self.gameTouchIsHUD=YES;self.gameClickCount=1;self.gameButtonMask=0;
     self.pencilPending=YES;self.pencilDragging=NO;self.pencilStart=[HUDTouch locationInView:self.window];
     self.HUDContactIdentity=DEHUDInputRegionsIdentityForBounds(self.bounds);
     CGPoint local=[self convertPoint:self.pencilStart fromView:self.window];
     for(NSValue *region in [self HUDInputRegions])if(CGRectContainsPoint(region.CGRectValue,local)){self.HUDContactRegion=region.CGRectValue;break;}
     [self sendGameMouse:5 touch:HUDTouch cancelled:NO];return;
 }
 if(self.commandWheel || self.wheelConsumed) {
     // A second contact cancels a held wheel. Consume the remaining sequence;
     // a genuinely new sequence after a system cancellation can start normally.
     BOOL older=NO;
     for(UITouch *touch in [self mapTouches:event])
         if(![touches containsObject:touch] && touch.phase!=UITouchPhaseEnded && touch.phase!=UITouchPhaseCancelled)older=YES;
     if(self.commandWheel || older){[self cancelTouchCommandWheel];self.wheelConsumed=YES;return;}
     self.wheelConsumed=NO;
 }
 // Second finger on the map soon after the first (and neither a Pencil): a
 // two-finger tap candidate. Undo anything the first finger started.
 // Only touches on the game view count: a finger holding a side button
 // (ZOOM, R-CLICK…) must not turn a map tap into a two-finger order.
 NSSet<UITouch *> *mapTouches=[self mapTouches:event];
 UITouch *first=self.gameTouch?:touches.anyObject;
 BOOL fingers=YES;for(UITouch *t in mapTouches)if(t.type!=UITouchTypeDirect)fingers=NO;
 if(fingers && mapTouches.count>=2 && !self.twoFingerCandidate &&
    event.timestamp-(self.gameTouch?self.pencilStartTime:event.timestamp)<DETwoFingerWindow &&
    // Once the first finger's press has begun in a match, the second finger
    // can't turn it into an order without leaving a drag behind.
    (!self.gameTouch || self.pencilPending || !DEPencilMatchActive())) {
     self.twoFingerCandidate=YES;self.twoFingerFailed=NO;self.twoFingerCount=mapTouches.count;
     self.twoFingerStart=self.gameTouch?self.pencilStartTime:event.timestamp;
     self.twoFingerPoint=[first locationInView:self.window];
     self.twoFingerStarts=[NSMutableDictionary dictionary];
     for(UITouch *t in mapTouches)self.twoFingerStarts[[NSValue valueWithNonretainedObject:t]]=[NSValue valueWithCGPoint:[t locationInView:self.window]];
     if(self.gameTouch && self.pencilPending){self.pencilPending=NO;}
     else if(self.gameTouch){[self sendGameMouse:6 touch:self.gameTouch cancelled:YES];[self sendGameMouse:2 touch:self.gameTouch cancelled:YES];}
     self.pencilDragging=NO;self.gameTouch=nil;
     fprintf(stderr,"DE_TWO_FINGER begin touches=%lu\n",(unsigned long)mapTouches.count);
     return;
 }
 if(self.twoFingerCandidate){self.twoFingerCount=MAX(self.twoFingerCount,mapTouches.count);return;}
 if(self.gameTouch)return;self.gameTouch=touches.anyObject;self.pencilStartTime=self.gameTouch.timestamp;
 // Simulator mouse-backed touches can report tapCount=0 on release after
 // reporting 1 on press. Preserve the click identity across the mouse pair.
 self.gameClickCount=MAX((NSInteger)self.gameTouch.tapCount,1);
 self.gameButtonMask=event.buttonMask;DELogButtonMask(event,1,self.gameButtonMask);
 self.pencilPending=NO;self.pencilDragging=NO;
 BOOL pencil=self.gameTouch.type==UITouchTypePencil;
 BOOL wheelCandidate=self.gameTouch.type==UITouchTypeDirect && event.buttonMask==0 && [self canBeginTouchCommandWheel];
 BOOL defer=!DEGlobalTouchCommandMode && DEPencilMatchActive() &&
     ((pencil && getenv("AGEPAD_PENCIL_STICKY_ORDER")) || (!pencil && (getenv("AGEPAD_TOUCH_DEFER_PRESS") || wheelCandidate)));
 if(defer) {
     // In a match, decide the button when the gesture resolves. Fingers wait
     // briefly so a second finger (two-finger order tap) never leaves a stray
     // left click or selection box behind; the Pencil waits for tap/hold/drag.
     self.pencilPending=YES;self.pendingIsPencil=pencil;
     self.pencilStart=[self.gameTouch locationInView:self.window];self.pencilStartTime=self.gameTouch.timestamp;
     [self sendGameMouse:5 touch:self.gameTouch cancelled:NO];
     if(!pencil) {
         UITouch *touch=self.gameTouch;
         NSUInteger generation=++self.wheelGeneration;
         // DETwoFingerWindow covers the gap between the two fingers of an
         // order tap, even a slow one, so the first finger is cancelled
         // instead of clicking (deselecting). Moving starts a drag at once.
         NSTimeInterval delay=wheelCandidate?DECommandWheelHoldDuration:DETwoFingerWindow;
         dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
             if(self.pencilPending && self.gameTouch==touch && self.wheelGeneration==generation) {
                 if(wheelCandidate && [self canBeginTouchCommandWheel] && ![self pencilPointInHUD:self.pencilStart])
                     [self beginTouchCommandWheel:YES];
                 else {[self commitPendingPress];fprintf(stderr,"DE_TOUCH_DEFERRED_PRESS reason=held\n");}
             }
         });
     }
     return;
 }
 // A touch can relocate the virtual pointer without a hardware hover phase.
 // Preserve AppKit's move-before-button ordering at the same actual point.
 if(getenv("AGEPAD_TOUCH_MOVE_BEFORE_DOWN")) [self sendGameMouse:5 touch:self.gameTouch cancelled:NO];
 [self sendGameMouse:1 touch:self.gameTouch cancelled:NO];
}
// Touches on the game view itself (not on the side buttons).
- (NSSet<UITouch *> *)mapTouches:(UIEvent *)event {
 return [[self hostTouches:event] objectsPassingTest:^BOOL(UITouch *t,BOOL *stop){return ![self.HUDTouches containsObject:t];}];
}
- (NSSet<UITouch *> *)hostTouches:(UIEvent *)event {
 return [event.allTouches objectsPassingTest:^BOOL(UITouch *t,BOOL *stop){
     if(!t.view || ![t.view isDescendantOfView:self])return NO;
     for(UIView *view=t.view;view && view!=self;view=view.superview)
         if([view isKindOfClass:UIControl.class])return NO;
     return YES; }];
}
- (BOOL)hostTouchesAllUp:(UIEvent *)event {
 for(UITouch *touch in [self hostTouches:event])if(touch.phase!=UITouchPhaseEnded && touch.phase!=UITouchPhaseCancelled)return NO;
 return YES;
}
- (BOOL)mapTouchesAllUp:(UIEvent *)event {
 for(UITouch *t in [self mapTouches:event])if(t.phase!=UITouchPhaseEnded && t.phase!=UITouchPhaseCancelled)return NO;
 return YES;
}
// Left button down at the original contact point; the gesture continues as a
// normal press/drag (selection box) and releases in touchesEnded.
- (void)commitPendingPress {
 self.wheelGeneration++;
 self.pencilPending=NO;self.pencilDragging=YES;self.gameClickCount=1;
 self.overrideActive=YES;self.overridePoint=self.pencilStart;
 [self sendGameMouse:5 touch:self.gameTouch cancelled:NO];[self sendGameMouse:1 touch:self.gameTouch cancelled:NO];
 self.overrideActive=NO;
}
// A complete single click at the original contact point with a real ~60 ms
// press. A same-instant down/up pair (or tapCount>1 double-clicks from quick
// repeated taps) was not handled as a plain click by the engine.
- (void)deliverPendingClick:(DEPendingTouchClick *)click type:(NSUInteger)type cancelled:(BOOL)cancelled {
 BOOL override=self.overrideActive,secondary=self.forceSecondary,delivery=self.pendingClickDelivery;
 DEPendingTouchClick *context=self.pendingClickContext;
 CGPoint point=self.overridePoint;NSInteger count=self.gameClickCount;
 self.gameClickCount=1;self.overrideActive=YES;self.overridePoint=click.point;
 self.forceSecondary=click.secondary;self.pendingClickDelivery=YES;self.pendingClickContext=click;
 [self sendGameMouse:type touch:click.touch cancelled:cancelled];
 self.gameClickCount=count;self.overrideActive=override;self.overridePoint=point;
 self.forceSecondary=secondary;self.pendingClickDelivery=delivery;self.pendingClickContext=context;
}
- (void)finishPendingClick:(DEPendingTouchClick *)click cancelled:(BOOL)cancelled {
 NSUInteger index=[self.pendingClicks indexOfObjectIdenticalTo:click];
 if(index==NSNotFound)return;
 if(cancelled)click.cancelled=YES;
 // Keep the token until its up actually posts. Cancellation can then relocate
 // that same queued up, even after the timer has handed it to ordered delivery.
 if(click.releaseQueued)return;
 click.releaseQueued=YES;
 if(cancelled)[self deliverPendingClick:click type:6 cancelled:YES];
 [self deliverPendingClick:click type:2 cancelled:cancelled];
}
- (void)sendPendingClick:(BOOL)secondary {
 UITouch *touch=self.gameTouch;CGPoint point=self.pencilStart;
 if(!touch)return;
 // Keep each pair independently: another quick tap may arrive before its up.
 DEPendingTouchClick *click=[DEPendingTouchClick new];click.touch=touch;click.point=point;click.secondary=secondary;
 if(self.gameTouchIsHUD)click.HUDProfileIdentity=self.HUDContactIdentity;
 if(!self.pendingClicks)self.pendingClicks=[NSMutableArray new];
 [self.pendingClicks addObject:click];
 extern void DEUIKitPinPointer(CGPoint windowPoint,NSTimeInterval seconds);
 DEUIKitPinPointer(point,0.25);
 [self deliverPendingClick:click type:5 cancelled:NO];[self deliverPendingClick:click type:1 cancelled:NO];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
     [self finishPendingClick:click cancelled:NO];
 });
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
 if(self.HUDInputConsumed)return;
 if(self.gameTouchIsHUD) {
     if(![self HUDContactIsValid])[self cancelHostInput:nil];
     return;
 }
 if(self.wheelConsumed) {
     if(self.commandWheel && self.wheelTouchDriven && [touches containsObject:self.gameTouch])
         [self updateTouchCommandWheel];
     return;
 }
 if(self.twoFingerCandidate) {
     // A pinch or scroll moves the fingers; a tap barely does.
     for(UITouch *t in touches){NSValue *s=self.twoFingerStarts[[NSValue valueWithNonretainedObject:t]];
         CGPoint a=s.CGPointValue,b=[t locationInView:self.window];
         if(s && hypot(b.x-a.x,b.y-a.y)>30)self.twoFingerFailed=YES;}
     return;
 }
 if(self.pencilPending && self.gameTouch && [touches containsObject:self.gameTouch]) {
     CGPoint now=[self.gameTouch locationInView:self.window];
     if(hypot(now.x-self.pencilStart.x,now.y-self.pencilStart.y)<8){[self sendGameMouse:5 touch:self.gameTouch cancelled:NO];return;}
     [self commitPendingPress]; // Drag: selection box from the original point.
 }
 if(!self.gameTouch || ![touches containsObject:self.gameTouch])return;
 // Coalesce drags to at most one per 1/60 s. Apple Pencil reports up to 240 Hz,
 // faster than the game consumes mouse events, so a queue built up and box
 // selection lagged behind the tip. touchesEnded sends the final position.
 NSTimeInterval now=self.gameTouch.timestamp;
 if(now-self.lastDragSent<1.0/60.0)return;
 self.lastDragSent=now;
 if(DEInputVerbose(6))DELogButtonMask(event,6,self.gameButtonMask);
 [self sendGameMouse:6 touch:self.gameTouch cancelled:NO];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
 if(self.HUDInputConsumed){if([self hostTouchesAllUp:event]){self.HUDInputConsumed=NO;self.wheelConsumed=NO;}return;}
 if(self.gameTouchIsHUD) {
     if(![touches containsObject:self.gameTouch])return;
     if([self HUDContactIsValid])[self sendPendingClick:NO];else [self cancelHostInput:nil];
     self.gameTouch=nil;self.gameTouchIsHUD=NO;self.pencilPending=NO;self.HUDContactIdentity=nil;
     if([self hostTouchesAllUp:event]){self.HUDInputConsumed=NO;self.wheelConsumed=NO;}
     return;
 }
 if(self.wheelConsumed) {
     if(self.commandWheel && self.wheelTouchDriven && [touches containsObject:self.gameTouch]) {
         [self updateTouchCommandWheel];
         [self performWheelAction:self.commandWheel.selectedAction];
     }
     if([self mapTouchesAllUp:event])self.wheelConsumed=NO;
     return;
 }
 if(self.twoFingerCandidate) {
     if(![self mapTouchesAllUp:event])return;
     NSTimeInterval held=event.timestamp-self.twoFingerStart;
     BOOL order=!self.twoFingerFailed && self.twoFingerCount==2 && held<1.0;
     fprintf(stderr,"DE_TWO_FINGER end order=%d held=%.2f touches=%lu moved=%d\n",order,held,(unsigned long)self.twoFingerCount,self.twoFingerFailed);
     self.twoFingerCandidate=NO;self.twoFingerStarts=nil;
     if(order){DEMenuOpen=NO;self.pencilStart=self.twoFingerPoint;self.gameTouch=touches.anyObject;[self sendPendingClick:YES];self.gameTouch=nil;
         DEGlobalTouchCommandMode=NO;DERefreshTouchCommandButtons();}
     return;
 }
 if(self.pencilPending && self.gameTouch && [touches containsObject:self.gameTouch]) {
     BOOL hud=[self pencilPointInHUD:self.pencilStart];
     NSTimeInterval held=self.gameTouch.timestamp-self.pencilStartTime;
     BOOL order=NO;const char *reason;
     // Only a Pencil selection makes later Pencil taps orders: after finger
     // taps, picking up the Pencil and tapping a unit selects it.
     if(!self.pendingIsPencil){reason="finger";DEPencilOrderArmed=NO;}
     else if(hud){DEPencilOrderArmed=NO;reason="hud";}
     else if(held>=0.45){DEPencilOrderArmed=NO;reason="hold";}
     else if(DEPencilOrderArmed){order=YES;reason="order";}
     else {DEPencilOrderArmed=YES;reason="select";}
     if(order)DEMenuOpen=NO;
     else if(!hud)DESetMaybeSelected(YES);
     [self sendPendingClick:order];
     self.pencilPending=NO;self.gameTouch=nil;
     fprintf(stderr,"DE_PENCIL_TAP kind=%s held=%.2f armed=%d\n",reason,held,DEPencilOrderArmed);
     return;
 }
 if(self.pencilDragging && self.gameTouch && [touches containsObject:self.gameTouch]) {
     self.pencilDragging=NO;
     NSTimeInterval held=self.gameTouch.timestamp-self.pencilStartTime;
     CGPoint end=[self.gameTouch locationInView:self.window];
     BOOL box=hypot(end.x-self.pencilStart.x,end.y-self.pencilStart.y)>=8;
     // A Pencil drag-box selects and arms orders (a finger box doesn't); a
     // long press without movement behaves like a Pencil hold and disarms.
     DEPencilOrderArmed=box?(self.pendingIsPencil && ![self pencilPointInHUD:self.pencilStart]):(held<0.45 && DEPencilOrderArmed);
     if(box){DEMenuOpen=NO;DESetMaybeSelected(YES);}
     fprintf(stderr,"DE_PENCIL_DRAG box=%d armed=%d\n",box,DEPencilOrderArmed);
 }
 if(self.gameTouch && [touches containsObject:self.gameTouch]) DELogButtonMask(event,2,self.gameButtonMask);
 if(self.gameTouch && [touches containsObject:self.gameTouch]){
     // UIKit may coalesce a short drag into begin/end (also seen in Simulator).
     // Commit its final position before mouseUp so the original engine sees
     // the selection rectangle even when no touchesMoved callback was delivered.
     CGPoint finalPoint=[self.gameTouch locationInView:self.window];
     if(hypot(finalPoint.x-self.previousTouchPoint.x,finalPoint.y-self.previousTouchPoint.y)>1.0)
         [self sendGameMouse:6 touch:self.gameTouch cancelled:NO];
     [self sendGameMouse:2 touch:self.gameTouch cancelled:NO];self.gameTouch=nil;if(DEGlobalTouchCommandMode){DEGlobalTouchCommandMode=NO;DERefreshTouchCommandButtons();fprintf(stderr,"DE_TOUCH_COMMAND_MODE mode=select reason=target-complete\n");}}
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
 if(self.gameTouchIsHUD || self.HUDInputConsumed) {
     [self cancelHostInput:nil];if([self hostTouchesAllUp:event]){self.HUDInputConsumed=NO;self.wheelConsumed=NO;}return;
 }
 self.wheelGeneration++;
 if(self.wheelConsumed || self.commandWheel) {
     [self cancelTouchCommandWheel];
     if([self mapTouchesAllUp:event])self.wheelConsumed=NO;
     return;
 }
 if(self.twoFingerCandidate){ // a pinch or map scroll took over
     if([self mapTouchesAllUp:event]){self.twoFingerCandidate=NO;self.twoFingerStarts=nil;}
     return;
 }
 if(self.pencilPending && self.gameTouch && [touches containsObject:self.gameTouch]) {
     self.pencilPending=NO;self.gameTouch=nil; // No button was pressed yet.
     fprintf(stderr,"DE_TOUCH_DEFERRED_CANCELLED\n");return;
 }
 self.pencilDragging=NO;
 if(self.gameTouch && [touches containsObject:self.gameTouch]) DELogButtonMask(event,2,self.gameButtonMask);
 if(self.gameTouch && [touches containsObject:self.gameTouch]){[self sendGameMouse:6 touch:self.gameTouch cancelled:YES];[self sendGameMouse:2 touch:self.gameTouch cancelled:YES];self.gameTouch=nil;if(DEGlobalTouchCommandMode){DEGlobalTouchCommandMode=NO;DERefreshTouchCommandButtons();fprintf(stderr,"DE_TOUCH_COMMAND_MODE mode=select reason=cancelled\n");}}
}
- (BOOL)pencilPointInHUD:(CGPoint)windowPoint {
    // DE's top resource bar and bottom command panel/minimap bands.
    CGPoint local=[self convertPoint:windowPoint fromView:self.window];CGFloat h=self.bounds.size.height;
    return [self pointInHUDInputRegion:windowPoint] || local.y<h*0.05 || local.y>h*0.83;
}
- (NSArray<NSValue *> *)HUDInputRegions { return DEHUDInputRegionsForBounds(self.bounds); }
- (BOOL)pointInHUDInputRegion:(CGPoint)windowPoint {
    CGPoint local=[self convertPoint:windowPoint fromView:self.window];
    for(NSValue *region in [self HUDInputRegions])if(CGRectContainsPoint(region.CGRectValue,local))return YES;
    return NO;
}
- (BOOL)HUDContactIsValid {
    CGPoint point=[self.gameTouch locationInView:self.window],local=[self convertPoint:point fromView:self.window];
    return self.HUDContactIdentity && [self.HUDContactIdentity isEqual:DEHUDInputRegionsIdentityForBounds(self.bounds)] &&
        CGRectContainsPoint(self.HUDContactRegion,local) && hypot(point.x-self.pencilStart.x,point.y-self.pencilStart.y)<=8;
}
- (NSArray<NSValue *> *)activeTouchReservedRects {
    NSMutableArray<NSValue *> *rects=[NSMutableArray new];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270100
    if (@available(iOS 27.1,*)) {
        for (UIViewReservedRegionKind *kind in @[UIViewReservedRegionKind.divisionRegionKind,UIViewReservedRegionKind.occlusionRegionKind])
            for (UIViewReservedRegion *region in [self reservedRegionsOfKind:kind options:UIViewReservedRegionQueryOptionsNone]) {
                CGRect frame=CGRectIntersection(self.bounds,region.frame);
                if (region.isActive && !CGRectIsEmpty(frame) && !CGRectIsNull(frame)) {
                    NSValue *value=[NSValue valueWithCGRect:frame];
                    if (![rects containsObject:value]) [rects addObject:value];
                }
            }
    }
#endif
    // Query enumeration order is not a geometry change.
    [rects sortUsingComparator:^NSComparisonResult(NSValue *a,NSValue *b) {
        CGRect x=a.CGRectValue,y=b.CGRectValue;
        CGFloat av[]={x.origin.x,x.origin.y,x.size.width,x.size.height};
        CGFloat bv[]={y.origin.x,y.origin.y,y.size.width,y.size.height};
        for (NSUInteger i=0;i<4;i++) { if(av[i]<bv[i])return NSOrderedAscending;if(av[i]>bv[i])return NSOrderedDescending; }
        return NSOrderedSame;
    }];
    return rects;
}
- (NSArray<NSValue *> *)touchControlRegions {
    CGFloat scale=[self touchCoordinateScale];
    CGRect safe=CGRectInset(UIEdgeInsetsInsetRect(self.bounds,self.safeAreaInsets),8*scale,8*scale);
    return DEClearControlRects(safe,[[self activeTouchReservedRects] arrayByAddingObjectsFromArray:[self HUDInputRegions]]);
}
- (CGRect)wheelRegionNearPoint:(CGPoint)point {
    CGFloat diameter=(2*DECommandWheelMinimumRadius+24)*[self touchCoordinateScale];
    return DEControlRegionNearPoint([self touchControlRegions],CGSizeMake(diameter,diameter),point);
}
- (BOOL)usesCompactTouchControls {
    CGRect safe=UIEdgeInsetsInsetRect(self.bounds,self.safeAreaInsets);
    CGFloat scale=[self touchCoordinateScale];
    CGRect strip=DEControlRegionNearPoint([self touchControlRegions],CGSizeMake(76*scale,356*scale),CGPointMake(CGRectGetMaxX(safe),CGRectGetMidY(safe)));
    return DEUseCompactControls(safe.size.width/scale,safe.size.height/scale) || CGRectIsNull(strip);
}
- (CGFloat)touchCoordinateScale {
    CGSize viewport=self.window.rootViewController.view.bounds.size;
    return 1/DEGameCanvasFit(viewport);
}
- (BOOL)canBeginTouchCommandWheel {
    return self.commandWheelButton && [self usesCompactTouchControls] && DEPencilMatchActive() && !DEMenuOpen &&
           !CGRectIsNull([self wheelRegionNearPoint:[self convertPoint:self.pencilStart fromView:self.window]]);
}
- (void)showTouchCommandWheel:(UIButton *)sender {
    if(self.commandWheel){[self cancelTouchCommandWheel];return;}
    if(DEGlobalTouchCommandMode){DEGlobalTouchCommandMode=NO;DERefreshTouchCommandButtons();return;}
    // Accessible alternative to a timed gesture; ORDER arms the next map tap.
    [self cancelHostInput:nil];
    [self beginTouchCommandWheel:NO];
}
- (void)beginTouchCommandWheel:(BOOL)touchDriven {
    CGPoint point=touchDriven?[self convertPoint:self.pencilStart fromView:self.window]:self.commandWheelButton.center;
    CGRect safe=[self wheelRegionNearPoint:point];
    if(CGRectIsNull(safe)) {
        if (!touchDriven) {
            // System presentations adapt when a tiny split window cannot fit
            // a radial wheel. Every command remains reachable from COMMANDS.
            UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Game commands" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *titles=@[@"Order on next map tap",@"Select idle villager",@"Select town center",@"Zoom in",@"Zoom out",@"Game menu"];
            __weak DEGameViewHost *weakSelf=self;
            for(NSInteger i=0;i<DECommandWheelActionCount;i++)
                [menu addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf performWheelAction:(DECommandWheelAction)i];}]];
            [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            menu.popoverPresentationController.sourceView=self.commandWheelButton;
            menu.popoverPresentationController.sourceRect=self.commandWheelButton.bounds;
            UIViewController *presenter=self.window.rootViewController;
            while(presenter.presentedViewController)presenter=presenter.presentedViewController;
            [presenter presentViewController:menu animated:YES completion:nil];
        }
        return;
    }
    self.wheelGeneration++;self.pencilPending=NO;self.pencilDragging=NO;
    self.wheelTouchDriven=touchDriven;self.wheelAnchor=self.pencilStart;
    self.wheelConsumed=self.wheelConsumed || touchDriven;
    CGFloat coordinateScale=[self touchCoordinateScale];
    CGRect wheelBounds=CGRectMake(0,0,self.bounds.size.width/coordinateScale,self.bounds.size.height/coordinateScale);
    DETouchCommandWheelView *wheel=[[DETouchCommandWheelView alloc] initWithFrame:wheelBounds];
    wheel.transform=CGAffineTransformMakeScale(coordinateScale,coordinateScale);
    wheel.center=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds));
    self.commandWheel=wheel;wheel.userInteractionEnabled=!touchDriven;
    [wheel placeAtPoint:CGPointMake(point.x/coordinateScale,point.y/coordinateScale)
              safeRect:CGRectMake(safe.origin.x/coordinateScale,safe.origin.y/coordinateScale,safe.size.width/coordinateScale,safe.size.height/coordinateScale)];
    if(!touchDriven)wheel.actionButtons[DECommandWheelOrder].accessibilityLabel=@"Order on next map tap";
    __weak DEGameViewHost *weakSelf=self;
    wheel.actionHandler=^(DECommandWheelAction action){[weakSelf performWheelAction:action];};
    [self addSubview:wheel];
    if(touchDriven) {
        UISelectionFeedbackGenerator *feedback=[UISelectionFeedbackGenerator new];[feedback selectionChanged];
    } else UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,wheel.actionButtons.firstObject);
    fprintf(stderr,"DE_COMMAND_WHEEL opened source=%s\n",touchDriven?"hold":"button");
}
- (void)updateTouchCommandWheel {
    // Clamping the drawing must not turn a stationary hold at a screen edge
    // into a command. Choose by displacement from the original contact.
    CGPoint start=[self convertPoint:self.wheelAnchor fromView:self.window];
    CGPoint point=[self.gameTouch locationInView:self];
    CGFloat scale=[self touchCoordinateScale];
    [self.commandWheel trackPoint:CGPointMake(self.commandWheel.wheelCenter.x+(point.x-start.x)/scale,
                                              self.commandWheel.wheelCenter.y+(point.y-start.y)/scale)];
}
- (void)cancelTouchCommandWheel {
    self.wheelGeneration++;
    BOOL wasOpen=self.commandWheel!=nil;
    [self.commandWheel removeFromSuperview];self.commandWheel=nil;
    if(self.wheelTouchDriven){self.gameTouch=nil;self.pencilPending=NO;self.pencilDragging=NO;}
    self.wheelTouchDriven=NO;
    if(wasOpen)fprintf(stderr,"DE_COMMAND_WHEEL closed\n");
}
- (void)performWheelAction:(DECommandWheelAction)action {
    if(self.commandWheel && self.lastInputReservedRects && ![self.lastInputReservedRects isEqualToArray:[self activeTouchReservedRects]]) {
        [self cancelHostInput:nil];[self setNeedsLayout];return;
    }
    BOOL held=self.wheelTouchDriven;UITouch *touch=self.gameTouch;CGPoint anchor=self.wheelAnchor;
    [self cancelTouchCommandWheel];
    if(action==DECommandWheelNone)return;
    if(action==DECommandWheelOrder) {
        if(held && touch) {
            DEMenuOpen=NO;self.gameTouch=touch;self.pencilStart=anchor;
            [self sendPendingClick:YES];self.gameTouch=nil;
            DEGlobalTouchCommandMode=NO;
        } else DEGlobalTouchCommandMode=YES;
        DERefreshTouchCommandButtons();
    } else if(action==DECommandWheelZoomIn || action==DECommandWheelZoomOut) {
        [self nativeMouse:22 point:CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds)) wheel:action==DECommandWheelZoomIn?1:-1];
    } else {
        NSUInteger index=action==DECommandWheelIdle?0:action==DECommandWheelTown?1:4;
        [self touchShortcut:self.touchShortcutButtons[index]];
    }
    fprintf(stderr,"DE_COMMAND_WHEEL action=%ld source=%s\n",(long)action,held?"hold":"button");
}
- (void)cancelHostInput:(NSNotification *)note {
    if([note.object isKindOfClass:UIWindow.class] && note.object!=self.window)return;
    self.wheelGeneration++;
    self.HUDInputConsumed=self.HUDInputConsumed || self.gameTouchIsHUD;
    for(DEPendingTouchClick *click in [self.pendingClicks copy])[self finishPendingClick:click cancelled:YES];
    if(self.gameTouch || self.commandWheel) {
        if(!self.gameTouchIsHUD)self.wheelConsumed=self.gameTouch!=nil || self.wheelConsumed;
        if(self.commandWheel)[self cancelTouchCommandWheel];
        else if(self.gameTouch && !self.pencilPending) {
            [self sendGameMouse:6 touch:self.gameTouch cancelled:YES];
            [self sendGameMouse:2 touch:self.gameTouch cancelled:YES];
        }
    }
    self.gameTouch=nil;self.pencilPending=NO;self.pencilDragging=NO;
    self.gameTouchIsHUD=NO;self.HUDContactIdentity=nil;
    self.twoFingerCandidate=NO;self.twoFingerStarts=nil;
    [self.zoomTimer invalidate];self.zoomTimer=nil;
    DEGlobalTouchCommandMode=NO;DERefreshTouchCommandButtons();
    [self cancelNativeGestures];
}
- (void)willMoveToWindow:(UIWindow *)newWindow {
    if(self.window && self.window!=newWindow)[self cancelHostInput:nil];
    [super willMoveToWindow:newWindow];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.reservedRegionTimer invalidate];self.reservedRegionTimer=nil;
    BOOL monitor=getenv("AGEPAD_HUD_INPUT_REGIONS")!=NULL;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270100
    if (@available(iOS 27.1,*))monitor=YES;
#endif
    if(monitor && self.window && self.commandWheelButton) {
        // UIKit exposes a query but no public reserved-region change callback.
        // Poll only attached overlays; camera activation need not resize them.
        __weak DEGameViewHost *weakSelf=self;
        self.reservedRegionTimer=[NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            DEGameViewHost *host=weakSelf;
            if(!host || !host.window){[timer invalidate];return;}
            NSString *HUDIdentity=DEHUDInputRegionsIdentityForBounds(host.bounds);
            if(![host.lastInputReservedRects isEqualToArray:[host activeTouchReservedRects]] ||
               ![(host.lastInputHUDIdentity?:@"") isEqual:(HUDIdentity?:@"")]) {
                [host cancelHostInput:nil];[host setNeedsLayout];
            }
        }];
        [NSRunLoop.mainRunLoop addTimer:self.reservedRegionTimer forMode:NSRunLoopCommonModes];
    }
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange];[self setNeedsLayout]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self];[self.zoomTimer invalidate];[self.reservedRegionTimer invalidate]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    NSArray<NSValue *> *reserved=[self activeTouchReservedRects];
    NSString *HUDIdentity=DEHUDInputRegionsIdentityForBounds(self.bounds);
    if(!CGRectIsEmpty(self.lastInputBounds) && (!CGRectEqualToRect(self.lastInputBounds,self.bounds) || !UIEdgeInsetsEqualToEdgeInsets(self.lastInputInsets,self.safeAreaInsets) || ![self.lastInputReservedRects isEqualToArray:reserved] || ![(self.lastInputHUDIdentity?:@"") isEqual:(HUDIdentity?:@"")]))
        [self cancelHostInput:nil];
    self.lastInputBounds=self.bounds;self.lastInputInsets=self.safeAreaInsets;self.lastInputReservedRects=reserved;
    self.lastInputHUDIdentity=HUDIdentity;
    if (self.gameLayer) {
        [CATransaction begin];[CATransaction setDisableActions:YES];
        self.gameLayer.frame=self.bounds;self.gameLayer.contentsScale=DERenderScaleForView(self);
        [CATransaction commit];
    }
    DEGameHostDidLayout(self);
    if (self.touchOrderButton) {
        CGFloat coordinateScale=[self touchCoordinateScale];
        CGRect safe=UIEdgeInsetsInsetRect(self.bounds,self.safeAreaInsets);
        BOOL compact=[self usesCompactTouchControls];
        NSArray<NSValue *> *regions=[self touchControlRegions];
        CGPoint preferred=CGPointMake(CGRectGetMaxX(safe)-62*coordinateScale,CGRectGetMidY(safe));
        CGRect entry=DEControlRegionNearPoint(regions,CGSizeMake(108*coordinateScale,96*coordinateScale),preferred);
        self.commandWheelButton.hidden=self.windowedPresentation || !compact || CGRectIsNull(entry);
        self.commandBackButton.hidden=self.windowedPresentation || CGRectIsNull(entry);
        if(!CGRectIsNull(entry)) {
            CGFloat y=MAX(CGRectGetMinY(entry),MIN(CGRectGetMaxY(entry)-96*coordinateScale,preferred.y-48*coordinateScale));
            self.commandWheelButton.transform=CGAffineTransformIdentity;
            self.commandWheelButton.bounds=CGRectMake(0,0,108,44);
            self.commandWheelButton.center=CGPointMake(CGRectGetMaxX(entry)-54*coordinateScale,y+22*coordinateScale);
            self.commandWheelButton.transform=CGAffineTransformMakeScale(coordinateScale,coordinateScale);
            self.commandBackButton.transform=CGAffineTransformIdentity;
            self.commandBackButton.bounds=CGRectMake(0,0,76,44);
            self.commandBackButton.center=CGPointMake(CGRectGetMaxX(entry)-38*coordinateScale,y+74*coordinateScale);
            self.commandBackButton.transform=CGAffineTransformMakeScale(coordinateScale,coordinateScale);
        }
        // Larger windows retain the original six-button strip. Compact windows
        // expose the same actions through a single thumb-sized entry point.
        CGFloat width=76*coordinateScale,height=44*coordinateScale,gap=8*coordinateScale;
        CGRect strip=DEControlRegionNearPoint(regions,CGSizeMake(width,7*height+6*gap),preferred);
        CGFloat x=0,y=0;
        if(!CGRectIsNull(strip)) {
            x=CGRectGetMaxX(strip)-width;
            y=MAX(CGRectGetMinY(strip),MIN(CGRectGetMaxY(strip)-(7*height+6*gap),preferred.y-(7*height+6*gap)/2));
        }
        NSArray *buttons=[@[self.touchOrderButton] arrayByAddingObjectsFromArray:self.touchShortcutButtons];
        if(self.commandBackButton && !compact)buttons=[buttons arrayByAddingObject:self.commandBackButton];
        for(NSUInteger i=0;i<buttons.count;i++) {
            UIButton *button=buttons[i];button.transform=CGAffineTransformIdentity;
            button.bounds=CGRectMake(0,0,76,44);button.center=CGPointMake(x+width/2,y+i*(height+gap)+height/2);
            button.transform=CGAffineTransformMakeScale(coordinateScale,coordinateScale);
            button.hidden=self.windowedPresentation || compact || CGRectIsNull(strip);
            [self bringSubviewToFront:button];
        }
        [self bringSubviewToFront:self.commandWheelButton];
        if(self.commandBackButton)[self bringSubviewToFront:self.commandBackButton];
        if(self.commandWheel)[self bringSubviewToFront:self.commandWheel];
    }
}
@end
@interface NSView : UIResponder
@property(nonatomic,strong) DEGameViewHost *deHost;
@property(nonatomic,strong) DEGameTrackingController *deTracking;
@property(nonatomic,weak) NSView *superview;
@property(nonatomic,weak) NSWindow *deWindow;
@property(nonatomic,strong) NSMutableArray<NSView *> *deSubviews;
@property(nonatomic) BOOL wantsLayer;
@property(nonatomic,weak) UIResponder *deNextResponder;
- (instancetype)initWithFrame:(CGRect)frame;
- (CGRect)frame;
- (void)setFrame:(CGRect)frame;
- (CGRect)bounds;
- (NSView *)hitTest:(CGPoint)point;
- (NSWindow *)window;
- (CALayer *)layer;
- (void)resetCursorRects;
@end
#ifndef AGEPAD_PUBLIC_API
#define AGEPAD_PUBLIC_API 0
#endif
#include "TrackingTypes.h"
#if !AGEPAD_PUBLIC_API
#include "LegacyWebViewHost.m"
#endif
@interface DEGameTrackingController : NSObject
@property(nonatomic,weak) UIView *host;
@property(nonatomic,strong) NSMutableArray<DEWebTrackingRecord *> *records;
- (void)hover:(UIHoverGestureRecognizer *)gesture;
@end
@implementation DEGameTrackingController
- (void)hover:(UIHoverGestureRecognizer *)gesture {
    UIView *host=self.host;
    CGPoint point=[gesture locationInView:host];
    BOOL ended=gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled;
    for (DEWebTrackingRecord *record in self.records.copy) {
        BOOL inside=!ended && CGRectContainsPoint([record.area rect],point);
        if (inside==record.inside) continue;
        record.inside=inside;
        SEL action=inside?@selector(mouseEntered:):@selector(mouseExited:);
        id owner=[record.area owner];
        if (![owner respondsToSelector:action]) continue;
        id<DEHoverEvent> event=[NSClassFromString(@"NSEvent") new];
        if (!event) DEUnsupported("game hover event unavailable");
        [event setType:inside?8:9];
        [event setLocationInWindow:[gesture locationInView:host.window]];
        [event setTimestamp:NSProcessInfo.processInfo.systemUptime];
        [event setTrackingArea:record.area];
        ((void(*)(id,SEL,id))objc_msgSend)(owner,action,event);
    }
}
@end

static UIView *DEHostView(id view) {
    if (!view) return nil;
    if ([view isKindOfClass:UIView.class]) return view;
    if ([view isKindOfClass:NSView.class]) return ((NSView *)view).deHost;
#if !AGEPAD_PUBLIC_API
    Class wak=NSClassFromString(@"WAKView");
    if (wak && [view isKindOfClass:wak]) return DELegacyHost(view);
#endif
    DEUnsupported("unsupported view host object");
}
static void DEUIKitWantsLayer(id view,SEL selector,BOOL wants) {
    if (!wants) DEUnsupported("UIKit view cannot disable layer backing");
    fprintf(stderr,"DE_UIKIT_NATIVE_VIEW_LAYER existing UIKit layer\n");
}
void DEInstallNativeViewCompatibility(void) {
    Class cls=NSClassFromString(@"CFeralNSWebView");
    fprintf(stderr,"DE_NATIVE_VIEW_CLASS present=%d parent=%s uiview=%d\n",cls!=Nil,cls?class_getName(class_getSuperclass(cls)):"none",cls?[cls isSubclassOfClass:UIView.class]:0);
#if !AGEPAD_PUBLIC_API
    Class wak=NSClassFromString(@"WAKView");
    if (cls && wak && [cls isSubclassOfClass:wak] && !DEExistingInstanceMethod(cls,@selector(setWantsLayer:)))
        class_addMethod(cls,@selector(setWantsLayer:),(IMP)DEWAKWantsLayer,"v@:B");
    if (cls && wak && [cls isSubclassOfClass:wak]) {
        if (!DEExistingInstanceMethod(cls,@selector(addTrackingArea:))) class_addMethod(cls,@selector(addTrackingArea:),(IMP)DEWAKAddTracking,"v@:@");
        if (!DEExistingInstanceMethod(cls,@selector(removeTrackingArea:))) class_addMethod(cls,@selector(removeTrackingArea:),(IMP)DEWAKRemoveTracking,"v@:@");
        if (!DEOriginalWebSetFrame) {
            Method method=DEExistingInstanceMethod(cls,@selector(setFrame:));
            if (!method) DEUnsupported("legacy web frame setter unavailable");
            DEOriginalWebSetFrame=method_getImplementation(method);
            class_replaceMethod(cls,@selector(setFrame:),(IMP)DEWAKSetFrame,method_getTypeEncoding(method));
        }
    }
#endif
    if (cls && [cls isSubclassOfClass:UIView.class] && !DEExistingInstanceMethod(cls,@selector(setWantsLayer:)))
        class_addMethod(cls,@selector(setWantsLayer:),(IMP)DEUIKitWantsLayer,"v@:B");
}
@interface NSWindow : UIResponder
@property(nonatomic,weak) id delegate;
@property(nonatomic,strong) NSView *contentView;
@property(nonatomic,strong) UIView *dePresentation;
@property(nonatomic,weak) UIWindow *deUIKitWindow;
@property(nonatomic,copy) NSString *title;
@property(nonatomic) NSUInteger styleMask;
@property(nonatomic) BOOL releasedWhenClosed,acceptsMouseMovedEvents;
@property(nonatomic,getter=isMovable) BOOL movable;
@property(nonatomic) NSInteger level,collectionBehavior;
@property(nonatomic) CGSize minSize,maxSize;
@property(nonatomic) CGRect deFrame;
@property(nonatomic) BOOL deVisible;
@property(nonatomic) CGRect deWindowedFrame;
@property(nonatomic) BOOL deFullScreenTransition;
@property(nonatomic) CGFloat deReportedBackingScale;
@property(nonatomic,strong) UIScreen *deReportedScreen;
@property(nonatomic) BOOL deProcessingHostResize;
@property(nonatomic) BOOL deLiveResize;
@property(nonatomic) NSInteger windowNumber;
@property(nonatomic,strong) id<DEColorObject> backgroundColor;
@property(nonatomic,weak) NSView *initialFirstResponder;
@property(nonatomic,weak) NSView *firstResponder;
@property(nonatomic,weak) id deMouseDownTarget;
- (void)update;
- (void)setFrame:(CGRect)frame display:(BOOL)display;
- (void)updatePresentation;
@end
static NSHashTable<NSWindow *> *DEGameWindows;
static __weak NSWindow *DEKeyGameWindow,*DEMainGameWindow;
static NSInteger DENextWindowNumber = 1;
#include "HardwareKeyMapping.h"
static void DEPostGameKeyWithModifiers(unsigned short macKey,NSString *characters,NSString *plain,NSUInteger flags,BOOL pressed) {
    NSTimeInterval timestamp=NSProcessInfo.processInfo.systemUptime;
    dispatch_async(dispatch_get_main_queue(),^{
        NSWindow *window=DEKeyGameWindow;
        if(!window || !window.deVisible || !window.deUIKitWindow.isKeyWindow)return;
        id<DEGameMouseEvent> event=[NSClassFromString(@"NSEvent") new];
        event.type=pressed?10:11;event.keyCode=macKey;
        event.characters=characters;event.charactersIgnoringModifiers=plain;
        event.modifierFlags=flags | ((characters.length && [characters characterAtIndex:0]>=0xF700)?(1UL<<23):0);
        event.timestamp=timestamp;event.window=window;
        id app=((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"NSApplication"),sel_registerName("sharedApplication"));
        ((void(*)(id,SEL,id,BOOL))objc_msgSend)(app,sel_registerName("postEvent:atStart:"),event,NO);
        if(getenv("AGEPAD_KEY_DELIVERY_TRACE"))fprintf(stderr,"DE_HARDWARE_KEY_ENQUEUED mac=%u pressed=%d flags=%lu\n",macKey,pressed,(unsigned long)flags);
    });
}
static void DEPostGameKey(unsigned short macKey, NSString *characters, BOOL pressed) {
    // Keys AgePad itself holds (map scrolling), so polled key state agrees.
    extern _Atomic unsigned char DEVirtualKeyHeld[128];
    if(macKey<128)DEVirtualKeyHeld[macKey]=pressed;
    DEPostGameKeyWithModifiers(macKey,characters,characters,0,pressed);
}
_Atomic unsigned char DEVirtualKeyHeld[128];
bool DEVirtualKeyIsHeld(uint16_t key) __attribute__((visibility("default")));
bool DEVirtualKeyIsHeld(uint16_t key) { return key<128 && DEVirtualKeyHeld[key]; }
static void DEConnectGameKeyboard(void) {
    GCKeyboardInput *keyboard=GCKeyboard.coalescedKeyboard.keyboardInput;
    if(!keyboard)return;
    keyboard.keyChangedHandler=^(GCKeyboardInput *input,GCControllerButtonInput *button,GCKeyCode code,BOOL pressed) {
        NSUInteger flags=0;
        // USB left/right modifier usages; preserve the AppKit modifier bits.
        if([input buttonForKeyCode:225].isPressed || [input buttonForKeyCode:229].isPressed)flags|=1UL<<17;
        if([input buttonForKeyCode:224].isPressed || [input buttonForKeyCode:228].isPressed)flags|=1UL<<18;
        if([input buttonForKeyCode:226].isPressed || [input buttonForKeyCode:230].isPressed)flags|=1UL<<19;
        if([input buttonForKeyCode:227].isPressed || [input buttonForKeyCode:231].isPressed)flags|=1UL<<20;
        unsigned short macKey;NSString *characters,*plain;
        if(!DEMapHardwareKey(code,(flags&(1UL<<17))!=0,&macKey,&plain,&characters))return;
        // Command-V is the only path that may read pasteboard contents.
        if(pressed && (flags&(1UL<<20)) && [plain isEqualToString:@"v"])DEArmUserPaste();
        DEPostGameKeyWithModifiers(macKey,characters,plain,flags,pressed);
    };
    fprintf(stderr,"DE_HARDWARE_KEYBOARD_CONNECTED layout=US letters_digits_punctuation_navigation_function_keys=1\n");
}
static void DEInstallGameKeyboard(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){DEConnectGameKeyboard();}];
        DEConnectGameKeyboard();
    });
}
static void DEPostWindowTransition(NSWindow *window,NSString *name,SEL action) {
    NSNotification *note=[NSNotification notificationWithName:name object:window];
    [NSNotificationCenter.defaultCenter postNotification:note];
    id delegate=window.delegate;
    if(delegate && DEHasMouseHandler(object_getClass(delegate),action))((void(*)(id,SEL,id))objc_msgSend)(delegate,action,note);
    fprintf(stderr,"DE_WINDOW_TRANSITION %s window=%p\n",name.UTF8String,(__bridge void*)window);
}
static void DEGameHostDidLayout(DEGameViewHost *host) {
    for(NSWindow *window in DEGameWindows.allObjects) {
        if(!window.deVisible || window.contentView.deHost!=host || window.deProcessingHostResize)continue;
        CGSize previous=window.deFrame.size;
        CGRect frame=window.deFrame;frame.size=host.bounds.size;
        if(window.styleMask & (1UL<<14)) {
            frame.origin=CGPointZero;
            frame.size=DEGameCanvasSize(window.deUIKitWindow.rootViewController.view.bounds.size);
        }
        BOOL resized=!CGSizeEqualToSize(previous,frame.size) || !CGSizeEqualToSize(host.bounds.size,frame.size);
        window.deProcessingHostResize=YES;
        if(resized) {
            // Feral's window consumes the live-resize pair rather than
            // windowDidResize:. Treat each committed UIKit layout as one
            // complete resize, including folds and multitasking changes.
            window.deLiveResize=YES;
            DEPostWindowTransition(window,@"NSWindowWillStartLiveResizeNotification",sel_registerName("windowWillStartLiveResize:"));
        }
        // Publish the new values before callbacks; the engine can query them
        // and lay out its child views while processing this notification.
        // Dispatch through the original NSWindow subclass: Feral caches its
        // pending render size in setFrame:display:. Updating only our adapter
        // ivar leaves that cache at the pre-fold aspect ratio.
        if(resized)[window setFrame:frame display:YES];
        else window.deFrame=frame;
        CGFloat oldScale=window.deReportedBackingScale,scale=DERenderScaleForView(host);
        window.deReportedBackingScale=scale;
        UIScreen *screen=window.deUIKitWindow.windowScene.screen ?: window.deUIKitWindow.screen;
        BOOL changedScreen=window.deReportedScreen && window.deReportedScreen!=screen;
        window.deReportedScreen=screen;
        if(changedScreen)
            DEPostWindowTransition(window,@"NSWindowDidChangeScreenNotification",sel_registerName("windowDidChangeScreen:"));
        if(resized)
            DEPostWindowTransition(window,@"NSWindowDidResizeNotification",sel_registerName("windowDidResize:"));
        if(oldScale>0 && oldScale!=scale) {
            NSNotification *note=[NSNotification notificationWithName:@"NSWindowDidChangeBackingPropertiesNotification" object:window
                                                           userInfo:@{@"NSBackingPropertyOldScaleFactorKey":@(oldScale)}];
            [NSNotificationCenter.defaultCenter postNotification:note];
            id delegate=window.delegate;SEL action=sel_registerName("windowDidChangeBackingProperties:");
            if(delegate && DEHasMouseHandler(object_getClass(delegate),action))((void(*)(id,SEL,id))objc_msgSend)(delegate,action,note);
        }
        if(resized) {
            window.deLiveResize=NO;
            DEPostWindowTransition(window,@"NSWindowDidEndLiveResizeNotification",sel_registerName("windowDidEndLiveResize:"));
        }
        window.deProcessingHostResize=NO;
    }
}
void DEUpdateVisibleGameWindows(void) {
    for(NSWindow *window in DEGameWindows.allObjects) if(window.deVisible) [window update];
}
@implementation NSView
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super init])) {
        _deHost=[[DEGameViewHost alloc] initWithFrame:frame];_deHost.backgroundColor=UIColor.clearColor;_deHost.originalView=self;
        _deSubviews=[NSMutableArray array];
    }return self;
}
- (CGRect)frame { return self.deHost.frame; }
- (void)setFrame:(CGRect)frame { self.deHost.frame=frame;[self.deHost setNeedsLayout];[self.deHost layoutIfNeeded];
    if(getenv("AGEPAD_LAYER_ATTACH_FLUSH")){[CATransaction flush];fprintf(stderr,"DE_LAYER_ATTACH_FLUSH actual transaction submitted\n");} }
- (void)setFrameOrigin:(CGPoint)origin { CGRect f=self.frame;f.origin=origin;self.frame=f; }
- (void)setFrameSize:(CGSize)size { CGRect f=self.frame;f.size=size;self.frame=f; }
- (CGRect)bounds { return self.deHost.bounds; }
- (void)setBounds:(CGRect)bounds { self.deHost.bounds=bounds;[self.deHost setNeedsLayout]; }
- (BOOL)isFlipped { return YES; } // Host view coordinates are UIKit top-left.
- (void)resetCursorRects { } // Base NSView defines no cursor regions.
- (BOOL)isHidden { return self.deHost.hidden; }
- (NSView *)hitTest:(CGPoint)point {
    if (self.deHost.hidden) return nil;
    // AppKit receives superview coordinates; UIKit performs the actual
    // frame/bounds conversion, including any host transform.
    CGPoint local=[self.deHost convertPoint:point fromView:self.deHost.superview];
    if (!CGRectContainsPoint(self.deHost.bounds,local)) return nil;
    for (id child in self.deSubviews.reverseObjectEnumerator) {
        if (![child isKindOfClass:NSView.class]) DEUnsupported("hit test for non-AppKit child");
        NSView *hit=[(NSView *)child hitTest:local];
        if (hit) return hit;
    }
    fprintf(stderr,"DE_VIEW_HIT view=%s x=%g y=%g\n",object_getClassName(self),local.x,local.y);
    return self;
}
- (void)setHidden:(BOOL)hidden { self.deHost.hidden=hidden; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)setNextResponder:(UIResponder *)responder { self.deNextResponder=responder; }
- (UIResponder *)nextResponder { return self.deNextResponder ?: self.superview ?: self.window; }
- (void)keyDown:(id)event {
    id next=self.nextResponder;
    if(next)((void(*)(id,SEL,id))objc_msgSend)(next,sel_registerName("keyDown:"),event);
}
- (void)keyUp:(id)event {
    id next=self.nextResponder;
    if(next)((void(*)(id,SEL,id))objc_msgSend)(next,sel_registerName("keyUp:"),event);
}
- (void)interpretKeyEvents:(NSArray<id<DEGameMouseEvent>> *)events {
    for(id<DEGameMouseEvent> event in events) {
        if(event.type!=10)DEUnsupported("text interpretation requires key down");
        const char *command=event.keyCode==51?"deleteBackward:":event.keyCode==36?"insertNewline:":event.keyCode==48?"insertTab:":event.keyCode==123?"moveLeft:":event.keyCode==124?"moveRight:":event.keyCode==125?"moveDown:":event.keyCode==126?"moveUp:":NULL;
        if(command){((void(*)(id,SEL,SEL))objc_msgSend)(self,sel_registerName("doCommandBySelector:"),sel_registerName(command));continue;}
        if(event.modifierFlags & (1UL<<23))continue;
        if(event.keyCode!=53) {
            NSString *text=event.characters;
            if(!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)
                DEUnsupported("text interpretation requires printable characters or Escape");
            // AppKit returns unbound printable input to the original responder.
            // This is text interpretation, not a synthetic game command.
            SEL modern=sel_registerName("insertText:replacementRange:");
            if(DEHasMouseHandler(object_getClass(self),modern))
                ((void(*)(id,SEL,id,NSRange))objc_msgSend)(self,modern,text,NSMakeRange(NSNotFound,0));
            else
                ((void(*)(id,SEL,id))objc_msgSend)(self,sel_registerName("insertText:"),text);
            fprintf(stderr,"DE_TEXT_INPUT_INSERT length=%lu\n",(unsigned long)text.length);
            continue;
        }
        // Verified against macOS StandardKeyBinding.dict. The original view's
        // command handler decides whether it implements this editing action.
        ((void(*)(id,SEL,SEL))objc_msgSend)(self,sel_registerName("doCommandBySelector:"),sel_registerName("cancelOperation:"));
    }
}
- (BOOL)respondsToSelector:(SEL)selector {
    // The original game's text-input responder probes editing commands before
    // dispatch. Answer those probes without triggering NSView's fail-closed
    // dynamic resolver for a command the view does not implement.
    for(NSString *name in @[@"cancelOperation:",@"deleteBackward:",@"insertNewline:",@"insertTab:",
                            @"moveLeft:",@"moveRight:",@"moveDown:",@"moveUp:"]) {
        if(selector==NSSelectorFromString(name))return DEHasMouseHandler(object_getClass(self),selector);
    }
    return [super respondsToSelector:selector];
}
- (BOOL)becomeFirstResponder { return [self.deHost becomeFirstResponder]; }
- (void)setAutoresizingMask:(NSUInteger)mask {
    // AppKit's six spring/strut bits correspond to UIView's positions, but
    // vertical top/bottom margins swap under UIKit's flipped coordinates.
    NSUInteger translated=(mask&7)|((mask&8)<<2)|(mask&16)|((mask&32)>>2);
    self.deHost.autoresizingMask=(UIViewAutoresizing)translated;
}
- (void)addTrackingArea:(id<DETrackingConfig>)area {
    if (!NSThread.isMainThread) DEUnsupported("game tracking attachment requires main thread");
    fprintf(stderr,"DE_GAME_TRACKING_REQUEST options=%lu\n",(unsigned long)[area options]);
    if ([area options]!=129) DEUnsupported("game tracking supports entered/exited active-always only");
    if (!self.deTracking) {
        self.deTracking=[DEGameTrackingController new];self.deTracking.host=self.deHost;
        self.deTracking.records=[NSMutableArray array];
        UIHoverGestureRecognizer *hover=[[UIHoverGestureRecognizer alloc] initWithTarget:self.deTracking action:@selector(hover:)];
        hover.cancelsTouchesInView=NO;[self.deHost addGestureRecognizer:hover];
    }
    for (DEWebTrackingRecord *record in self.deTracking.records) if (record.area==area) return;
    DEWebTrackingRecord *record=[DEWebTrackingRecord new];record.area=area;
    [self.deTracking.records addObject:record];
    fprintf(stderr,"DE_GAME_TRACKING_ATTACHED options=129 UIKit hover observer\n");
}
- (void)removeTrackingArea:(id)area {
    for (DEWebTrackingRecord *record in self.deTracking.records.copy)
        if (record.area==area) [self.deTracking.records removeObjectIdenticalTo:record];
}
- (NSArray *)trackingAreas {
    NSMutableArray *areas=[NSMutableArray array];
    for (DEWebTrackingRecord *record in self.deTracking.records) [areas addObject:record.area];
    return areas.copy;
}
- (NSArray *)subviews { return self.deSubviews.copy; }
- (void)setSubviews:(NSArray *)views {
    NSArray *incoming=views.copy ?: @[];
    __attribute__((objc_precise_lifetime)) NSMutableArray<UIView *> *hosts=[NSMutableArray array];
    for (id view in incoming) {
        UIView *host=DEHostView(view);
        if (view==self || [hosts containsObject:host]) DEUnsupported("duplicate or self subview");
        [hosts addObject:host];
    }
    for (id old in self.deSubviews.copy) {
        if ([old isKindOfClass:NSView.class]) [old removeFromSuperview];
        else [DEHostView(old) removeFromSuperview];
    }
    [self.deSubviews removeAllObjects];
    for (id view in incoming) [self addSubview:view];
}
- (void)addSubview:(NSView *)view {
    if ([view isKindOfClass:NSView.class]) {
        if (view.superview) [view removeFromSuperview];view.superview=self;
    }
    [self.deSubviews addObject:view];[self.deHost addSubview:DEHostView(view)];
    [self.deHost bringSubviewToFront:self.deHost.touchOrderButton];
}
- (void)removeFromSuperview { [self.superview.deSubviews removeObjectIdenticalTo:self];self.superview=nil;[self.deHost removeFromSuperview]; }
- (NSWindow *)window { return self.deWindow ?: self.superview.window; }
- (CALayer *)layer { return self.deHost.gameLayer ?: self.deHost.layer; }
- (void)setLayer:(CALayer *)layer {
    if ([layer isKindOfClass:CAMetalLayer.class]) DEInstallDrawablePresentationCompatibility();
    [self.deHost.gameLayer removeFromSuperlayer];self.deHost.gameLayer=layer;
    if (layer) [self.deHost.layer addSublayer:layer];
    [self.deHost setNeedsLayout];[self.deHost layoutIfNeeded];
    if(getenv("AGEPAD_LAYER_ATTACH_FLUSH")){[CATransaction flush];fprintf(stderr,"DE_LAYER_ATTACH_FLUSH actual transaction submitted\n");}
    fprintf(stderr,"DE_GAME_LAYER_ATTACHED class=%s metal=%d\n",class_getName(layer.class),[layer isKindOfClass:CAMetalLayer.class]);
    DELogHostGeometry(@"layer_attach",self.deHost);
}
- (void)setNeedsDisplay:(BOOL)needs { if (needs) [self.deHost setNeedsDisplay]; }
- (void)displayIfNeeded { [self.deHost.layer displayIfNeeded]; }
- (CGPoint)convertPoint:(CGPoint)point fromView:(NSView *)view {
    if(view)return [self.deHost convertPoint:point fromView:DEHostView(view)];
    UIView *root=self.window.contentView.deHost;
    CGPoint local=CGPointMake(point.x+root.bounds.origin.x,CGRectGetMaxY(root.bounds)-point.y);
    return [self.deHost convertPoint:local fromView:root];
}
- (CGPoint)convertPoint:(CGPoint)point toView:(NSView *)view {
    if(view)return [self.deHost convertPoint:point toView:DEHostView(view)];
    UIView *root=self.window.contentView.deHost;
    CGPoint local=[self.deHost convertPoint:point toView:root];
    return CGPointMake(local.x-root.bounds.origin.x,CGRectGetMaxY(root.bounds)-local.y);
}
- (CGRect)convertRectToBacking:(CGRect)r { CGFloat s=DERenderScale(self.deHost.window.screen);return CGRectMake(r.origin.x*s,r.origin.y*s,r.size.width*s,r.size.height*s); }
- (CGRect)convertRectFromBacking:(CGRect)r { CGFloat s=DERenderScale(self.deHost.window.screen);return CGRectMake(r.origin.x/s,r.origin.y/s,r.size.width/s,r.size.height/s); }
+ (BOOL)resolveInstanceMethod:(SEL)sel {fprintf(stderr,"DE_UNSUPPORTED_SELECTOR -[NSView %s]\n",sel_getName(sel));DEUnsupported("NSView");}
@end
@implementation NSWindow
- (void)mouseMoved:(id)event {
    // NSResponder's default forwards to the next responder. The original
    // CFeralNSWindow calls super for moves it does not consume.
    id next=self.nextResponder;
    NSMutableArray *visited=[NSMutableArray arrayWithObject:self];
    SEL action=sel_registerName("mouseMoved:");
    while(next && !DEHasMouseHandler(object_getClass(next),action)) {
        if([visited containsObject:next])DEUnsupported("cycle in move responder chain");
        [visited addObject:next];next=((id(*)(id,SEL))objc_msgSend)(next,sel_registerName("nextResponder"));
    }
    if(next==self)DEUnsupported("cycle in move responder chain");
    if(next)((void(*)(id,SEL,id))objc_msgSend)(next,action,event);
}
- (void)update {
    [self.contentView.deHost layoutIfNeeded];
    [NSNotificationCenter.defaultCenter postNotificationName:@"NSWindowDidUpdateNotification" object:self];
}
- (CGPoint)convertPointFromScreen:(CGPoint)point {
    UIView *root=self.contentView.deHost;
    CGRect viewport=DEHostBoundsForScreen(self.deUIKitWindow.windowScene.screen ?: self.deUIKitWindow.screen);
    CGSize canvas=DEGameCanvasSize(viewport.size);
    CGPoint ui=DEHostPointFromGame(CGPointMake(point.x,canvas.height-point.y),viewport.size);
    CGPoint local=[root convertPoint:ui fromView:self.deUIKitWindow];
    CGPoint result=CGPointMake(local.x-root.bounds.origin.x,CGRectGetMaxY(root.bounds)-local.y);
    fprintf(stderr,"DE_INPUT_FROM_SCREEN in=%g,%g out=%g,%g root=%s\n",point.x,point.y,result.x,result.y,NSStringFromCGRect(root.frame).UTF8String);
    return result;
}
- (CGPoint)convertPointToScreen:(CGPoint)point {
    UIView *root=self.contentView.deHost;
    CGRect viewport=DEHostBoundsForScreen(self.deUIKitWindow.windowScene.screen ?: self.deUIKitWindow.screen);
    CGPoint local=CGPointMake(point.x+root.bounds.origin.x,CGRectGetMaxY(root.bounds)-point.y);
    CGPoint ui=[root convertPoint:local toView:self.deUIKitWindow];
    CGPoint game=DEGamePointFromHost(ui,viewport.size);
    CGPoint result=CGPointMake(game.x,DEGameCanvasSize(viewport.size).height-game.y);
    fprintf(stderr,"DE_INPUT_TO_SCREEN in=%g,%g out=%g,%g\n",point.x,point.y,result.x,result.y);
    return result;
}
- (CGRect)convertRectToScreen:(CGRect)rect {
    CGPoint a=[self convertPointToScreen:rect.origin],b=[self convertPointToScreen:CGPointMake(CGRectGetMaxX(rect),CGRectGetMaxY(rect))];
    return CGRectMake(MIN(a.x,b.x),MIN(a.y,b.y),fabs(b.x-a.x),fabs(b.y-a.y));
}
- (CGRect)convertRectFromScreen:(CGRect)rect {
    CGPoint a=[self convertPointFromScreen:rect.origin],b=[self convertPointFromScreen:CGPointMake(CGRectGetMaxX(rect),CGRectGetMaxY(rect))];
    return CGRectMake(MIN(a.x,b.x),MIN(a.y,b.y),fabs(b.x-a.x),fabs(b.y-a.y));
}
- (void)sendEvent:(id<DEGameMouseEvent>)event {
    if (!NSThread.isMainThread || event.window!=self) DEUnsupported("window event requires owned main-thread event");
    NSUInteger type=event.type;
    // Touch recognition can deliver a coalesced begin/end after the pointer
    // observer already saw the endpoint. Match polled pointer state to the event
    // being consumed, not to whichever UIKit sample arrived most recently.
    if((type>=1 && type<=7) || type==22) {
        UIView *host=self.contentView.deHost;
        CGPoint local=CGPointMake(event.locationInWindow.x+host.bounds.origin.x,
                                  CGRectGetMaxY(host.bounds)-event.locationInWindow.y);
        if(CGRectContainsPoint(host.bounds,local) && host.window) {
            CGPoint inWindow=[host convertPoint:local toView:host.window];
            DEUIKitSetPointerPosition(inWindow);
        }
    }
    for(NSString *name in @[@"cachedIsActive",@"cachedIsMain",@"cachedIsVisible"]) {
        SEL getter=NSSelectorFromString(name);
        if(DEHasMouseHandler(object_getClass(self),getter))fprintf(stderr,"DE_INPUT_WINDOW_STATE %s=%d\n",name.UTF8String,((BOOL(*)(id,SEL))objc_msgSend)(self,getter));
    }
    if(type==10 || type==11) {
        SEL action=sel_registerName(type==10?"keyDown:":"keyUp:");
        id target=self.firstResponder ?: self;
        NSMutableArray *visited=[NSMutableArray array];
        while(target && !DEHasMouseHandler(object_getClass(target),action)) {
            if([visited containsObject:target])DEUnsupported("cycle in key responder chain");
            [visited addObject:target];target=((id(*)(id,SEL))objc_msgSend)(target,sel_registerName("nextResponder"));
        }
        if(target)((void(*)(id,SEL,id))objc_msgSend)(target,action,event);
        return;
    }
    BOOL down=type==1 || type==3 || type==25, up=type==2 || type==4 || type==26, dragged=type==6 || type==7 || type==27;
    BOOL moved=type==5, scroll=type==22;
    if (!down && !up && !dragged && !moved && !scroll) DEUnsupported("window dispatch currently supports mouse and key events");
    // AppKit chooses a distinct responder method for secondary-button events.
    // Original games may encode the button in that method, independently of
    // NSEvent.buttonNumber. Sending a right event to mouseDown: loses that contract.
    BOOL secondary=type==3 || type==4 || type==7;
    BOOL other=type==25 || type==26 || type==27; // middle button (three-finger map drag)
    SEL action=sel_registerName(scroll?"scrollWheel:":other ?
        (down?"otherMouseDown:":up?"otherMouseUp:":"otherMouseDragged:") : secondary ?
        (down?"rightMouseDown:":up?"rightMouseUp:":"rightMouseDragged:") :
        (down?"mouseDown:":up?"mouseUp:":moved?"mouseMoved:":"mouseDragged:"));
    id target=self.deMouseDownTarget;
    if(down || moved || scroll) {
        UIView *parent=self.contentView.deHost.superview;
        UIView *root=self.contentView.deHost;
        CGPoint local=CGPointMake(event.locationInWindow.x,event.locationInWindow.y);
        local.y=CGRectGetMaxY(root.bounds)-local.y;
        local.x+=root.bounds.origin.x;local.y+=root.bounds.origin.y;
        CGPoint point=[parent convertPoint:local fromView:root];
        target=[self.contentView hitTest:point];
        if(down)self.deMouseDownTarget=target;
    }
    // AppKit's default view mouse handlers forward along the responder chain.
    // Look up existing handlers without triggering unsupported-method resolution.
    NSMutableArray *visited=[NSMutableArray array];
    while(target && !DEHasMouseHandler(object_getClass(target),action)) {
        if([visited containsObject:target]) DEUnsupported("cycle in mouse responder chain");
        [visited addObject:target];
        target=((id(*)(id,SEL))objc_msgSend)(target,sel_registerName("nextResponder"));
    }
    if(DEInputVerbose(type))fprintf(stderr,"DE_WINDOW_MOUSE_DISPATCH type=%lu action=%s target=%s\n",(unsigned long)type,sel_getName(action),target?object_getClassName(target):"none");
    if(target)((void(*)(id,SEL,id))objc_msgSend)(target,action,event);
    if(up)self.deMouseDownTarget=nil;
}
- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer {
    if (!NSThread.isMainThread || backing!=2) DEUnsupported("window requires main thread and buffered backing");
    if ((self=[super init])) {
        _deFrame=rect;_styleMask=style;_title=@"";_windowNumber=DENextWindowNumber++;
        if(!DEGameWindows)DEGameWindows=[NSHashTable weakObjectsHashTable];
        [DEGameWindows addObject:self];
        _deUIKitWindow=DEHostWindow();
        if (!_deUIKitWindow) DEUnsupported("game window requires existing UIKit window");
        self.contentView=[[NSView alloc] initWithFrame:CGRectMake(0,0,rect.size.width,rect.size.height)];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostGeometryChanged:) name:@"DEUIKitDisplayGeometryDidChange" object:nil];
        fprintf(stderr,"DE_GAME_WINDOW_CREATED size=%gx%g style=%lu\n",rect.size.width,rect.size.height,(unsigned long)style);
    }return self;
}
- (void)hostGeometryChanged:(NSNotification *)note {
    if(!self.deVisible)return;
    UIScreen *screen=self.deUIKitWindow.windowScene.screen ?: self.deUIKitWindow.screen;
    if(note.object && note.object!=screen)return;
    if(self.styleMask & (1UL<<14))
        self.contentView.deHost.frame=(CGRect){CGPointZero,DEGameCanvasSize(self.deUIKitWindow.rootViewController.view.bounds.size)};
    [self updatePresentation];
    [self.contentView.deHost setNeedsLayout];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)setContentView:(NSView *)view {
    [self.dePresentation removeFromSuperview];
    [_contentView.deHost removeFromSuperview];_contentView.deWindow=nil;_contentView=view;view.deWindow=self;
    if (self.deVisible) [self makeKeyAndOrderFront:nil];
}
- (void)setBackgroundColor:(id<DEColorObject>)color { _backgroundColor=color;self.contentView.deHost.backgroundColor=color?[UIColor colorWithCGColor:color.CGColor]:nil; }
- (BOOL)makeFirstResponder:(NSView *)view {
    if (!view) { BOOL result=[DEHostView(self.firstResponder) resignFirstResponder];self.firstResponder=nil;return result; }
    BOOL result=[view becomeFirstResponder];if (result) self.firstResponder=view;return result;
}
- (void)setTouchBar:(id)bar { if (bar) DEUnsupported("non-nil Touch Bar on UIKit window");fprintf(stderr,"DE_WINDOW_TOUCHBAR_CLEAR no Touch Bar attached\n"); }
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)invalidateCursorRectsForView:(NSView *)view {
    if (!NSThread.isMainThread || view.window!=self) DEUnsupported("cursor invalidation requires owned main-thread view");
    // No regions have been registered yet in this adapter. Ask the original
    // view to rebuild them; any unsupported registration still fails explicitly.
    [view resetCursorRects];
    fprintf(stderr,"DE_WINDOW_CURSOR_RECTS_RESET original_view=%s\n",class_getName(object_getClass(view)));
}
- (id)standardWindowButton:(NSUInteger)button {
    // UIKit owns scene chrome; this content host has no AppKit title-bar
    // close/minimize/zoom/full-screen buttons. AppKit permits absent buttons.
    fprintf(stderr,"DE_WINDOW_STANDARD_BUTTON absent desktop chrome type=%lu\n",(unsigned long)button);
    return nil;
}
- (BOOL)canBecomeMainWindow { return YES; }
- (CGRect)frame { return self.deFrame; }
- (id)screen { return DEUIKitScreenObject(self.deUIKitWindow.windowScene.screen ?: self.deUIKitWindow.screen); }
- (CGFloat)backingScaleFactor { return DERenderScaleForWindow(self.deUIKitWindow); }
- (CGRect)frameRectForContentRect:(CGRect)rect { return rect; } // UIKit host has no desktop decorations.
- (CGRect)contentRectForFrameRect:(CGRect)rect { return rect; } // No desktop decorations.
+ (CGRect)contentRectForFrameRect:(CGRect)rect styleMask:(NSUInteger)style { return rect; }
+ (CGRect)frameRectForContentRect:(CGRect)rect styleMask:(NSUInteger)style { return rect; }
- (BOOL)isVisible { return self.deVisible && !self.deUIKitWindow.hidden; }
- (NSInteger)windowNumber { return _windowNumber; }
- (BOOL)isKeyWindow { return DEKeyGameWindow==self && self.deVisible && self.deUIKitWindow.isKeyWindow; }
- (BOOL)isMainWindow { return DEMainGameWindow==self && self.deVisible; }
- (void)resignKeyWindow {
    if(DEKeyGameWindow!=self)return;DEKeyGameWindow=nil;
    DEPostWindowTransition(self,@"NSWindowDidResignKeyNotification",sel_registerName("windowDidResignKey:"));
}
- (void)resignMainWindow {
    if(DEMainGameWindow!=self)return;DEMainGameWindow=nil;
    DEPostWindowTransition(self,@"NSWindowDidResignMainNotification",sel_registerName("windowDidResignMain:"));
}
- (void)makeKeyWindow {
    DEInstallGameKeyboard();
    if(!self.deVisible || !self.deUIKitWindow.isKeyWindow || ![self canBecomeKeyWindow])return;
    if(DEKeyGameWindow==self)return;
    [DEKeyGameWindow resignKeyWindow];DEKeyGameWindow=self;
    DEPostWindowTransition(self,@"NSWindowDidBecomeKeyNotification",sel_registerName("windowDidBecomeKey:"));
}
- (void)makeMainWindow {
    if(!self.deVisible || ![self canBecomeMainWindow])return;
    if(DEMainGameWindow==self)return;
    [DEMainGameWindow resignMainWindow];DEMainGameWindow=self;
    DEPostWindowTransition(self,@"NSWindowDidBecomeMainNotification",sel_registerName("windowDidBecomeMain:"));
}
- (BOOL)isMiniaturized { return NO; }
- (BOOL)inLiveResize { return self.deLiveResize; }
- (BOOL)isOnActiveSpace { return UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground; }
- (void)updatePresentation {
    UIView *root=self.deUIKitWindow.rootViewController.view;
    DEGameViewHost *host=self.contentView.deHost;
    if(!root || !host)return;
    if(!self.dePresentation)self.dePresentation=[UIView new];
    BOOL fullscreen=(self.styleMask & (1UL<<14))!=0;
    CGSize logical=fullscreen?DEGameCanvasSize(root.bounds.size):self.deFrame.size;
    CGRect available=fullscreen?root.bounds:UIEdgeInsetsInsetRect(root.bounds,root.safeAreaInsets);
    BOOL fitted=DEConfigureWindowPresentation(self.dePresentation,host,logical,available,fullscreen);
    if(host.windowedPresentation!=fitted) {
        [host cancelHostInput:nil];
        host.windowedPresentation=fitted;
        [host setNeedsLayout];
    }
    if(host.superview!=self.dePresentation)[self.dePresentation addSubview:host];
    if(self.deVisible && self.dePresentation.superview!=root)[root addSubview:self.dePresentation];
}
- (void)center {
    CGRect bounds=self.deUIKitWindow.rootViewController.view.bounds;
    CGRect frame=self.deFrame;frame.origin=CGPointMake(CGRectGetMidX(bounds)-frame.size.width/2,CGRectGetMidY(bounds)-frame.size.height/2);self.deFrame=frame;
    if (self.deVisible) [self updatePresentation];
}
- (void)makeKeyAndOrderFront:(id)sender {
    [self orderFront:sender];
    [self makeKeyWindow];[self makeMainWindow];
}
- (void)orderFront:(id)sender {
    UIView *root=self.deUIKitWindow.rootViewController.view;
    // Ordering another window front must not close/detach existing windows.
    // The original renderer may still submit to them until orderOut:/close.
    fprintf(stderr,"DE_WINDOW_ORDER_FRONT existing_hosts=%lu newhost=%p\n",(unsigned long)root.subviews.count,(__bridge void *)self.contentView.deHost);
    self.deVisible=YES;
    [self updatePresentation];
    [root bringSubviewToFront:self.dePresentation];[self.deUIKitWindow makeKeyAndVisible];
    if(getenv("AGEPAD_LAYER_ATTACH_FLUSH")){[root layoutIfNeeded];[CATransaction flush];fprintf(stderr,"DE_WINDOW_SHOW_FLUSH actual transaction submitted\n");}
    if (self.initialFirstResponder) [self makeFirstResponder:self.initialFirstResponder];
    fprintf(stderr,"DE_GAME_WINDOW_VISIBLE size=%gx%g\n",self.deFrame.size.width,self.deFrame.size.height);
    DELogHostGeometry(@"order_front",self.contentView.deHost);
}
- (void)toggleFullScreen:(id)sender {
    if (!NSThread.isMainThread || !self.deVisible || self.deFullScreenTransition)
        DEUnsupported("full-screen transition requires visible idle main-thread window");
    BOOL entering=(self.styleMask & (1UL<<14))==0;
    self.deFullScreenTransition=YES;
    NSString *will=entering?@"NSWindowWillEnterFullScreenNotification":@"NSWindowWillExitFullScreenNotification";
    SEL willSelector=NSSelectorFromString(entering?@"windowWillEnterFullScreen:":@"windowWillExitFullScreen:");
    NSNotification *note=[NSNotification notificationWithName:will object:self];
    [NSNotificationCenter.defaultCenter postNotification:note];
    if ([self.delegate respondsToSelector:willSelector]) ((void(*)(id,SEL,id))objc_msgSend)(self.delegate,willSelector,note);
    UIView *root=self.deUIKitWindow.rootViewController.view;
    if (entering) { self.deWindowedFrame=self.deFrame;self.deFrame=(CGRect){CGPointZero,DEGameCanvasSize(root.bounds.size)};self.styleMask|=(1UL<<14); }
    else { self.deFrame=self.deWindowedFrame;self.styleMask&=~(1UL<<14); }
    [self updatePresentation];
    self.contentView.frame=(CGRect){CGPointZero,self.deFrame.size};
    self.contentView.deHost.autoresizingMask=entering?(UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight):UIViewAutoresizingNone;
    [root layoutIfNeeded];[self.contentView.deHost layoutIfNeeded];
    // UIKit owns the scene; full screen means filling its actual content area.
    // Complete after layout on the next main-queue turn, with the real layer.
    dispatch_async(dispatch_get_main_queue(),^{
        self.deFullScreenTransition=NO;
        NSString *did=entering?@"NSWindowDidEnterFullScreenNotification":@"NSWindowDidExitFullScreenNotification";
        SEL didSelector=NSSelectorFromString(entering?@"windowDidEnterFullScreen:":@"windowDidExitFullScreen:");
        NSNotification *completion=[NSNotification notificationWithName:did object:self];
        [NSNotificationCenter.defaultCenter postNotification:completion];
        if ([self.delegate respondsToSelector:didSelector]) ((void(*)(id,SEL,id))objc_msgSend)(self.delegate,didSelector,completion);
        fprintf(stderr,"DE_WINDOW_FULLSCREEN actual_scene_fill=%d size=%gx%g\n",entering,self.contentView.bounds.size.width,self.contentView.bounds.size.height);
        DELogHostGeometry(entering?@"fullscreen_enter":@"fullscreen_exit",self.contentView.deHost);
    });
}
- (void)setFrame:(CGRect)frame display:(BOOL)display {
    // The engine may reapply its cached display mode from a resize callback.
    // A UIKit full-screen window must still fill the current scene, including
    // during the original engine's enter-full-screen notification sequence.
    if(self.styleMask & (1UL<<14))frame=(CGRect){CGPointZero,DEGameCanvasSize(self.deUIKitWindow.rootViewController.view.bounds.size)};
    self.deFrame=frame;self.contentView.frame=CGRectMake(0,0,frame.size.width,frame.size.height);
    [self updatePresentation];
}
- (void)setContentSize:(CGSize)size { CGRect frame=self.deFrame;frame.size=size;[self setFrame:frame display:YES]; }
- (void)orderOut:(id)sender { fprintf(stderr,"DE_WINDOW_DETACH window=%p host=%p layer=%p\n",(__bridge void *)self,(__bridge void *)self.contentView.deHost,(__bridge void *)self.contentView.layer); [self.dePresentation removeFromSuperview];[self.contentView.deHost removeFromSuperview];self.deVisible=NO;[self resignKeyWindow];[self resignMainWindow]; }
- (void)close { [self orderOut:nil]; }
+ (BOOL)resolveInstanceMethod:(SEL)sel {fprintf(stderr,"DE_UNSUPPORTED_SELECTOR -[NSWindow %s]\n",sel_getName(sel));DEUnsupported("NSWindow");}
@end

#include "NativeTouchGestures.m"
