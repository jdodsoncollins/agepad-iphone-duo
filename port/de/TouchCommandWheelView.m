// AgePad-owned commands, styled to match the red/gold game-side controls.
// In hold mode the game host retains the touch; in tap mode these are ordinary
// accessible buttons. Drawing this view never posts an engine input event.
#import <UIKit/UIKit.h>
#include "TouchCommandWheel.h"
#include "TouchControlLayout.h"

@interface DETouchCommandWheelView : UIControl
@property(nonatomic) CGPoint wheelCenter;
@property(nonatomic) CGFloat wheelRadius;
@property(nonatomic) DECommandWheelAction selectedAction;
@property(nonatomic,strong) NSArray<UIButton *> *actionButtons;
@property(nonatomic,strong) UIButton *cancelButton;
@property(nonatomic,copy) void (^actionHandler)(DECommandWheelAction);
- (void)placeAtPoint:(CGPoint)point safeRect:(CGRect)safeRect;
- (void)trackPoint:(CGPoint)point;
@end

@implementation DETouchCommandWheelView
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.clearColor;self.opaque=NO;
        self.accessibilityViewIsModal=YES;_selectedAction=DECommandWheelNone;
        NSMutableArray *buttons=[NSMutableArray new];
        NSArray *titles=@[@"ORDER",@"IDLE",@"TOWN",@"ZOOM +",@"ZOOM −",@"MENU"];
        NSArray *labels=@[@"Order at held point",@"Select idle villager",@"Select town center",@"Zoom in",@"Zoom out",@"Game menu"];
        for(NSInteger i=0;i<DECommandWheelActionCount;i++) {
            UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];
            button.tag=i;[button setTitle:titles[i] forState:UIControlStateNormal];
            [button setTitleColor:[UIColor colorWithRed:0.99 green:0.88 blue:0.62 alpha:1] forState:UIControlStateNormal];
            button.titleLabel.font=[UIFont fontWithName:@"Georgia-Bold" size:12];
            button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.7;
            button.accessibilityLabel=labels[i];
            [button addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:button];[buttons addObject:button];
        }
        self.actionButtons=buttons;
        self.cancelButton=[UIButton buttonWithType:UIButtonTypeCustom];
        [self.cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
        self.cancelButton.titleLabel.font=[UIFont fontWithName:@"Georgia" size:12];
        [self.cancelButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        self.cancelButton.accessibilityLabel=@"Cancel command wheel";
        [self.cancelButton addTarget:self action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.cancelButton];
        [self addTarget:self action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)placeAtPoint:(CGPoint)point safeRect:(CGRect)safeRect {
    self.wheelRadius=DETouchWheelRadiusForBounds(safeRect.size.width,safeRect.size.height);
    double x,y;
    DEClampWheelCenter(point.x,point.y,CGRectGetMinX(safeRect),CGRectGetMinY(safeRect),
                      CGRectGetMaxX(safeRect),CGRectGetMaxY(safeRect),self.wheelRadius,&x,&y);
    self.wheelCenter=CGPointMake(x,y);self.selectedAction=DECommandWheelNone;
    [self setNeedsLayout];[self setNeedsDisplay];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    for(NSInteger i=0;i<DECommandWheelActionCount;i++) {
        double angle=-M_PI_2+i*M_PI/3;
        CGPoint p=CGPointMake(self.wheelCenter.x+cos(angle)*self.wheelRadius*0.66,
                             self.wheelCenter.y+sin(angle)*self.wheelRadius*0.66);
        self.actionButtons[i].frame=CGRectMake(p.x-22,p.y-22,44,44);
    }
    self.cancelButton.frame=CGRectMake(self.wheelCenter.x-22,self.wheelCenter.y-22,44,44);
}
- (void)trackPoint:(CGPoint)point {
    DECommandWheelAction action=DEWheelActionForOffset(point.x-self.wheelCenter.x,point.y-self.wheelCenter.y,self.wheelRadius);
    if(action==self.selectedAction)return;
    self.selectedAction=action;
    for(UIButton *button in self.actionButtons)button.alpha=action==DECommandWheelNone || button.tag==action?1:0.55;
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    CGPoint c=self.wheelCenter;CGFloat r=self.wheelRadius;
    CGContextRef context=UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context,[UIColor colorWithRed:0.30 green:0.045 blue:0.025 alpha:0.98].CGColor);
    CGContextFillEllipseInRect(context,CGRectMake(c.x-r,c.y-r,2*r,2*r));
    UIColor *gold=[UIColor colorWithRed:0.81 green:0.63 blue:0.30 alpha:1];
    if(self.selectedAction!=DECommandWheelNone) {
        CGFloat angle=-M_PI_2+self.selectedAction*M_PI/3;
        UIBezierPath *sector=[UIBezierPath bezierPath];[sector moveToPoint:c];
        [sector addArcWithCenter:c radius:r-3 startAngle:angle-M_PI/6 endAngle:angle+M_PI/6 clockwise:YES];
        [sector closePath];[[UIColor colorWithRed:0.66 green:0.26 blue:0.06 alpha:1] setFill];[sector fill];
    }
    CGContextSetStrokeColorWithColor(context,gold.CGColor);CGContextSetLineWidth(context,2);
    CGContextStrokeEllipseInRect(context,CGRectMake(c.x-r+1,c.y-r+1,2*r-2,2*r-2));
    CGContextStrokeEllipseInRect(context,CGRectMake(c.x-r+5,c.y-r+5,2*r-10,2*r-10));
    CGFloat inner=MAX(28,r*0.26);
    for(int i=0;i<6;i++) {
        CGFloat angle=-M_PI_2+(i+0.5)*M_PI/3;
        CGContextMoveToPoint(context,c.x+cos(angle)*inner,c.y+sin(angle)*inner);
        CGContextAddLineToPoint(context,c.x+cos(angle)*(r-5),c.y+sin(angle)*(r-5));
    }
    CGContextStrokePath(context);
    CGContextSetFillColorWithColor(context,[UIColor colorWithRed:0.19 green:0.04 blue:0.025 alpha:1].CGColor);
    CGContextFillEllipseInRect(context,CGRectMake(c.x-inner,c.y-inner,2*inner,2*inner));
    CGContextStrokeEllipseInRect(context,CGRectMake(c.x-inner,c.y-inner,2*inner,2*inner));
}
- (void)actionTapped:(UIButton *)sender { if(self.actionHandler)self.actionHandler((DECommandWheelAction)sender.tag); }
- (void)cancelTapped:(id)sender { if(self.actionHandler)self.actionHandler(DECommandWheelNone); }
@end
