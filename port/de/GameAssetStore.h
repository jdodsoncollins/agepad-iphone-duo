#import <Foundation/Foundation.h>

// Assets only. This store never touches the app program, saves, or Steam state.
@interface AgePadGameAssetStore : NSObject
@property(nonatomic,readonly) NSString *dataRoot;
@property(nonatomic,readonly) NSString *profileIdentifier;
@property(nonatomic,readonly) unsigned long long requiredBytes;
@property(nonatomic,readonly) BOOL validProfile;
- (instancetype)initWithHome:(NSString *)home profileURL:(NSURL *)url;
- (BOOL)isReady;
// Run these disk operations on a background queue. Progress contains no account data.
// Concurrent calls return a retryable AgePadGameAssets busy error (code 3).
- (BOOL)prepareExistingWithProgress:(void (^)(NSString *))progress error:(NSError **)error;
- (BOOL)importFolder:(NSURL *)folder progress:(void (^)(NSString *))progress error:(NSError **)error;
// Adopts only AgePad's private download staging tree, after a fresh SHA-256
// pass. Renames it into place; does not make a second 14.6 GB copy.
- (BOOL)installDownloadedFolder:(NSURL *)folder progress:(void (^)(NSString *))progress error:(NSError **)error;
@end
