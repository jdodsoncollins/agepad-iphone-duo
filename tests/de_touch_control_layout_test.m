// Independent geometry checks for SDK-reported folds/camera exclusions.
// Runs as a command-line UIKit executable in the existing Simulator; no app UI.
#import <UIKit/UIKit.h>
#include "TouchControlLayout.h"
#include <stdio.h>

static unsigned failures;
#define CHECK(condition, message) do { \
    if (!(condition)) { fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,message);failures++; } \
} while (0)

static NSValue *Box(CGFloat x,CGFloat y,CGFloat width,CGFloat height) {
    return [NSValue valueWithCGRect:CGRectMake(x,y,width,height)];
}

static BOOL Overlaps(CGRect a,CGRect b) {
    CGRect intersection=CGRectIntersection(a,b);
    return !CGRectIsNull(intersection) && !CGRectIsEmpty(intersection);
}

static BOOL ContainsRectangle(NSArray<NSValue *> *rects,CGRect expected) {
    for(NSValue *value in rects) if(CGRectEqualToRect(value.CGRectValue,expected)) return YES;
    return NO;
}

// These are requirements on every output, independent of the subtraction
// algorithm: stay inside the usable view, avoid every obstacle, and return
// unique maximal candidates rather than redundant contained rectangles.
static void CheckRegions(CGRect safe,NSArray<NSValue *> *obstacles,NSArray<NSValue *> *regions) {
    for(NSUInteger i=0;i<regions.count;i++) {
        CGRect r=regions[i].CGRectValue;
        CHECK(!CGRectIsNull(r) && !CGRectIsEmpty(r),"candidate has positive area");
        CHECK(CGRectContainsRect(safe,r),"candidate remains inside asymmetric safe rect");
        for(NSValue *obstacle in obstacles) CHECK(!Overlaps(r,obstacle.CGRectValue),"candidate avoids all obstacles");
        for(NSUInteger j=0;j<regions.count;j++) if(i!=j) {
            CHECK(!CGRectEqualToRect(r,regions[j].CGRectValue),"candidates are unique");
            CHECK(!CGRectContainsRect(regions[j].CGRectValue,r),"candidate is not contained by another candidate");
        }
    }
}

static void TestDivisionAxes(void) {
    CGRect safe=CGRectMake(0,0,1000,800);
    NSArray *vertical=@[Box(490,-20,20,840)];
    NSArray *regions=DEClearControlRects(safe,vertical);
    CheckRegions(safe,vertical,regions);
    CHECK(regions.count==2,"vertical fold produces two usable sides");
    CHECK(ContainsRectangle(regions,CGRectMake(0,0,490,800)),"vertical fold preserves full-height left side");
    CHECK(ContainsRectangle(regions,CGRectMake(510,0,490,800)),"vertical fold preserves full-height right side");
    CGRect chosen=DEControlRegionNearPoint(regions,CGSizeMake(204,204),CGPointMake(900,400));
    CHECK(CGRectEqualToRect(chosen,CGRectMake(510,0,490,800)),"wheel chooses nearby side of vertical fold");

    NSArray *horizontal=@[Box(-20,390,1040,20)];
    regions=DEClearControlRects(safe,horizontal);
    CheckRegions(safe,horizontal,regions);
    CHECK(regions.count==2,"horizontal fold produces two usable halves");
    CHECK(ContainsRectangle(regions,CGRectMake(0,0,1000,390)),"horizontal fold preserves upper width");
    CHECK(ContainsRectangle(regions,CGRectMake(0,410,1000,390)),"horizontal fold preserves lower width");
    chosen=DEControlRegionNearPoint(regions,CGSizeMake(108,44),CGPointMake(990,790));
    CHECK(CGRectEqualToRect(chosen,CGRectMake(0,410,1000,390)),"trailing/lower preference selects lower half");
}

static void TestInteriorCamera(void) {
    CGRect safe=CGRectMake(0,0,600,600);
    NSArray *obstacles=@[Box(250,220,100,160)];
    NSArray *regions=DEClearControlRects(safe,obstacles);
    CheckRegions(safe,obstacles,regions);
    CHECK(regions.count==4,"interior camera preserves all four maximal strips");
    CHECK(ContainsRectangle(regions,CGRectMake(0,0,250,600)),"camera keeps full-height left strip");
    CHECK(ContainsRectangle(regions,CGRectMake(350,0,250,600)),"camera keeps full-height right strip");
    CHECK(ContainsRectangle(regions,CGRectMake(0,0,600,220)),"camera keeps full-width upper strip");
    CHECK(ContainsRectangle(regions,CGRectMake(0,380,600,220)),"camera keeps full-width lower strip");
    CGRect side=DEControlRegionNearPoint(regions,CGSizeMake(240,500),CGPointMake(590,300));
    CHECK(CGRectEqualToRect(side,CGRectMake(350,0,250,600)),"tall group fits beside interior camera across its height");
}

static void TestIntersectingObstacles(void) {
    CGRect safe=CGRectMake(0,0,1000,800);
    NSArray *obstacles=@[Box(490,-20,20,840),Box(-20,390,1040,20),Box(880,0,120,100)];
    NSArray *regions=DEClearControlRects(safe,obstacles);
    CheckRegions(safe,obstacles,regions);
    CHECK(ContainsRectangle(regions,CGRectMake(0,0,490,390)),"crossing folds preserve upper-left quadrant");
    CHECK(ContainsRectangle(regions,CGRectMake(0,410,490,390)),"crossing folds preserve lower-left quadrant");
    CHECK(ContainsRectangle(regions,CGRectMake(510,410,490,390)),"crossing folds preserve lower-right quadrant");
    CHECK(ContainsRectangle(regions,CGRectMake(510,100,490,290)),"camera clips only its quadrant");

    // Reordering SDK queries must preserve all valid fitting choices.
    NSArray *reversed=DEClearControlRects(safe,@[obstacles[2],obstacles[1],obstacles[0]]);
    CheckRegions(safe,obstacles,reversed);
    CHECK(regions.count==reversed.count,"obstacle order does not change maximal region count");
    for(NSValue *value in regions) CHECK(ContainsRectangle(reversed,value.CGRectValue),"obstacle order preserves candidate geometry");
}

