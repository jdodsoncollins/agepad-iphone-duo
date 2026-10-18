#!/usr/bin/env python3
"""Two-finger tap and touch-gesture behaviour of the real game-view touch code,
run in the AgePad iPad Simulator with scripted touch timelines.

The Simulator can't produce two independent finger touches, so this compiles
the actual touch handlers from port/de/WindowViewCompat.m (touchesBegan..Ended,
the two-finger recogniser, deferred presses, click synthesis) with fake touches
and records the mouse events the game would receive. Real fingers, the Apple
Pencil and multi-finger feel still need the iPad."""
from pathlib import Path
import json, subprocess, sys
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'scripts'))
import de_device
out = root / 'generated/de-two-finger-regression'
out.mkdir(parents=True, exist_ok=True)
s = (root / 'port/de/WindowViewCompat.m').read_text()
protocol = s[s.index('@protocol DEGameMouseEvent'):s.index('@interface DEGameViewHost')]
interface = s[s.index('@interface DEGameViewHost'):s.index('static void DEPostGameKey(unsigned short macKey, NSString *characters, BOOL pressed);')]
handlers = s[s.index('- (void)sendGameMouse:'):s.index('\n@end\n@interface NSView')]
shortcuts = s[s.index('- (void)touchShortcut:'):s.index('- (BOOL)canBecomeFirstResponder')]
window_frame = s[s.index('- (void)setFrame:(CGRect)frame display:(BOOL)display {'):s.index('- (void)setContentSize:')]
window_layout = s[s.index('static void DEPostWindowTransition(NSWindow *window,NSString *name,SEL action) {'):s.index('void DEUpdateVisibleGameWindows(void)')]
handler_lookup = s[s.index('static BOOL DEHasMouseHandler('):s.index('static void DELogTouchDetail(')]
gestures = (root / 'port/de/NativeTouchGestures.m').read_text()
window_line = next(l for l in s.splitlines() if l.startswith('static const NSTimeInterval DETwoFingerWindow'))
window_line += '\n' + '\n'.join(l for l in s.splitlines() if l.startswith(('static void DESetMaybeSelected', 'static BOOL DEMaybeSelected')))
preamble = r'''
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include "TouchCommandWheelView.m"
#include "RenderScale.h"
#include "HUDInputRegions.h"
#include "EventCompat.m"
#include "EventQueueCompat.m"
#include "PointerEventCompat.m"
static CGPoint testPointer;
@class DEGameViewHost;
static void DEGameHostDidLayout(DEGameViewHost *host);
static NSHashTable *DEGameWindows;
CGPoint DEUIKitPointerPosition(void){return testPointer;}
void DEUIKitSetPointerPosition(CGPoint p){testPointer=p;}
void DEUIKitPinPointer(CGPoint p,NSTimeInterval s){testPointer=p;}
@interface NSApplication:NSObject
@property(nonatomic,strong) DEEventQueue *queue;
+(instancetype)sharedApplication;
-(void)postEvent:(id)e atStart:(BOOL)start;
@end
@implementation NSApplication
+(instancetype)sharedApplication{static NSApplication *a; if(!a){a=[self new];a.queue=[DEEventQueue new];}return a;}
-(void)postEvent:(id)e atStart:(BOOL)start{[self.queue post:e atStart:start];}
@end
@interface FakeContent:NSObject
@property(nonatomic,strong) UIView *deHost;
@property(nonatomic) CGRect frame;
@end
@implementation FakeContent
-(void)setFrame:(CGRect)frame{_frame=frame;self.deHost.frame=frame;}
@end
@interface NSWindow:NSObject
@property(nonatomic,strong) FakeContent *contentView;
@property(nonatomic) NSInteger windowNumber;
@property(nonatomic) NSUInteger styleMask;
@property(nonatomic) CGRect deFrame;
@property(nonatomic,weak) UIWindow *deUIKitWindow;
@property(nonatomic,weak) id delegate;
@property(nonatomic) BOOL deVisible;
@property(nonatomic) BOOL deProcessingHostResize;
@property(nonatomic) BOOL deLiveResize;
@property(nonatomic) CGFloat deReportedBackingScale;
@property(nonatomic,strong) UIScreen *deReportedScreen;
-(void)setFrame:(CGRect)frame display:(BOOL)display;
-(void)updatePresentation;
@end
@implementation NSWindow
WINDOW_FRAME_HANDLER
-(void)updatePresentation{} // Presentation geometry has its own UIKit regression.
@end
@interface ResizeWindow:NSWindow
@property(nonatomic) NSUInteger appliedFrames;
@end
@implementation ResizeWindow
-(void)setFrame:(CGRect)frame display:(BOOL)display{self.appliedFrames++;[super setFrame:frame display:display];}
@end
@interface FakeOwner:NSObject
@property(nonatomic,strong) NSWindow *window;
@end
@implementation FakeOwner @end
@interface FakeTouch:NSObject
@property(nonatomic) CGPoint point;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic) NSUInteger tapCount;
@property(nonatomic) UITouchType type;
@property(nonatomic) UITouchPhase phase;
@property(nonatomic,weak) UIView *view;
-(CGPoint)locationInView:(UIView *)view;
@end
@implementation FakeTouch
-(CGPoint)locationInView:(UIView *)view{return self.point;}
@end
@interface FakeEvent:NSObject
@property(nonatomic,strong) NSSet *allTouches;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic) UIEventButtonMask buttonMask;
@end
@implementation FakeEvent @end
static BOOL DEGlobalTouchCommandMode,DEPencilOrderArmed,DEMenuOpen;
TWO_FINGER_WINDOW
static BOOL DEPencilMatchActive(void){return YES;}
static void DERefreshTouchCommandButtons(void){}
static BOOL DEInputVerbose(NSUInteger t){return NO;}
static void DELogTouchDetail(id t,NSUInteger n){}
static void DELogButtonMask(id e,NSUInteger t,UIEventButtonMask m){}
static void DELogSynthesizedMouse(NSUInteger p,id e,UIEventButtonMask m,SEL s){}
static int escapeDowns;
static void DEPostGameKey(unsigned short key,NSString *characters,BOOL pressed){if(key==53 && pressed)escapeDowns++;}
'''
main = r'''
@interface FixtureHost:DEGameViewHost
@property(nonatomic,copy) NSArray<NSValue *> *fixtureReservedRects;
@property(nonatomic) UIEdgeInsets fixtureInsets;
@end
@implementation FixtureHost
-(NSArray<NSValue *> *)activeTouchReservedRects {return self.fixtureReservedRects ?: [super activeTouchReservedRects];}
-(UIEdgeInsets)safeAreaInsets{return self.fixtureInsets;}
@end
static void pump(double seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(end.timeIntervalSinceNow>0)CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.005,true);}
static DEGameViewHost *host;static UIButton *button;
static FakeTouch *touch(CGPoint p,UIView *view){FakeTouch *t=[FakeTouch new];t.point=p;t.tapCount=1;t.type=UITouchTypeDirect;t.view=view;t.phase=UITouchPhaseBegan;t.timestamp=NSProcessInfo.processInfo.systemUptime;return t;}
static FakeEvent *event(NSArray *all){FakeEvent *e=[FakeEvent new];e.allTouches=[NSSet setWithArray:all];e.timestamp=NSProcessInfo.processInfo.systemUptime;return e;}
static void began(FakeTouch *t,NSArray *all){t.phase=UITouchPhaseBegan;t.timestamp=NSProcessInfo.processInfo.systemUptime;[host touchesBegan:[NSSet setWithObject:t] withEvent:(UIEvent *)event(all)];}
static void moved(FakeTouch *t,CGPoint p,NSArray *all){t.point=p;t.phase=UITouchPhaseMoved;t.timestamp=NSProcessInfo.processInfo.systemUptime;[host touchesMoved:[NSSet setWithObject:t] withEvent:(UIEvent *)event(all)];}
static void ended(FakeTouch *t,NSArray *all){t.phase=UITouchPhaseEnded;t.timestamp=NSProcessInfo.processInfo.systemUptime;[host touchesEnded:[NSSet setWithObject:t] withEvent:(UIEvent *)event(all)];}
// Observe completed delivery rather than sampling exactly at its 100 ms
// minimum. A busy main run loop may post the release just after that boundary.
static void finishPendingClicks(void){NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:0.6];
 while(host.pendingClicks.count && deadline.timeIntervalSinceNow>0)pump(0.005);
 NSCAssert(host.pendingClicks.count==0,@"Pending clicks must finish within the ordered delivery bound");}
// Replays the queued right-button drag through DE's measured click-drag
// scrolling (see NativeTouchGestures.m) and returns how far the map content
// moved, in view points, as the game would scroll it.
static CGPoint simulateScroll(void){BOOL down=NO;CGPoint a=CGPointZero,cur=CGPointZero,moved=CGPointZero;double t=0;
  for(NSEvent *e in NSApplication.sharedApplication.queue.events){
    if(down){double dt=e.timestamp-t;CGFloat ox=cur.x-a.x,oy=-(cur.y-a.y),r=hypot(ox,1.78*oy);
      if(r>68){CGFloat x=r-68,v=3.84*x+0.0622*x*x;moved.x-=v*dt*ox/r;moved.y-=v*dt*1.78*oy/r;}}
    if(e.type==3){down=YES;a=cur=e.locationInWindow;}
    else if(e.type==7)cur=e.locationInWindow;
    else if(e.type==4)down=NO;
    t=e.timestamp;}
  return moved;}
static NSArray *drain(void){pump(0.45);NSMutableArray *types=[NSMutableArray new];
  for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type!=5)[types addObject:@(e.type)];
  [NSApplication.sharedApplication.queue.events removeAllObjects];host.gameTouch=nil;return types;}
int main(void){@autoreleasepool{
unsetenv("AGEPAD_HUD_INPUT_REGIONS"); // Fixtures must not inherit a private game profile.
setenv("AGEPAD_POINTER_STATE","1",1);setenv("AGEPAD_TOUCH_DEFER_PRESS","1",1);
ResizeWindow *w=[ResizeWindow new];w.contentView=[FakeContent new];w.contentView.deHost=[[UIView alloc]initWithFrame:CGRectMake(0,0,1366,1024)];
FakeOwner *owner=[FakeOwner new];owner.window=w;
host=[[FixtureHost alloc]initWithFrame:CGRectMake(0,0,1366,1024)];host.originalView=owner;host.gameClickCount=1;
// Real UIKit coordinate conversion is part of sendPendingClick. A detached host
// has window=nil and would turn an overridden target into CGPointZero.
__attribute__((objc_precise_lifetime)) UIWindow *fixtureWindow=[[UIWindow alloc]initWithFrame:CGRectMake(0,0,1366,1024)];
fixtureWindow.rootViewController=[UIViewController new];
[fixtureWindow.rootViewController.view addSubview:w.contentView.deHost];
[w.contentView.deHost addSubview:host];
[fixtureWindow makeKeyAndVisible];
NSCAssert(host.window==fixtureWindow,@"The gesture fixture must be attached to its UIKit window");
button=[[UIButton alloc]initWithFrame:CGRectMake(1280,500,76,44)];[host addSubview:button];
NSMutableDictionary *r=[NSMutableDictionary new];
CGPoint p=CGPointMake(600,400),q=CGPointMake(700,420);
// One finger tap on the map: a left click.
{FakeTouch *a=touch(p,host);began(a,@[a]);pump(0.08);ended(a,@[a]);r[@"one_finger_tap"]=drain();}
// A quick tap has ended physically while its synthetic 60 ms press is still
// down. Resize must release it outside the world once, suppressing its timer.
{FakeTouch *a=touch(p,host);began(a,@[a]);ended(a,@[a]);
 CGRect frame=host.frame;host.frame=CGRectMake(0,0,1200,900);[host layoutIfNeeded];
 [host cancelHostInput:nil];finishPendingClicks();NSInteger ups=0;BOOL outside=YES;
 for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==2){ups++;outside&=e.locationInWindow.x<0;}
 r[@"resized_pending_tap_up"]=@[@(ups),@(outside)];r[@"resized_pending_tap"]=drain();
 host.frame=frame;[host layoutIfNeeded];}
// A delayed up belongs to its original target and button, even if another
// interaction changes the host's order mode, button mask or touch position.
{FakeTouch *a=touch(p,host);began(a,@[a]);ended(a,@[a]);
 a.point=q;host.pencilStart=q;host.gameButtonMask=UIEventButtonMaskSecondary;DEGlobalTouchCommandMode=YES;
 finishPendingClicks();NSMutableArray *points=[NSMutableArray new];
 for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==1 || e.type==2)[points addObject:@[@(e.locationInWindow.x),@(e.locationInWindow.y)]];
 r[@"pending_tap_target"]=points;r[@"pending_tap_button"]=drain();
 DEGlobalTouchCommandMode=NO;host.gameButtonMask=0;}
// Independently track rapid taps; cancelling both must pair each down once.
{FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);ended(a,@[a]);began(b,@[b]);ended(b,@[b]);
 [host cancelHostInput:nil];[host cancelHostInput:nil];finishPendingClicks();NSInteger ups=0;BOOL outside=YES;
 for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==2){ups++;outside&=e.locationInWindow.x<0;}
 r[@"cancel_rapid_pending_ups"]=@[@(ups),@(outside)];r[@"cancel_rapid_pending"]=drain();}
// Two fingers 80 ms apart, lifted together: a right click only.
{FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);pump(0.08);began(b,@[a,b]);pump(0.1);ended(a,@[a,b]);ended(b,@[a,b]);r[@"two_finger_tap"]=drain();}
// Focus loss between the synthesized right-down and delayed up cancels an
// order rather than releasing it on the original map point after the pause.
{FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);began(b,@[a,b]);ended(a,@[a,b]);ended(b,@[a,b]);
 [host cancelHostInput:nil];[host cancelHostInput:nil];finishPendingClicks();NSInteger ups=0;BOOL outside=YES;
 for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==4){ups++;outside&=e.locationInWindow.x<0;}
 r[@"cancel_pending_order_up"]=@[@(ups),@(outside)];r[@"cancel_pending_order"]=drain();}
// The 60 ms click timer fires before ordered delivery's minimum press ends.
// Cancellation at 80 ms must relocate that already queued up, without adding
// a second release. Exercise both primary selection and secondary ordering.
for(NSInteger secondary=0;secondary<2;secondary++) {
 FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);
 if(secondary){began(b,@[a,b]);ended(a,@[a,b]);ended(b,@[a,b]);}else ended(a,@[a]);
 pump(0.08);BOOL waiting=host.pendingClicks.count==1 && host.pendingClicks.firstObject.releaseQueued;
 [host cancelHostInput:nil];[host cancelHostInput:nil];finishPendingClicks();NSInteger ups=0;BOOL outside=YES;
 for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==(secondary?4:2)){ups++;outside&=e.locationInWindow.x<0;}
 NSString *name=secondary?@"late_cancel_order":@"late_cancel_tap";
 r[[name stringByAppendingString:@"_up"]]=@[@(waiting),@(ups),@(outside)];r[name]=drain();
}
// A prior click can delay the next click's down as well as its up. Cancelling
// the new click before either posts must keep both outside the world, paired.
{[host nativeMouse:1 point:p wheel:0];[host nativeMouse:2 point:p wheel:0];
 FakeTouch *a=touch(q,host);began(a,@[a]);ended(a,@[a]);[host cancelHostInput:nil];finishPendingClicks();
 NSInteger downs=0,ups=0;BOOL downOutside=NO,upOutside=NO;
 for(NSEvent *e in NSApplication.sharedApplication.queue.events){
  if(e.type==1){downs++;if(downs==2)downOutside=e.locationInWindow.x<0;}
  if(e.type==2){ups++;if(ups==2)upOutside=e.locationInWindow.x<0;}
 }
 r[@"queued_down_cancel_pair"]=@[@(downs),@(ups),@(downOutside),@(upOutside)];
 r[@"queued_down_cancel"]=drain();}
// Second finger 300 ms after the first (slow tap).
{FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);pump(0.30);began(b,@[a,b]);pump(0.1);ended(a,@[a,b]);ended(b,@[a,b]);r[@"slow_two_finger_tap"]=drain();}
// Fingers lifted 150 ms apart.
{FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);pump(0.05);began(b,@[a,b]);pump(0.1);ended(a,@[a,b]);pump(0.15);ended(b,@[a,b]);r[@"uneven_lift"]=drain();}
// A finger holding a side button while another taps the map: a left click.
{FakeTouch *z=touch(CGPointMake(1300,520),button),*a=touch(p,host);began(a,@[z,a]);pump(0.08);ended(a,@[z,a]);r[@"tap_while_holding_button"]=drain();}
// Two fingers that move apart (a pinch): no click.
{FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);pump(0.05);began(b,@[a,b]);pump(0.05);moved(b,CGPointMake(800,480),@[a,b]);pump(0.05);ended(a,@[a,b]);ended(b,@[a,b]);r[@"pinch"]=drain();}
// Three fingers: no click.
{FakeTouch *a=touch(p,host),*b=touch(q,host),*c=touch(CGPointMake(650,500),host);began(a,@[a]);pump(0.05);began(b,@[a,b]);began(c,@[a,b,c]);pump(0.1);ended(a,@[a,b,c]);ended(b,@[a,b,c]);ended(c,@[a,b,c]);r[@"three_fingers"]=drain();}
// One finger drag: a left-button drag (selection box).
{FakeTouch *a=touch(p,host);began(a,@[a]);pump(0.05);moved(a,CGPointMake(650,450),@[a]);pump(0.05);moved(a,CGPointMake(700,500),@[a]);pump(0.05);ended(a,@[a]);r[@"one_finger_drag"]=drain();}
// Apple Pencil sticky orders: tap selects and arms, later taps order until a
// hold (>=0.45 s) disarms; HUD taps never order; a drag-box selects and arms.
setenv("AGEPAD_PENCIL_STICKY_ORDER","1",1);DEPencilOrderArmed=NO;
#define PTAP(name,pt,hold) {FakeTouch *a=touch(pt,host);a.type=UITouchTypePencil;began(a,@[a]);pump(hold);ended(a,@[a]);r[@name]=drain();}
PTAP("pencil_1_select",p,0.08) PTAP("pencil_2_order",q,0.08) PTAP("pencil_3_order_again",p,0.08)
PTAP("pencil_4_hold_deselect",q,0.5) PTAP("pencil_5_select_again",p,0.08)
PTAP("pencil_6_hud_tap",CGPointMake(600,900),0.08) PTAP("pencil_7_after_hud",p,0.08)
{FakeTouch *a=touch(p,host);a.type=UITouchTypePencil;began(a,@[a]);pump(0.05);moved(a,CGPointMake(700,500),@[a]);pump(0.05);ended(a,@[a]);r[@"pencil_8_box"]=drain();}
PTAP("pencil_9_order_after_box",q,0.08)
// Finger taps and two-finger orders don't switch the Pencil to orders: the
// next Pencil tap on a unit selects it.
{FakeTouch *a=touch(p,host);began(a,@[a]);pump(0.08);ended(a,@[a]);drain();}
PTAP("pencil_after_finger_tap",q,0.08)
{FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);pump(0.08);began(b,@[a,b]);pump(0.1);ended(a,@[a,b]);ended(b,@[a,b]);drain();}
DEPencilOrderArmed=NO;PTAP("pencil_select_before_two_finger",p,0.08)
{FakeTouch *a=touch(p,host),*b=touch(q,host);began(a,@[a]);pump(0.08);began(b,@[a,b]);pump(0.1);ended(a,@[a,b]);ended(b,@[a,b]);drain();}
PTAP("pencil_after_two_finger_order",q,0.08)
r[@"maybe_selected"]=@(DEMaybeSelected());
// Pencil double-tap: one Escape per gesture even when reported twice, and
// none when nothing is selected (Escape then opened the game menu).
escapeDowns=0;DESetMaybeSelected(YES);[host pencilDeselect:"a"];[host pencilDeselect:"b"];pump(0.35);
[host pencilDeselect:"c"];pump(0.1);r[@"double_tap_escapes"]=@(escapeDowns);
// Two/three-finger map drag: one right-button press held at least 0.35 s,
// and, replayed through DE's measured scrolling, the map moves as far as the
// fingers did; a drag under 16 points sends nothing.
drain();
{[host nativeMapScrollPhase:0 point:p];for(int i=1;i<=6;i++){[host nativeMapScrollPhase:1 point:CGPointMake(p.x+i*10,p.y+i*4)];pump(0.01);}
 [host nativeMapScrollPhase:2 point:CGPointMake(p.x+60,p.y+24)];pump(0.1);
 BOOL early=NO;for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==4)early=YES;r[@"drag_released_early"]=@(early);
 pump(0.8);CGPoint m=simulateScroll();r[@"map_drag_moved"]=@[@(round(m.x)),@(round(m.y))];r[@"map_drag"]=drain();}
// A fast flick: 300 x 150 points in 0.1 s, then lift. The view catches up.
{[host nativeMapScrollPhase:0 point:q];for(int i=1;i<=5;i++){[host nativeMapScrollPhase:1 point:CGPointMake(q.x-i*60,q.y-i*30)];pump(0.02);}
 [host nativeMapScrollPhase:2 point:CGPointMake(q.x-300,q.y-150)];pump(1.5);
 CGPoint m=simulateScroll();r[@"flick_moved"]=@[@(round(m.x)),@(round(m.y))];r[@"flick"]=drain();}
{[host nativeMapScrollPhase:0 point:p];[host nativeMapScrollPhase:1 point:CGPointMake(p.x+8,p.y+6)];[host nativeMapScrollPhase:2 point:CGPointMake(p.x+8,p.y+6)];r[@"tiny_drag"]=drain();}
// A second swipe right after the first continues the same press: one press,
// one release, and the map moves by both swipes.
{[host nativeMapScrollPhase:0 point:p];for(int i=1;i<=4;i++){[host nativeMapScrollPhase:1 point:CGPointMake(p.x+i*10,p.y)];pump(0.01);}
 [host nativeMapScrollPhase:2 point:CGPointMake(p.x+40,p.y)];
 pump(0.1);[host nativeMapScrollPhase:0 point:q];[host nativeMapScrollPhase:1 point:CGPointMake(q.x+20,q.y)];pump(0.1);
 for(int i=1;i<=4;i++){[host nativeMapScrollPhase:1 point:CGPointMake(q.x+20+i*10,q.y)];pump(0.01);}
 [host nativeMapScrollPhase:2 point:CGPointMake(q.x+60,q.y)];pump(0.8);
 CGPoint m=simulateScroll();r[@"repeat_drag_moved"]=@[@(round(m.x)),@(round(m.y))];r[@"repeat_drag"]=drain();}
// Zoom: whole wheel steps only; the remainder waits for more movement.
{CGFloat pending=2.6;[host sendZoomSteps:&pending point:p source:"test"];r[@"zoom_steps"]=drain();r[@"zoom_left"]=@(round(pending*10)/10);}
// Compact-window controls exercise the same real handlers and ordered engine
// delivery as the iPad timelines above. No independent long-press recognizer.
host.frame=CGRectMake(0,0,800,400);w.contentView.deHost.frame=host.bounds;
host.commandWheelButton=[UIButton buttonWithType:UIButtonTypeSystem];
NSMutableArray *shortcuts=[NSMutableArray new];for(int i=0;i<5;i++){UIButton *b=[UIButton new];b.tag=i;[shortcuts addObject:b];}host.touchShortcutButtons=shortcuts;
[host layoutIfNeeded]; // Finish the resize before starting the next gesture.
DEMenuOpen=NO;DEGlobalTouchCommandMode=NO;CGPoint phone=CGPointMake(300,160);
{FakeTouch *a=touch(phone,host);began(a,@[a]);pump(0.08);ended(a,@[a]);r[@"compact_quick_tap"]=drain();}
{FakeTouch *a=touch(phone,host),*b=touch(CGPointMake(400,180),host);began(a,@[a]);pump(0.30);began(b,@[a,b]);pump(0.08);ended(a,@[a,b]);ended(b,@[a,b]);r[@"compact_slow_two_finger"]=drain();}
{FakeTouch *a=touch(phone,host);began(a,@[a]);pump(0.50);r[@"wheel_opened"]=@(host.commandWheel!=nil);
 NSInteger downs=0;for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==1 || e.type==3)downs++;
 r[@"wheel_no_press_before_selection"]=@(downs==0);ended(a,@[a]);r[@"wheel_center_cancel"]=drain();}
// A clamped drawing at an edge must not select anything without a slide.
{FakeTouch *a=touch(CGPointMake(5,160),host);began(a,@[a]);pump(0.50);ended(a,@[a]);r[@"wheel_stationary_edge"]=drain();}
{FakeTouch *a=touch(CGPointMake(30,160),host);began(a,@[a]);pump(0.50);
 moved(a,CGPointMake(30,90),@[a]);ended(a,@[a]);pump(0.3);
 NSMutableArray *points=[NSMutableArray new];for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==3 || e.type==4)[points addObject:@[@(e.locationInWindow.x),@(e.locationInWindow.y)]];
 r[@"wheel_order_anchor"]=points;r[@"wheel_order"]=drain();}
{FakeTouch *a=touch(phone,host);began(a,@[a]);pump(0.50);moved(a,CGPointMake(550,160),@[a]);ended(a,@[a]);r[@"wheel_outside_cancel"]=drain();}
{FakeTouch *a=touch(phone,host),*b=touch(CGPointMake(400,180),host);began(a,@[a]);pump(0.50);began(b,@[a,b]);ended(a,@[a,b]);ended(b,@[a,b]);r[@"wheel_second_finger_cancel"]=drain();}
{FakeTouch *a=touch(phone,host);began(a,@[a]);pump(0.05);moved(a,CGPointMake(330,180),@[a]);pump(0.50);
 r[@"drag_never_opens_wheel"]=@(host.commandWheel==nil);ended(a,@[a]);r[@"compact_drag"]=drain();}
{FakeTouch *a=touch(phone,host);began(a,@[a]);pump(0.1);[host cancelHostInput:nil];pump(0.5);
 r[@"cancelled_timeout_stays_closed"]=@(host.commandWheel==nil);ended(a,@[a]);r[@"wheel_cancelled_pending"]=drain();}
{FakeTouch *a=touch(CGPointMake(300,380),host);began(a,@[a]);pump(0.5);r[@"hud_hold_no_wheel"]=@(host.commandWheel==nil);ended(a,@[a]);r[@"compact_hud_hold"]=drain();}
// A foreground button can be touched while a map drag is still held. Opening
// commands must cancel the old press, not leave it down behind the wheel.
{FakeTouch *a=touch(phone,host);began(a,@[a]);moved(a,CGPointMake(330,180),@[a]);pump(0.15);
 [host showTouchCommandWheel:host.commandWheelButton];ended(a,@[a]);r[@"button_interrupts_drag"]=drain();[host cancelTouchCommandWheel];}
// Short cancelled map scrolling must release outside the world, never order
// at its center anchor merely because the app resized or lost focus.
{[host nativeMapScrollPhase:0 point:phone];[host nativeMapScrollPhase:1 point:CGPointMake(330,180)];
 [host cancelNativeGestures];pump(0.3);BOOL outside=NO;
 for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==4)outside=e.locationInWindow.x<0;
 r[@"early_scroll_cancel_outside"]=@(outside);drain();}
// Real layout code must move a whole wheel to one side of a fold, retain the
// original order target, and cancel when a camera/fold changes without resize.
host.touchOrderButton=[UIButton new];
((FixtureHost *)host).fixtureReservedRects=@[[NSValue valueWithCGRect:CGRectMake(385,0,30,400)]];
[host setNeedsLayout];[host layoutIfNeeded];
{FakeTouch *a=touch(CGPointMake(380,160),host);began(a,@[a]);pump(0.50);
 r[@"wheel_avoids_fold"]=@(host.commandWheel && host.commandWheel.wheelCenter.x+host.commandWheel.wheelRadius<=385);
 moved(a,CGPointMake(380,90),@[a]);ended(a,@[a]);pump(0.3);
 NSMutableArray *points=[NSMutableArray new];for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==3 || e.type==4)[points addObject:@[@(e.locationInWindow.x),@(e.locationInWindow.y)]];
 r[@"fold_order_anchor"]=points;drain();}
{FakeTouch *a=touch(phone,host);began(a,@[a]);pump(0.50);
 ((FixtureHost *)host).fixtureReservedRects=@[[NSValue valueWithCGRect:CGRectMake(0,180,800,40)]];
 [host setNeedsLayout];[host layoutIfNeeded];
 r[@"region_change_closes_wheel"]=@(host.commandWheel==nil);ended(a,@[a]);r[@"region_change_no_order"]=drain();}
// A last-moment region change must be checked before committing an action,
// even if the layout pass or polling timer has not seen it yet.
((FixtureHost *)host).fixtureReservedRects=@[];[host setNeedsLayout];[host layoutIfNeeded];
{FakeTouch *a=touch(phone,host);began(a,@[a]);pump(0.50);moved(a,CGPointMake(300,90),@[a]);
 ((FixtureHost *)host).fixtureReservedRects=@[[NSValue valueWithCGRect:CGRectMake(280,0,40,400)]];
 ended(a,@[a]);r[@"region_change_before_commit"]=drain();}
// Resize callbacks from the legacy engine must not shrink a full-screen host
// back to a cached outer-display mode. Windowed hosts still accept their size.
w.deUIKitWindow=fixtureWindow;w.styleMask=1UL<<14;
[w setFrame:CGRectMake(0,0,466,678) display:YES];
r[@"fullscreen_uses_scene"]=@(CGRectEqualToRect(w.contentView.frame,fixtureWindow.rootViewController.view.bounds));
w.styleMask=0;[w setFrame:CGRectMake(0,0,320,240) display:YES];
r[@"windowed_size_preserved"]=@(CGSizeEqualToSize(w.contentView.frame.size,CGSizeMake(320,240)));
// Use the actual host-to-AppKit bridge. The legacy engine only implements
// the live-resize pair; notifications must publish the new geometry between
// begin and end, and a reentrant layout must not duplicate the transaction.
host.frame=CGRectMake(0,0,320,240);w.contentView.deHost=host;
DEGameWindows=[NSHashTable weakObjectsHashTable];[DEGameWindows addObject:w];
w.deVisible=YES;w.deFrame=CGRectMake(0,0,951,669);
NSMutableArray *resizeEvents=[NSMutableArray new];NSMutableArray *observers=[NSMutableArray new];
for(NSString *name in @[@"NSWindowWillStartLiveResizeNotification",@"NSWindowDidResizeNotification",@"NSWindowDidEndLiveResizeNotification"]) {
 id token=[NSNotificationCenter.defaultCenter addObserverForName:name object:w queue:nil usingBlock:^(NSNotification *note){
  [resizeEvents addObject:@[note.name,@(w.deFrame.size.width),@(w.deFrame.size.height),@(w.deLiveResize)]];
  DEGameHostDidLayout(host);
 }];[observers addObject:token];
}
NSUInteger framesBefore=w.appliedFrames;
DEGameHostDidLayout(host);DEGameHostDidLayout(host);
r[@"resize_transaction"]=resizeEvents;
r[@"resize_subclass_setter"]=@(w.appliedFrames-framesBefore);
for(id token in observers)[NSNotificationCenter.defaultCenter removeObserver:token];
w.styleMask=1UL<<14;
DEGameHostDidLayout(host);
r[@"fullscreen_transaction_uses_scene"]=@(CGRectEqualToRect(w.deFrame,fixtureWindow.rootViewController.view.bounds) && CGRectEqualToRect(host.frame,fixtureWindow.rootViewController.view.bounds));
host.frame=CGRectMake(0,0,466,678);framesBefore=w.appliedFrames;
DEGameHostDidLayout(host);
r[@"fullscreen_repairs_stale_host"]=@(CGRectEqualToRect(host.frame,fixtureWindow.rootViewController.view.bounds) && w.appliedFrames==framesBefore+1);
// Screen identity can change without a size change. Deliver it once, after
// publishing the scene screen, independently of resize/backing notifications.
__block NSUInteger screenChanges=0;
id screenObserver=[NSNotificationCenter.defaultCenter addObserverForName:@"NSWindowDidChangeScreenNotification" object:w queue:nil usingBlock:^(NSNotification *note){
 NSCAssert(w.deReportedScreen==fixtureWindow.screen,@"screen callback must see new identity");screenChanges++;
}];
w.deReportedScreen=(UIScreen *)[NSObject new];
DEGameHostDidLayout(host);DEGameHostDidLayout(host);
r[@"screen_change_once"]=@(screenChanges);
[NSNotificationCenter.defaultCenter removeObserver:screenObserver];
// A normal landscape phone keeps both finger controls at full size, clear of
// the notch and home gesture, and hides them for a fitted desktop launcher.
w.deVisible=NO;host.frame=CGRectMake(0,0,874,402);
((FixtureHost *)host).fixtureInsets=UIEdgeInsetsMake(0,62,21,0);
((FixtureHost *)host).fixtureReservedRects=@[];
host.commandBackButton=[UIButton new];host.windowedPresentation=NO;
[host setNeedsLayout];[host layoutIfNeeded];
CGRect phoneSafe=UIEdgeInsetsInsetRect(host.bounds,host.safeAreaInsets);
r[@"phone_controls_full_size"]=@(host.commandWheelButton.bounds.size.height==44 && host.commandBackButton.bounds.size.height==44 && host.commandBackButton.bounds.size.width>=44);
r[@"phone_controls_inside_safe_area"]=@(CGRectContainsRect(phoneSafe,host.commandWheelButton.frame) && CGRectContainsRect(phoneSafe,host.commandBackButton.frame) && !CGRectIntersectsRect(host.commandWheelButton.frame,host.commandBackButton.frame));
host.windowedPresentation=YES;[host setNeedsLayout];[host layoutIfNeeded];
r[@"launcher_hides_game_controls"]=@(host.commandWheelButton.hidden && host.commandBackButton.hidden && host.touchOrderButton.hidden);
host.windowedPresentation=NO;
// Finger Back follows the same guarded Escape behavior as Pencil deselect.
pump(0.35);escapeDowns=0;DESetMaybeSelected(YES);DEMenuOpen=NO;DEGlobalTouchCommandMode=YES;
[host touchBack:host.commandBackButton];[host touchBack:host.commandBackButton];pump(0.35);
[host touchBack:host.commandBackButton];pump(0.1);
r[@"finger_back_escape_once"]=@(escapeDowns);
r[@"finger_back_disarms_orders"]=@(!DEGlobalTouchCommandMode && !DEMaybeSelected());
// Private HUD profile parsing and the actual host touch handlers, using only
// synthetic JSON/layout bytes. No original game files enter these fixtures.
host.frame=CGRectMake(0,0,800,400);w.contentView.deHost.frame=host.bounds;
((FixtureHost *)host).fixtureInsets=UIEdgeInsetsZero;((FixtureHost *)host).fixtureReservedRects=@[];
[host setNeedsLayout];[host layoutIfNeeded];
r[@"HUD_absent_unchanged"]=@([host HUDInputRegions].count==0);
NSString *priorCase=getenv("AGEPAD_CASE_INSENSITIVE_RESOURCE_ROOT")?@(getenv("AGEPAD_CASE_INSENSITIVE_RESOURCE_ROOT")):nil;
NSString *priorDevice=getenv("AGEPAD_DEVICE_DATA_ROOT")?@(getenv("AGEPAD_DEVICE_DATA_ROOT")):nil;
NSString *HUDRoot=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
NSString *layoutPath=[HUDRoot stringByAppendingPathComponent:@"widgetui/commandpanel.json"],*manifestPath=[HUDRoot stringByAppendingPathComponent:@"hud-input.json"];
[NSFileManager.defaultManager createDirectoryAtPath:layoutPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
NSData *layoutData=[@"{\"fixture\":true}" dataUsingEncoding:NSUTF8StringEncoding];[layoutData writeToFile:layoutPath atomically:YES];
NSDictionary *HUDRegion=@{@"x":@260,@"y":@100,@"width":@120,@"height":@100};
NSDictionary *HUDObstacle=@{@"x":@650,@"y":@100,@"width":@140,@"height":@210};
NSDictionary *HUDManifest=@{@"format":@1,@"profile":@"mac-488492.107976-phone-grid-v1",@"viewport":@{@"width":@800,@"height":@400},@"layout_sha256":AgePadSHA256(layoutData),@"regions":@[HUDRegion,HUDObstacle]};
void (^writeHUDManifest)(NSDictionary *)=^(NSDictionary *document){[[NSJSONSerialization dataWithJSONObject:document options:0 error:nil] writeToFile:manifestPath atomically:YES];};
writeHUDManifest(HUDManifest);setenv("AGEPAD_HUD_INPUT_REGIONS",manifestPath.fileSystemRepresentation,1);setenv("AGEPAD_CASE_INSENSITIVE_RESOURCE_ROOT",HUDRoot.fileSystemRepresentation,1);
r[@"HUD_valid_manifest"]=@([host HUDInputRegions].count==2);
NSArray *HUDCachedRects=[host HUDInputRegions];NSString *HUDCachedIdentity=DEHUDInputRegionsIdentityForBounds(host.bounds);BOOL alternates=YES;
for(NSUInteger i=0;i<40;i++) {
 alternates&=DEHUDInputRegionsForBounds(CGRectMake(0,0,214,162)).count==0;
 alternates&=DEHUDInputRegionsIdentityForBounds(CGRectMake(0,0,214,162))==nil;
 alternates&=[host HUDInputRegions]==HUDCachedRects;
 alternates&=[DEHUDInputRegionsIdentityForBounds(host.bounds) isEqual:HUDCachedIdentity];
}
r[@"HUD_alternating_hosts_reuse_cache"]=@(alternates);
unsetenv("AGEPAD_CASE_INSENSITIVE_RESOURCE_ROOT");setenv("AGEPAD_DEVICE_DATA_ROOT",HUDRoot.fileSystemRepresentation,1);
r[@"HUD_device_root_fallback"]=@([host HUDInputRegions].count==2);
setenv("AGEPAD_CASE_INSENSITIVE_RESOURCE_ROOT",HUDRoot.fileSystemRepresentation,1);
BOOL rejected=YES;
for(NSDictionary *change in @[@{@"format":@YES},@{@"format":@2},@{@"profile":@"other"},@{@"viewport":@{@"width":@799,@"height":@400}},
 @{@"layout_sha256":@"0000000000000000000000000000000000000000000000000000000000000000"},@{@"layout_sha256":@"missing"},
 @{@"regions":@[@{@"x":@260,@"y":@100,@"width":@0,@"height":@100}]},@{@"regions":@[@{@"x":@790,@"y":@100,@"width":@120,@"height":@100}]},
 @{@"regions":@[@{@"x":@"260",@"y":@100,@"width":@120,@"height":@100}]},@{@"regions":@[NSNull.null]},@{@"regions":@[]}]) {
 NSMutableDictionary *invalid=[HUDManifest mutableCopy];[invalid addEntriesFromDictionary:change];writeHUDManifest(invalid);rejected&=[host HUDInputRegions].count==0;
}
[@"{broken JSON" writeToFile:manifestPath atomically:YES encoding:NSUTF8StringEncoding error:nil];rejected&=[host HUDInputRegions].count==0;
writeHUDManifest(HUDManifest);r[@"HUD_rejects_invalid_profiles"]=@(rejected && [host HUDInputRegions].count==2);
[@"{\"fixture\":false}" writeToFile:layoutPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
r[@"HUD_hash_cache_revalidates"]=@([host HUDInputRegions].count==0);
[layoutData writeToFile:layoutPath atomically:YES];
r[@"HUD_hash_cache_recovers"]=@([host HUDInputRegions].count==2);
r[@"HUD_rejects_other_viewport"]=@(DEHUDInputRegionsForBounds(CGRectMake(0,0,801,400)).count==0);
[host setNeedsLayout];[host layoutIfNeeded];
CGRect HUDBox=CGRectMake(650,100,140,210);
r[@"HUD_controls_avoid_regions"]=@(!host.commandWheelButton.hidden && !host.commandBackButton.hidden && host.commandWheelButton.bounds.size.height==44 && host.commandBackButton.bounds.size.height==44 && !CGRectIntersectsRect(HUDBox,host.commandWheelButton.frame) && !CGRectIntersectsRect(HUDBox,host.commandBackButton.frame));
CGPoint HUDPoint=CGPointMake(300,160),worldPoint=CGPointMake(500,160);escapeDowns=0;
UIPanGestureRecognizer *HUDGesture=[UIPanGestureRecognizer new];
{DESetMaybeSelected(YES);DEGlobalTouchCommandMode=YES;DEPencilOrderArmed=YES;FakeTouch *a=touch(HUDPoint,host);began(a,@[a]);pump(0.5);
 r[@"HUD_hold_no_wheel"]=@(host.commandWheel==nil && NSApplication.sharedApplication.queue.events.count==1);
 r[@"HUD_native_gestures_blocked"]=@(![host gestureRecognizer:HUDGesture shouldReceiveTouch:(UITouch *)a]);
 ended(a,@[a]);finishPendingClicks();r[@"HUD_finger_primary"]=drain();
 r[@"HUD_preserves_selection_disarms_orders"]=@(DEMaybeSelected() && !DEGlobalTouchCommandMode && !DEPencilOrderArmed && escapeDowns==0);}
{DESetMaybeSelected(NO);DEPencilOrderArmed=YES;FakeTouch *a=touch(HUDPoint,host);a.type=UITouchTypePencil;began(a,@[a]);ended(a,@[a]);finishPendingClicks();r[@"HUD_pencil_primary"]=drain();r[@"HUD_never_arms_selection"]=@(!DEMaybeSelected() && !DEPencilOrderArmed);}
{FakeTouch *a=touch(HUDPoint,host),*b=touch(worldPoint,host);began(a,@[a]);began(b,@[a,b]);ended(a,@[a,b]);ended(b,@[a,b]);r[@"HUD_then_world_cancel"]=drain();}
{FakeTouch *a=touch(worldPoint,host),*b=touch(HUDPoint,host);began(a,@[a]);began(b,@[a,b]);ended(a,@[a,b]);ended(b,@[a,b]);r[@"world_then_HUD_cancel"]=drain();}
{FakeTouch *a=touch(HUDPoint,host);began(a,@[a]);moved(a,CGPointMake(420,160),@[a]);moved(a,HUDPoint,@[a]);ended(a,@[a]);r[@"HUD_leave_stays_cancelled"]=drain();}
{FakeTouch *a=touch(HUDPoint,host);began(a,@[a]);[@"changed" writeToFile:layoutPath atomically:YES encoding:NSUTF8StringEncoding error:nil];ended(a,@[a]);r[@"HUD_invalidated_contact_cancel"]=drain();[layoutData writeToFile:layoutPath atomically:YES];}
{FakeTouch *a=touch(HUDPoint,host);began(a,@[a]);ended(a,@[a]);[@"changed" writeToFile:layoutPath atomically:YES encoding:NSUTF8StringEncoding error:nil];finishPendingClicks();
 NSInteger ups=0;BOOL outside=YES;for(NSEvent *e in NSApplication.sharedApplication.queue.events)if(e.type==2){ups++;outside&=e.locationInWindow.x<0;}
 r[@"HUD_queued_click_revalidates"]=@[@(ups),@(outside)];r[@"HUD_queued_click_pair"]=drain();[layoutData writeToFile:layoutPath atomically:YES];}
{FakeTouch *a=touch(HUDPoint,host);began(a,@[a]);host.frame=CGRectMake(0,0,801,400);[host layoutIfNeeded];ended(a,@[a]);r[@"HUD_resize_cancels"]=drain();host.frame=CGRectMake(0,0,800,400);[host layoutIfNeeded];}
{FakeTouch *a=touch(worldPoint,host);r[@"HUD_world_gestures_remain_enabled"]=@([host gestureRecognizer:HUDGesture shouldReceiveTouch:(UITouch *)a]);began(a,@[a]);ended(a,@[a]);r[@"HUD_world_tap_unchanged"]=drain();}
unsetenv("AGEPAD_HUD_INPUT_REGIONS");
if(priorCase)setenv("AGEPAD_CASE_INSENSITIVE_RESOURCE_ROOT",priorCase.UTF8String,1);else unsetenv("AGEPAD_CASE_INSENSITIVE_RESOURCE_ROOT");
if(priorDevice)setenv("AGEPAD_DEVICE_DATA_ROOT",priorDevice.UTF8String,1);else unsetenv("AGEPAD_DEVICE_DATA_ROOT");
[NSFileManager.defaultManager removeItemAtPath:HUDRoot error:nil];
puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding].UTF8String);
return 0;}}
'''
(out/'TwoFingerProbe.m').write_text(preamble.replace('TWO_FINGER_WINDOW', window_line).replace('WINDOW_FRAME_HANDLER',window_frame)+protocol+interface+'\n@implementation DEGameViewHost\n'+shortcuts+handlers+'\n@end\n'+handler_lookup+window_layout+gestures+main)
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
subprocess.run(['xcrun','clang','-fobjc-arc','-Wno-deprecated-declarations','-target','arm64-apple-ios17.0-simulator','-isysroot',sdk,'-I',str(root/'port/de'),str(out/'TwoFingerProbe.m'),
                '-framework','Foundation','-framework','UIKit','-framework','QuartzCore','-framework','GameController','-framework','CoreGraphics','-o',str(out/'TwoFingerProbe')],check=True)
