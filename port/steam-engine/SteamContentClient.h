#pragma once
#import <Foundation/Foundation.h>

// Steam's public content protocol, independent of the game and UIKit.
// Credentials stay in memory. The plan contains only the signed profile's assets.
@interface AgePadSteamContentClient : NSObject
@property(atomic) BOOL cancelled;
// Call on a worker queue. Never on the main queue.
- (NSDictionary *)prepareProfile:(NSDictionary *)profile appManifest:(NSString *)manifest
    token:(NSString *)token steamID:(uint64_t)steamID account:(NSString *)account
    progress:(void (^)(NSString *))progress error:(NSError **)error;
- (void)close;
@end

NSData *AgePadSteamDecodeChunk(NSData *encrypted, NSData *key, NSDictionary *chunk, NSError **error);
NSArray *AgePadSteamManifestFiles(NSData *zip, NSData *key, uint32_t depot, uint64_t manifest, NSError **error);
BOOL AgePadSteamContentHost(NSString *host);
