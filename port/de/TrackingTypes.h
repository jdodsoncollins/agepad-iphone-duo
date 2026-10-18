#pragma once
// The game-layer hover adapter and development desktop web host share these
// event shapes. They do not require any legacy WebKit implementation.
@protocol DETrackingConfig
- (NSUInteger)options;
- (CGRect)rect;
- (id)owner;
@end
@protocol DEHoverEvent
- (void)setType:(NSUInteger)value;
- (void)setLocationInWindow:(CGPoint)value;
- (void)setTimestamp:(NSTimeInterval)value;
- (void)setTrackingArea:(id)value;
@end
@interface DEWebTrackingRecord : NSObject
@property(nonatomic,strong) id<DETrackingConfig> area;
@property(nonatomic) BOOL inside;
@end
@implementation DEWebTrackingRecord @end