subprocess.run(['codesign','-s','-','--force',str(out/'TwoFingerProbe')],check=True,capture_output=True)
device=de_device.device_udid()
allowed,reason=de_device.require_sole_device(device)
if not allowed:
    print('COMPILED; runtime skipped: ' + reason); sys.exit(0)
run=subprocess.run(['xcrun','simctl','spawn',device,str(out/'TwoFingerProbe')],capture_output=True,text=True,timeout=60)
assert run.returncode==0,run.stderr[-2000:]
r=json.loads(run.stdout.strip().splitlines()[-1])
(out/'result.json').write_text(json.dumps(r,indent=1))
LEFT,RIGHT=[1,2],[3,4]
expect={'one_finger_tap':LEFT,'two_finger_tap':RIGHT,'slow_two_finger_tap':RIGHT,'uneven_lift':RIGHT,
        'HUD_absent_unchanged':True,'HUD_valid_manifest':True,'HUD_alternating_hosts_reuse_cache':True,'HUD_device_root_fallback':True,
        'HUD_rejects_invalid_profiles':True,'HUD_hash_cache_revalidates':True,'HUD_hash_cache_recovers':True,
        'HUD_rejects_other_viewport':True,'HUD_controls_avoid_regions':True,'HUD_hold_no_wheel':True,
        'HUD_native_gestures_blocked':True,'HUD_finger_primary':LEFT,'HUD_preserves_selection_disarms_orders':True,
        'HUD_pencil_primary':LEFT,'HUD_never_arms_selection':True,'HUD_then_world_cancel':[],'world_then_HUD_cancel':[],
        'HUD_leave_stays_cancelled':[],'HUD_invalidated_contact_cancel':[],'HUD_queued_click_revalidates':[1,True],
        'HUD_queued_click_pair':LEFT,'HUD_resize_cancels':[],'HUD_world_gestures_remain_enabled':True,'HUD_world_tap_unchanged':LEFT,
        'resized_pending_tap_up':[1,True],'resized_pending_tap':[1,6,2],
        'pending_tap_target':[[600,624],[600,624]],'pending_tap_button':LEFT,
        'cancel_rapid_pending_ups':[2,True],'cancel_rapid_pending':[1,1,6,2,6,2],
        'cancel_pending_order_up':[1,True],'cancel_pending_order':[3,7,4],
        'late_cancel_tap_up':[True,1,True],'late_cancel_tap':LEFT,
        'late_cancel_order_up':[True,1,True],'late_cancel_order':RIGHT,
        'queued_down_cancel_pair':[2,2,True,True],'queued_down_cancel':[1,2,1,6,2],
        'tap_while_holding_button':LEFT,'pinch':[],'three_fingers':[],
        'pencil_1_select':LEFT,'pencil_2_order':RIGHT,'pencil_3_order_again':RIGHT,'pencil_4_hold_deselect':LEFT,
        'pencil_5_select_again':LEFT,'pencil_6_hud_tap':LEFT,'pencil_7_after_hud':LEFT,'pencil_9_order_after_box':RIGHT,
        'pencil_after_finger_tap':LEFT,'pencil_select_before_two_finger':LEFT,'pencil_after_two_finger_order':RIGHT,'maybe_selected':True,
        'double_tap_escapes':1,'drag_released_early':False,'tiny_drag':[],'zoom_steps':[22,22],'zoom_left':0.6,
        'wheel_opened':True,'wheel_no_press_before_selection':True,'wheel_center_cancel':[],
        'compact_quick_tap':LEFT,'compact_slow_two_finger':RIGHT,'hud_hold_no_wheel':True,'compact_hud_hold':LEFT,
        'wheel_stationary_edge':[],'wheel_order':RIGHT,'wheel_order_anchor':[[30,240],[30,240]],
        'wheel_outside_cancel':[],'wheel_second_finger_cancel':[],'drag_never_opens_wheel':True,
        'wheel_avoids_fold':True,'fold_order_anchor':[[380,240],[380,240]],
        'region_change_closes_wheel':True,'region_change_no_order':[],'region_change_before_commit':[],
        'fullscreen_uses_scene':True,'windowed_size_preserved':True,
        'resize_transaction':[['NSWindowWillStartLiveResizeNotification',951,669,True],['NSWindowDidResizeNotification',320,240,True],['NSWindowDidEndLiveResizeNotification',320,240,False]],
        'resize_subclass_setter':1,
        'fullscreen_transaction_uses_scene':True,
        'fullscreen_repairs_stale_host':True,
        'screen_change_once':1,
        'phone_controls_full_size':True,'phone_controls_inside_safe_area':True,
        'launcher_hides_game_controls':True,'finger_back_escape_once':1,'finger_back_disarms_orders':True,
        'cancelled_timeout_stays_closed':True,'wheel_cancelled_pending':[],'early_scroll_cancel_outside':True}
