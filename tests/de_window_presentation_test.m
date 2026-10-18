#import <UIKit/UIKit.h>
#include "WindowPresentation.h"
#include <stdio.h>

static void CheckClose(CGFloat a,CGFloat b,NSString *message) {
    NSCAssert(fabs(a-b)<0.001,@"%@: %g != %g",message,a,b);
}

int main(void) {
    @autoreleasepool {
        UIView *root=[[UIView alloc] initWithFrame:CGRectMake(0,0,874,402)];
        UIView *container=[UIView new],*host=[UIView new];
        [root addSubview:container];[container addSubview:host];
        CGSize launcher=CGSizeMake(930,640);
        CGRect safe=CGRectMake(59,0,756,381);
        NSCAssert(DEConfigureWindowPresentation(container,host,launcher,safe,NO),@"phone launcher must be fitted");
        NSCAssert(CGRectContainsRect(safe,container.frame),@"all launcher pixels fit asymmetric safe area");
        NSCAssert(CGRectEqualToRect(host.frame,CGRectMake(0,0,930,640)),@"host frame stays in original logical coordinates");
        NSCAssert(CGAffineTransformIsIdentity(host.transform),@"host itself must never be transformed");
        CheckClose(container.center.x,437,@"safe-area horizontal center");
        CheckClose(container.center.y,190.5,@"safe-area vertical center");
        CheckClose(container.transform.a,381.0/640,@"uniform fitting scale");
        CheckClose(container.transform.d,container.transform.a,@"uniform axes");

        CGPoint bottomButton=CGPointMake(850,600);
        CGPoint physical=[host convertPoint:bottomButton toView:root];
        NSCAssert(CGRectContainsPoint(safe,physical),@"previously clipped lower launcher button stays onscreen");
        CGPoint recovered=[host convertPoint:physical fromView:root];
        CheckClose(recovered.x,bottomButton.x,@"UIKit inverse pointer x");
        CheckClose(recovered.y,bottomButton.y,@"UIKit inverse pointer y");
        CGPoint expected=CGPointMake(CGRectGetMinX(container.frame)+bottomButton.x*container.transform.a,
                                    CGRectGetMinY(container.frame)+bottomButton.y*container.transform.d);
        CheckClose(physical.x,expected.x,@"rendered button x");
        CheckClose(physical.y,expected.y,@"rendered button y");

        CGRect narrower=CGRectMake(123,9,620,350);
        DEConfigureWindowPresentation(container,host,launcher,narrower,NO);
        NSCAssert(CGRectContainsRect(narrower,container.frame),@"safe-area-only changes refit presentation");
        NSCAssert(CGSizeEqualToSize(host.bounds.size,launcher),@"refitting preserves WebKit dimensions");

        CGRect large=CGRectMake(0,0,1400,1000);
        NSCAssert(!DEConfigureWindowPresentation(container,host,launcher,large,NO),@"large windows need no fit");
        NSCAssert(CGAffineTransformIsIdentity(container.transform),@"do not enlarge original UI");
        CheckClose(container.center.x,700,@"large window centered x");
        CheckClose(container.center.y,500,@"large window centered y");

        DEConfigureWindowPresentation(container,host,launcher,safe,NO);
        NSCAssert(!DEConfigureWindowPresentation(container,host,root.bounds.size,root.bounds,YES),@"fullscreen is never fitted");
        NSCAssert(CGAffineTransformIsIdentity(container.transform),@"fullscreen removes launcher transform");
        NSCAssert(CGRectEqualToRect(container.frame,root.bounds),@"fullscreen fills scene");
        NSCAssert(CGRectEqualToRect(host.frame,root.bounds),@"fullscreen uses actual scene logical dimensions");
        DEConfigureWindowPresentation(container,host,launcher,safe,NO);
        NSCAssert(CGSizeEqualToSize(host.bounds.size,launcher),@"return to launcher restores logical size");

        DEConfigureWindowPresentation(container,host,launcher,CGRectZero,NO);
        NSCAssert(container.hidden,@"unavailable scene area hides presentation");
        NSCAssert(CGAffineTransformIsIdentity(container.transform),@"zero-area presentation never has singular input transform");
        DEConfigureWindowPresentation(container,host,launcher,safe,NO);
        NSCAssert(!container.hidden,@"valid scene makes presentation visible again");

        [container removeFromSuperview];
        NSCAssert([root hitTest:physical withEvent:nil]==root,@"detached wrapper cannot block another window");
        puts("window presentation: PASS logical coordinates, phone fit, inverse input, safe-area refit, fullscreen reset, detach");
    }
    return 0;
}
