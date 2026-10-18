// Presentation geometry only: original AppKit/WebKit coordinates stay logical.
#pragma once
#import <UIKit/UIKit.h>
#include <math.h>

static inline CGFloat DEWindowPresentationScale(CGSize logical,CGRect available) {
    if(logical.width<=0 || logical.height<=0 || !isfinite(logical.width) || !isfinite(logical.height))return 1;
    return MAX(0,MIN(1,MIN(available.size.width/logical.width,available.size.height/logical.height)));
}

// Transform an ancestor, never the content host. UIView.frame remains usable
// by the original NSView implementation and UIKit converts input through the
// ancestor's inverse transform. A zero available area is temporarily hidden.
static inline BOOL DEConfigureWindowPresentation(UIView *container,UIView *content,CGSize logical,CGRect available,BOOL fullscreen) {
    CGFloat scale=DEWindowPresentationScale(logical,available);
    container.hidden=CGRectIsEmpty(available) || scale<=0;
    container.transform=CGAffineTransformIdentity;
    container.bounds=(CGRect){CGPointZero,logical};
    container.center=CGPointMake(CGRectGetMidX(available),CGRectGetMidY(available));
    // Avoid a singular transform while an unattached scene has zero bounds.
    container.transform=CGAffineTransformMakeScale(scale>0?scale:1,scale>0?scale:1);
    content.frame=(CGRect){CGPointZero,logical};
    return !fullscreen && scale<1;
}