bad={k:r[k] for k,v in expect.items() if r[k]!=v}
if r['one_finger_drag'][:1]!=[1] or r['one_finger_drag'][-1:]!=[2] or 6 not in r['one_finger_drag']: bad['one_finger_drag']=r['one_finger_drag']
if r['pencil_8_box'][:1]!=[1] or r['pencil_8_box'][-1:]!=[2] or 6 not in r['pencil_8_box']: bad['pencil_8_box']=r['pencil_8_box']
for name in ('compact_drag','button_interrupts_drag'):
    if r[name][:1]!=[1] or r[name][-1:]!=[2] or r[name].count(1)!=1:bad[name]=r[name]
def one_press(events): return [t for t in events if t in (3,4)]==[3,4] and events.count(7)>=5
def near(got,want,tolerance): return abs(got[0]-want[0])<=tolerance and abs(got[1]-want[1])<=tolerance
# The map moves 1.2 times the finger movement.
for name,want,tol in (('map_drag',(72,29),3),('flick',(-360,-180),5),('repeat_drag',(120,0),3)):
    if not one_press(r[name]): bad[name]=r[name]
    if not near(r[name+'_moved'],want,tol): bad[name+'_moved']=r[name+'_moved']
print(json.dumps(r))
assert not bad,'unexpected: %s' % bad
print('PASS: two-finger taps right-click only; Pencil tap selects, repeat taps order, hold/HUD disarm, only Pencil selections arm; one Escape per double-tap; map drag is a held right drag; zoom in whole steps')
