#import "GameAssetStore.h"
#import "DataDigest.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>

static BOOL GAError(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"AgePadGameAssets" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL GABusy(NSError **error) {
    if(error)*error=[NSError errorWithDomain:@"AgePadGameAssets" code:3 userInfo:@{NSLocalizedDescriptionKey:@"AgePad is already working on the game files. Please try again when it finishes."}];
    return NO;
}
static BOOL GARelative(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length || path.isAbsolutePath ||
        [path containsString:@"\\"] || [path rangeOfString:@"\0"].location!=NSNotFound) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static BOOL GAInside(NSString *root, NSString *path) {
    NSString *realRoot=root.stringByResolvingSymlinksInPath;
    NSString *realPath=path.stringByResolvingSymlinksInPath;
    return [realPath hasPrefix:[realRoot stringByAppendingString:@"/"]];
}
// Validate each parent directory once per inventory scan. Resolving every
// complete pathname repeats the same ancestor I/O tens of thousands of times.
static BOOL GARegularParents(NSString *root,NSString *path,NSMutableSet *checked) {
    NSString *parent=path.stringByDeletingLastPathComponent;
    if([checked containsObject:parent])return YES;
    if(![parent hasPrefix:[root stringByAppendingString:@"/"]]&&![parent isEqual:root])return NO;
    NSMutableArray *pending=[NSMutableArray new];
    while(![checked containsObject:parent]) {
        [pending addObject:parent];if([parent isEqual:root])break;
        parent=parent.stringByDeletingLastPathComponent;
    }
    for(NSString *directory in pending.reverseObjectEnumerator){struct stat st;
        if(lstat(directory.fileSystemRepresentation,&st)||!S_ISDIR(st.st_mode))return NO;
        [checked addObject:directory];
    }return YES;
}
static BOOL GATransfer(NSString *source, NSString *destination, NSDictionary *entry, NSError **error) {
    struct stat st;
    int input=open(source.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    if (input<0 || fstat(input,&st) || !S_ISREG(st.st_mode) || (uint64_t)st.st_size!=[entry[@"bytes"] unsignedLongLongValue]) {
        if(input>=0)close(input);return GAError(error,@"A required game file is missing or incomplete. Choose the supported AgeOfEmpires2Data folder.");
    }
    int output=-1;
    if(destination) {
        [NSFileManager.defaultManager createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        output=open(destination.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        if(output<0){close(input);return GAError(error,@"Couldn't create the imported game files. Check free space and try again.");}
    }
    CC_SHA256_CTX hash;CC_SHA256_Init(&hash);unsigned char buffer[1<<18];BOOL ok=YES;unsigned long long size=0;
    for(;;) {
        ssize_t n=read(input,buffer,sizeof buffer);if(n==0)break;
        if(n<0){ok=NO;break;}size+=(unsigned long long)n;CC_SHA256_Update(&hash,buffer,(CC_LONG)n);
        if(output>=0)for(ssize_t at=0;at<n;) { ssize_t wrote=write(output,buffer+at,(size_t)(n-at));if(wrote<=0){ok=NO;break;}at+=wrote; }
        if(!ok)break;
    }
    close(input);if(output>=0){if(fsync(output))ok=NO;close(output);}
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&hash);
    NSMutableString *hex=[NSMutableString new];for(unsigned i=0;i<sizeof digest;i++) [hex appendFormat:@"%02x",digest[i]];
    if(!ok || size!=[entry[@"bytes"] unsignedLongLongValue] || ![hex isEqual:entry[@"sha256"]]) {
        if(destination)unlink(destination.fileSystemRepresentation);
        return GAError(error,@"The game files don't match this supported game version, or the transfer was interrupted. The previous install is preserved.");
    }
    return YES;
}

@interface AgePadGameAssetStore ()
@property(nonatomic,copy) NSString *home,*support,*receiptPath,*profileHash;
@property(nonatomic,strong) NSDictionary *profile;
@property(nonatomic,strong) NSSet<NSString *> *knownPaths;
@property(nonatomic,strong) NSRecursiveLock *mutationLock;
@property(nonatomic,readwrite,copy) NSString *dataRoot,*profileIdentifier;
@property(nonatomic,readwrite) unsigned long long requiredBytes;
@property(nonatomic,readwrite) BOOL validProfile;
@end
@implementation AgePadGameAssetStore
- (instancetype)initWithHome:(NSString *)home profileURL:(NSURL *)url {
    if(!(self=[super init]))return nil;
    self.mutationLock=[NSRecursiveLock new];
    self.home=home.stringByStandardizingPath;self.dataRoot=[self.home stringByAppendingPathComponent:@"Documents/AgeOfEmpires2Data"];
    self.support=[self.home stringByAppendingPathComponent:@"Library/Application Support/AgePad"];
    self.receiptPath=[self.support stringByAppendingPathComponent:@"InstallReceipt.json"];
    NSData *raw=[NSData dataWithContentsOfURL:url];
    id profile=raw.length && raw.length<(16<<20)?[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL]:nil;
    if(![profile isKindOfClass:NSDictionary.class] || [profile[@"schema_version"] integerValue]!=1 ||
        ![profile[@"profile_id"] isKindOfClass:NSString.class] || [profile[@"steam_app_id"] unsignedIntValue]!=813780 ||
        ![profile[@"entries"] isKindOfClass:NSArray.class] || ![profile[@"excluded"] isKindOfClass:NSArray.class] ||
        ![profile[@"entries"] count] || [profile[@"entries"] count]>50000 || [profile[@"excluded"] count]>50000) return self;
    NSMutableSet *known=[NSMutableSet new];unsigned long long size=0;
    for(NSString *group in @[@"entries",@"excluded"]) for(id item in profile[group]) {
        if(![item isKindOfClass:NSDictionary.class] || !GARelative(item[@"path"]) ||
            ![item[@"bytes"] isKindOfClass:NSNumber.class] || [item[@"bytes"] longLongValue]<0 || [known containsObject:item[@"path"]])return self;
        [known addObject:item[@"path"]];
        if([group isEqual:@"entries"]) {
            NSString *sha=item[@"sha256"];
            if(![sha isKindOfClass:NSString.class] || sha.length!=64 ||
                [sha rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound)return self;
            size+=[item[@"bytes"] unsignedLongLongValue];
        }
    }
    if(size!=[profile[@"bytes"] unsignedLongLongValue] || [profile[@"files"] unsignedLongLongValue]!=[profile[@"entries"] count])return self;
    self.profile=profile;self.profileHash=AgePadSHA256(raw);self.knownPaths=known;
    self.requiredBytes=size;self.profileIdentifier=profile[@"profile_id"];self.validProfile=YES;return self;
}
- (BOOL)isReady {
    if(!self.validProfile)return NO;
    struct stat root;
    if(!GAInside(self.home,self.dataRoot) || lstat(self.dataRoot.fileSystemRepresentation,&root) || !S_ISDIR(root.st_mode))return NO;
    NSData *raw=[NSData dataWithContentsOfFile:self.receiptPath];
    NSDictionary *receipt=raw?[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL]:nil;
    if(![receipt isKindOfClass:NSDictionary.class] || ![receipt[@"profile_sha256"] isEqual:self.profileHash])return NO;
    NSMutableSet *checkedDirectories=[NSMutableSet setWithObject:self.dataRoot];
    for(NSDictionary *entry in self.profile[@"entries"]) {
        NSString *path=[self.dataRoot stringByAppendingPathComponent:entry[@"path"]];struct stat st;
        if(!GARegularParents(self.dataRoot,path,checkedDirectories) || lstat(path.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) ||
            (uint64_t)st.st_size!=[entry[@"bytes"] unsignedLongLongValue])return NO;
    }
    return YES;
}
- (unsigned long long)cleanTransientCaches:(NSError **)error {
    unsigned long long bytes=0;NSFileManager *fm=NSFileManager.defaultManager;
    for(NSString *relative in @[@"Library/Caches",@"tmp"]) {
        NSString *folder=[self.home stringByAppendingPathComponent:relative];
        struct stat root;
        if(!lstat(folder.fileSystemRepresentation,&root) && (!S_ISDIR(root.st_mode) || !GAInside(self.home,folder))) {
            GAError(error,@"The cache folder isn't a directory inside AgePad.");return ULLONG_MAX;
        }
        for(NSString *name in [fm contentsOfDirectoryAtPath:folder error:NULL]) {
            // Keep only an actively captured diagnostic, never Steam's license
            // database, saves or account metadata (which live outside Caches).
            if([relative isEqual:@"Library/Caches"] && [name isEqual:@"AgePadDiagnostics"] && getenv("AGEPAD_DEVICE_LOG_FILE"))continue;
            NSString *path=[folder stringByAppendingPathComponent:name];
            if(!GAInside(self.home,folder)){GAError(error,@"The cache folder isn't inside AgePad.");return ULLONG_MAX;}
            NSDictionary *attr=[fm attributesOfItemAtPath:path error:NULL];
            if([attr[NSFileType] isEqual:NSFileTypeRegular])bytes+=[attr[NSFileSize] unsignedLongLongValue];
            for(NSURL *file in [attr[NSFileType] isEqual:NSFileTypeDirectory]?[fm enumeratorAtURL:[NSURL fileURLWithPath:path] includingPropertiesForKeys:@[NSURLFileSizeKey,NSURLIsRegularFileKey] options:0 errorHandler:nil]:nil) {
                NSNumber *regular=nil,*size=nil;[file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
                if(regular.boolValue){[file getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];bytes+=size.unsignedLongLongValue;}
            }
            if(![fm removeItemAtPath:path error:error])return ULLONG_MAX;
        }
    }
    return bytes;
}
- (BOOL)finishInstall:(NSError **)error {
    NSFileManager *fm=NSFileManager.defaultManager;unsigned long long removed=0;unsigned count=0;
    NSMutableSet<NSString *> *emptyCandidates=[NSMutableSet new];
    for(NSDictionary *entry in self.profile[@"excluded"]) {
        NSString *path=[self.dataRoot stringByAppendingPathComponent:entry[@"path"]];struct stat st;
        if(!GAInside(self.dataRoot,path) || lstat(path.fileSystemRepresentation,&st))continue;
        // Only known source paths and sizes are eligible. Unknown files stay.
        if(S_ISREG(st.st_mode) && (uint64_t)st.st_size==[entry[@"bytes"] unsignedLongLongValue]) {
            if(![fm removeItemAtPath:path error:error])return NO;
            removed+=(unsigned long long)st.st_size;count++;
            NSString *parent=path.stringByDeletingLastPathComponent;
            while(GAInside(self.dataRoot,parent)) { [emptyCandidates addObject:parent];parent=parent.stringByDeletingLastPathComponent; }
        }
    }
    for(NSString *folder in [emptyCandidates.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b) {
        return a.length>b.length?NSOrderedAscending:a.length<b.length?NSOrderedDescending:NSOrderedSame;
    }])rmdir(folder.fileSystemRepresentation); // Empty directories only; user content is never traversed/deleted here.
    [fm removeItemAtPath:[self.dataRoot stringByAppendingPathComponent:@".agepad-import-inventory-checked"] error:NULL];
    [fm removeItemAtPath:[self.dataRoot stringByAppendingPathComponent:@"update_hosts_cached.vdf"] error:NULL];
    unsigned long long cacheBytes=[self cleanTransientCaches:error];if(cacheBytes==ULLONG_MAX)return NO;
    [fm createDirectoryAtPath:self.support withIntermediateDirectories:YES attributes:nil error:error];
    NSDictionary *receipt=@{@"profile_sha256":self.profileHash,@"profile_id":self.profileIdentifier,
        @"files":self.profile[@"files"],@"bytes":@(self.requiredBytes),@"sha256_verified":@YES,
        @"removed_asset_files":@(count),@"removed_asset_bytes":@(removed),@"cleared_cache_bytes":@(cacheBytes)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:receipt options:0 error:error];
    if(!data || ![data writeToFile:self.receiptPath options:NSDataWritingAtomic error:error])return NO;
    fprintf(stderr,"AGEPAD_ASSET_INSTALL ready=1 files=%lu bytes=%llu removed_files=%u removed_bytes=%llu cleared_cache_bytes=%llu\n",
        (unsigned long)[self.profile[@"entries"] count],self.requiredBytes,count,removed,cacheBytes);return YES;
}
- (BOOL)prepareExistingWithProgress:(void (^)(NSString *))progress error:(NSError **)error {
    if(![self.mutationLock tryLock])return GABusy(error);
    @try {
        if(!self.validProfile)return GAError(error,@"This build has no valid game-data profile.");
        if([self isReady])return [self removeStaleInstalls:error];
        NSFileManager *fm=NSFileManager.defaultManager;
        if(![fm fileExistsAtPath:self.dataRoot]) {
            // Recover the old tree if termination happened between the two renames.
            // Never discard a backup merely because a receipt from an older install exists.
            NSMutableArray<NSString *> *backups=[NSMutableArray new];
            for(NSString *name in [fm contentsOfDirectoryAtPath:self.support error:NULL]) {
                NSString *path=[self.support stringByAppendingPathComponent:name];struct stat st;
                if([name hasPrefix:@"PreviousInstall-"] && GAInside(self.home,path) &&
                    !lstat(path.fileSystemRepresentation,&st) && S_ISDIR(st.st_mode))[backups addObject:path];
            }
            if(backups.count!=1)return GAError(error,@"Import your game files from Files to continue.");
            [fm createDirectoryAtPath:self.dataRoot.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
            if(![fm moveItemAtPath:backups.firstObject toPath:self.dataRoot error:error])return NO;
        }
        struct stat root;
        if(!GAInside(self.home,self.dataRoot) || lstat(self.dataRoot.fileSystemRepresentation,&root) || !S_ISDIR(root.st_mode))
            return GAError(error,@"The installed game-data folder is invalid. Import a fresh copy from Files.");
        NSUInteger n=0;
        for(NSDictionary *entry in self.profile[@"entries"]) {
            NSString *path=[self.dataRoot stringByAppendingPathComponent:entry[@"path"]];
            if(!GAInside(self.dataRoot,path) || !GATransfer(path,nil,entry,error))return NO;
            if(progress && (++n%128==0))progress([NSString stringWithFormat:@"Verifying game files · %lu%%",(unsigned long)(n*100/[self.profile[@"entries"] count])]);
        }
        if(progress)progress(@"Removing superseded assets and caches…");
        return [self finishInstall:error] && [self removeStaleInstalls:error];
    } @finally {[self.mutationLock unlock];}
}
- (BOOL)discardBackup:(NSString *)backup error:(NSError **)error {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *preserved=[self.home stringByAppendingPathComponent:[@"Documents/PreservedGameData/" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSDirectoryEnumerator *walk=[fm enumeratorAtPath:backup];NSMutableArray *unknown=[NSMutableArray new];
    for(NSString *relative in walk) {
        NSString *path=[backup stringByAppendingPathComponent:relative];NSDictionary *a=[fm attributesOfItemAtPath:path error:NULL];
        if(![a[NSFileType] isEqual:NSFileTypeDirectory] && ![self.knownPaths containsObject:relative] &&
            ![relative.lastPathComponent isEqual:@".agepad-import-inventory-checked"] && ![relative.lastPathComponent isEqual:@"update_hosts_cached.vdf"]) [unknown addObject:relative];
    }
    for(NSString *relative in unknown) {
        NSString *destination=[preserved stringByAppendingPathComponent:relative];
        [fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error];
        if(![fm moveItemAtPath:[backup stringByAppendingPathComponent:relative] toPath:destination error:error])return NO;
    }
    return [fm removeItemAtPath:backup error:error];
}
- (BOOL)removeStaleInstalls:(NSError **)error {
    NSFileManager *fm=NSFileManager.defaultManager;
    for(NSString *name in [fm contentsOfDirectoryAtPath:self.support error:NULL]) {
        NSString *path=[self.support stringByAppendingPathComponent:name];
        if(!GAInside(self.home,path))continue;
        if([name hasPrefix:@"InstallStaging-"]) { if(![fm removeItemAtPath:path error:error])return NO; }
        else if([name hasPrefix:@"PreviousInstall-"] && ![self discardBackup:path error:error])return NO;
    }
    return YES;
}
- (BOOL)importFolder:(NSURL *)folder progress:(void (^)(NSString *))progress error:(NSError **)error {
    if(![self.mutationLock tryLock])return GABusy(error);
    @try {
        if(!self.validProfile || !folder.isFileURL)return GAError(error,@"Choose the AgeOfEmpires2Data folder in Files.");
        NSString *source=folder.path.stringByResolvingSymlinksInPath;
        if([source isEqual:self.dataRoot.stringByResolvingSymlinksInPath])return [self prepareExistingWithProgress:progress error:error];
        NSFileManager *fm=NSFileManager.defaultManager;
        NSDictionary *disk=[fm attributesOfFileSystemForPath:self.home error:NULL];
        if([disk[NSFileSystemFreeSize] unsignedLongLongValue]<self.requiredBytes+(64<<20))
            return GAError(error,@"There isn't enough free space for a verified import. Free some space and try again.");
        [fm createDirectoryAtPath:self.support withIntermediateDirectories:YES attributes:nil error:error];
        NSString *stage=[self.support stringByAppendingPathComponent:[@"InstallStaging-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:error];
        BOOL ok=YES;NSUInteger n=0;
        for(NSDictionary *entry in self.profile[@"entries"]) {
            NSString *path=[source stringByAppendingPathComponent:entry[@"path"]];
            if(!GAInside(source,path) || !GATransfer(path,[stage stringByAppendingPathComponent:entry[@"path"]],entry,error)){ok=NO;break;}
            if(progress && (++n%128==0))progress([NSString stringWithFormat:@"Importing game files · %lu%%",(unsigned long)(n*100/[self.profile[@"entries"] count])]);
        }
        if(!ok){[fm removeItemAtPath:stage error:NULL];return NO;}
        return [self commitStaging:stage error:error];
    } @finally {[self.mutationLock unlock];}
}
- (BOOL)installDownloadedFolder:(NSURL *)folder progress:(void (^)(NSString *))progress error:(NSError **)error {
    if(![self.mutationLock tryLock])return GABusy(error);
    @try {
        NSString *allowed=[self.home stringByAppendingPathComponent:@"Library/Application Support/AgePadDownloads/813780/content"];
        struct stat st;
        if(!self.validProfile||!folder.isFileURL||![folder.path isEqual:allowed]||!GAInside(self.home,allowed)||
            lstat(allowed.fileSystemRepresentation,&st)||!S_ISDIR(st.st_mode))return GAError(error,@"The downloaded game folder is invalid.");
        NSUInteger n=0;
        for(NSDictionary *entry in self.profile[@"entries"]) {
            NSString *path=[allowed stringByAppendingPathComponent:entry[@"path"]];
            if(!GAInside(allowed,path)||!GATransfer(path,nil,entry,error)){
                if(error)*error=[NSError errorWithDomain:@"AgePadGameAssets" code:2 userInfo:@{NSLocalizedDescriptionKey:@"A downloaded game file failed verification. Resume to repair it.",@"AgePadInvalidAssetPath":entry[@"path"]}];return NO;
            }
            if(progress&&++n%128==0)progress([NSString stringWithFormat:@"Verifying download · %lu%%",(unsigned long)(n*100/[self.profile[@"entries"] count])]);
        }
        return [self commitStaging:allowed error:error];
    } @finally {[self.mutationLock unlock];}
}
- (BOOL)commitStaging:(NSString *)stage error:(NSError **)error {
    NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:self.support withIntermediateDirectories:YES attributes:nil error:error];
    NSString *backup=[self.support stringByAppendingPathComponent:[@"PreviousInstall-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    BOOL hadOld=[fm fileExistsAtPath:self.dataRoot];
    if(hadOld && ![fm moveItemAtPath:self.dataRoot toPath:backup error:error]){[fm removeItemAtPath:stage error:NULL];return NO;}
    [fm createDirectoryAtPath:self.dataRoot.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error];
    if(![fm moveItemAtPath:stage toPath:self.dataRoot error:error]) {
        if(hadOld)[fm moveItemAtPath:backup toPath:self.dataRoot error:NULL];[fm removeItemAtPath:stage error:NULL];return NO;
    }
    if(![self finishInstall:error])return NO;
    return [self removeStaleInstalls:error];
}
@end