static void TestAsymmetricSafeBox(void) {
    CGRect safe=CGRectMake(61,17,850,650);
    NSArray *obstacles=@[Box(-100,200,300,80),Box(700,500,400,400),Box(950,0,20,40)];
    NSArray *regions=DEClearControlRects(safe,obstacles);
    CheckRegions(safe,obstacles,regions);
    CGRect selected=DEControlRegionNearPoint(regions,CGSizeMake(108,44),CGPointMake(900,350));
    CHECK(!CGRectIsNull(selected),"asymmetric insets retain a fitting control region");
    CHECK(CGRectContainsRect(safe,selected),"selection keeps nonzero safe-area origin");

    NSArray *unobstructed=DEClearControlRects(safe,@[Box(950,0,20,40),Box(0,0,0,40),[NSValue valueWithCGRect:CGRectNull]]);
    CHECK(unobstructed.count==1 && CGRectEqualToRect(((NSValue *)unobstructed.firstObject).CGRectValue,safe),"outside/empty/null obstacles preserve usable area");
}

static void TestNoFitAndNearestFit(void) {
    CGRect safe=CGRectMake(10,20,300,200);
    CHECK(DEClearControlRects(CGRectZero,@[]).count==0,"empty safe area has no region");
    CHECK(DEClearControlRects(CGRectNull,@[]).count==0,"null safe area has no region");
    CHECK(DEClearControlRects(safe,@[Box(-100,-100,1000,1000)]).count==0,"fully occluded area has no region");
    CHECK(CGRectIsNull(DEControlRegionNearPoint(@[],CGSizeMake(108,44),CGPointZero)),"empty candidate list has no fitting region");
    NSArray *narrow=DEClearControlRects(safe,@[Box(100,0,10,300),Box(200,0,10,300)]);
    CHECK(CGRectIsNull(DEControlRegionNearPoint(narrow,CGSizeMake(108,44),CGPointMake(300,100))),"separate narrow strips cannot be combined across folds");

    NSArray *choices=@[Box(0,0,80,500),Box(100,0,300,500),Box(500,0,300,500)];
    CGRect selected=DEControlRegionNearPoint(choices,CGSizeMake(108,44),CGPointMake(20,250));
    CHECK(CGRectEqualToRect(selected,CGRectMake(100,0,300,500)),"nearest region skips undersized candidate containing preference");
    selected=DEControlRegionNearPoint(choices,CGSizeMake(108,44),CGPointMake(700,250));
    CHECK(CGRectEqualToRect(selected,CGRectMake(500,0,300,500)),"nearest suitable region follows preference");
    selected=DEControlRegionNearPoint(@[Box(12,34,108,44)],CGSizeMake(108,44),CGPointZero);
    CHECK(CGRectEqualToRect(selected,CGRectMake(12,34,108,44)),"an exactly fitting region is accepted");
    selected=DEControlRegionNearPoint(@[Box(0,0,100,100),Box(100,50,100,100)],CGSizeMake(100,100),CGPointMake(99,99));
    CHECK(CGRectEqualToRect(selected,CGRectMake(100,50,100,100)),"nearest means reachable group center, not distance to region edge");
}

static void TestEntireControlGroup(void) {
    CGRect safe=CGRectMake(23,11,900,700);
    NSArray *obstacles=@[Box(23,330,900,24),Box(830,450,50,90)];
    NSArray *regions=DEClearControlRects(safe,obstacles);
    CGSize groupSize=CGSizeMake(76,356); // Seven 44-point buttons, six 8-point gaps.
    CGPoint preferred=CGPointMake(900,650);
    CGRect region=DEControlRegionNearPoint(regions,groupSize,preferred);
    CHECK(!CGRectIsNull(region),"seven-button strip has a fitting lower region");
    if(CGRectIsNull(region)) return;
    CGRect group=CGRectMake(CGRectGetMaxX(region)-groupSize.width,
                            MAX(CGRectGetMinY(region),MIN(CGRectGetMaxY(region)-groupSize.height,preferred.y-groupSize.height/2)),
                            groupSize.width,groupSize.height);
    CHECK(CGRectContainsRect(safe,group),"entire strip remains inside usable area");
    for(NSValue *obstacle in obstacles) CHECK(!Overlaps(group,obstacle.CGRectValue),"entire strip including gaps avoids all reserved frames");
    for(unsigned i=0;i<7;i++) {
        CGRect button=CGRectMake(group.origin.x,group.origin.y+i*52,76,44);
        CHECK(CGRectContainsRect(group,button),"every full 44-point target fits its group");
        for(NSValue *obstacle in obstacles) CHECK(!Overlaps(button,obstacle.CGRectValue),"every target avoids reserved frames");
    }
}

int main(void) {
    @autoreleasepool {
        TestDivisionAxes();TestInteriorCamera();TestIntersectingObstacles();
        TestAsymmetricSafeBox();TestNoFitAndNearestFit();TestEntireControlGroup();
        if(failures) { fprintf(stderr,"touch control layout: %u failures\n",failures);return 1; }
        puts("touch control layout: PASS (fold axes, camera, intersections, asymmetric insets, fit selection, full strip)");
    }
    return 0;
}
