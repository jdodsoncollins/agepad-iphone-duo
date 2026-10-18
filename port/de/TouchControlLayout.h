// Unobstructed rectangles for a group of game controls. All coordinates are
// local view points; reserved-region frames already include UIKit's margins.
#pragma once
#import <UIKit/UIKit.h>

static inline NSArray<NSValue *> *DEClearControlRects(CGRect safe, NSArray<NSValue *> *obstacles) {
    if (CGRectIsEmpty(safe) || CGRectIsNull(safe)) return @[];
    NSArray<NSValue *> *rects=@[[NSValue valueWithCGRect:safe]];
    for (NSValue *value in obstacles) {
        CGRect obstacle=value.CGRectValue;
        if (CGRectIsEmpty(obstacle) || CGRectIsNull(obstacle)) continue;
        NSMutableArray<NSValue *> *next=[NSMutableArray new];
        for (NSValue *candidate in rects) {
            CGRect r=candidate.CGRectValue, cut=CGRectIntersection(r,obstacle);
            if (CGRectIsEmpty(cut) || CGRectIsNull(cut)) { [next addObject:candidate];continue; }
            // Keep overlapping maximal strips, rather than a disjoint tiling:
            // a wheel may fit beside a camera across the camera's full height.
            CGRect pieces[]={
                CGRectMake(CGRectGetMinX(r),CGRectGetMinY(r),CGRectGetMinX(cut)-CGRectGetMinX(r),r.size.height),
                CGRectMake(CGRectGetMaxX(cut),CGRectGetMinY(r),CGRectGetMaxX(r)-CGRectGetMaxX(cut),r.size.height),
                CGRectMake(CGRectGetMinX(r),CGRectGetMinY(r),r.size.width,CGRectGetMinY(cut)-CGRectGetMinY(r)),
                CGRectMake(CGRectGetMinX(r),CGRectGetMaxY(cut),r.size.width,CGRectGetMaxY(r)-CGRectGetMaxY(cut))
            };
            for (NSUInteger i=0;i<4;i++) if (!CGRectIsEmpty(pieces[i])) {
                NSValue *piece=[NSValue valueWithCGRect:pieces[i]];
                if (![next containsObject:piece]) [next addObject:piece];
            }
        }
        NSMutableArray *maximal=[NSMutableArray new];
        for (NSValue *candidate in next) {
            BOOL contained=NO;
            for (NSValue *other in next) if (candidate!=other &&
                !CGRectEqualToRect(candidate.CGRectValue,other.CGRectValue) &&
                CGRectContainsRect(other.CGRectValue,candidate.CGRectValue)) { contained=YES;break; }
            if (!contained && ![maximal containsObject:candidate]) [maximal addObject:candidate];
        }
        rects=maximal;
    }
    return rects;
}

// Return the closest region that can contain the complete control group.
// A trailing/lower preferred point makes edge controls reachable in either
// division axis, without guessing the device pose or hinge angle.
static inline CGRect DEControlRegionNearPoint(NSArray<NSValue *> *rects, CGSize minimum, CGPoint point) {
    CGRect best=CGRectNull;CGFloat distance=CGFLOAT_MAX;
    for (NSValue *value in rects) {
        CGRect r=value.CGRectValue;
        if (r.size.width<minimum.width || r.size.height<minimum.height) continue;
        CGFloat x=MAX(CGRectGetMinX(r)+minimum.width/2,MIN(CGRectGetMaxX(r)-minimum.width/2,point.x));
        CGFloat y=MAX(CGRectGetMinY(r)+minimum.height/2,MIN(CGRectGetMaxY(r)-minimum.height/2,point.y));
        CGFloat d=hypot(x-point.x,y-point.y);
        if (d<distance) { best=r;distance=d; }
    }
    return best;
}
