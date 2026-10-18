#pragma once
#import <Foundation/Foundation.h>
#import "GameAssetStore.h"

FOUNDATION_EXPORT NSString *const AgePadDownloadChanged;
FOUNDATION_EXPORT NSString *const AgePadDownloadSessionIdentifier;

@interface AgePadSteamAssetDownload : NSObject <NSURLSessionDownloadDelegate>
@property(atomic,readonly) NSDictionary *snapshot;
@property(nonatomic,readonly) BOOL busy;
+ (instancetype)shared;
- (void)configureStore:(AgePadGameAssetStore *)store;
- (void)start;
- (void)pause;
- (void)resume;
- (void)cancel;
// Reconnect even on a background-only launch, before any scene/game/Steam startup.
- (void)handleBackgroundSession:(NSString *)identifier completion:(void (^)(void))completion;
@end
