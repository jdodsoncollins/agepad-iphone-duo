#import <Foundation/Foundation.h>
#import "GameAssetStore.h"
#import <CommonCrypto/CommonDigest.h>

static unsigned checks;
static void check(BOOL pass, NSString *what) { if(!pass){fprintf(stderr,"FAIL %s\n",what.UTF8String);exit(1);}checks++; }
static void put(NSString *path, NSString *value) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
static NSString *hash(NSString *value) {
    NSData *data=[value dataUsingEncoding:NSUTF8StringEncoding];unsigned char h[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,h);
    NSMutableString *s=[NSMutableString new];for(unsigned i=0;i<sizeof h;i++)[s appendFormat:@"%02x",h[i]];return s;
}
static NSURL *profile(NSString *home, NSString *path) {
    NSDictionary *p=@{@"schema_version":@1,@"profile_id":@"fixture",@"steam_app_id":@813780,@"files":@1,@"bytes":@4,
        @"entries":@[@{@"path":path,@"bytes":@4,@"sha256":hash(@"CORE")}],
        @"excluded":@[@{@"path":@"modes/optional.bin",@"bytes":@8}]};
    NSString *file=[home stringByAppendingPathComponent:@"profile.json"];
    [[NSJSONSerialization dataWithJSONObject:p options:0 error:NULL] writeToFile:file atomically:YES];return [NSURL fileURLWithPath:file];
}
static void concurrentMutations(void) {
    NSString *home=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *source=[home stringByAppendingPathComponent:@"Source"];
    NSString *download=[home stringByAppendingPathComponent:@"Library/Application Support/AgePadDownloads/813780/content"];
    NSString *support=[home stringByAppendingPathComponent:@"Library/Application Support/AgePad"];
    NSMutableArray *entries=[NSMutableArray new];
    for(unsigned i=0;i<129;i++)[entries addObject:@{@"path":[NSString stringWithFormat:@"resources/%03u.bin",i],@"bytes":@4,@"sha256":hash(@"CORE")}];
    NSDictionary *p=@{@"schema_version":@1,@"profile_id":@"concurrency",@"steam_app_id":@813780,@"files":@129,@"bytes":@(129*4),@"entries":entries,@"excluded":@[]};
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *file=[home stringByAppendingPathComponent:@"profile.json"];
    [[NSJSONSerialization dataWithJSONObject:p options:0 error:NULL] writeToFile:file atomically:YES];
    AgePadGameAssetStore *store=[[AgePadGameAssetStore alloc] initWithHome:home profileURL:[NSURL fileURLWithPath:file]];
    for(NSDictionary *entry in entries)for(NSString *root in @[store.dataRoot,source,download])put([root stringByAppendingPathComponent:entry[@"path"]],@"CORE");
    NSError *error=nil;
    check([store prepareExistingWithProgress:nil error:&error]&&[store isReady],@"129-file existing install is valid before concurrent import");
    check([store importFolder:[NSURL fileURLWithPath:store.dataRoot] progress:nil error:&error],@"importing the installed data root can prepare it recursively");
    dispatch_semaphore_t paused=dispatch_semaphore_create(0),resume=dispatch_semaphore_create(0),finished=dispatch_semaphore_create(0);
    __block BOOL imported=NO;__block NSError *importError=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        imported=[store importFolder:[NSURL fileURLWithPath:source] progress:^(NSString *message){
            dispatch_semaphore_signal(paused);
            dispatch_semaphore_wait(resume,DISPATCH_TIME_FOREVER);
        } error:&importError];
        dispatch_semaphore_signal(finished);
    }});
    check(dispatch_semaphore_wait(paused,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,@"Files import pauses at its first progress callback after file 128");
    NSString *stage=nil;
    for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:support error:NULL])
        if([name hasPrefix:@"InstallStaging-"])stage=[support stringByAppendingPathComponent:name];
    check(stage&&[NSFileManager.defaultManager contentsOfDirectoryAtPath:[stage stringByAppendingPathComponent:@"resources"] error:NULL].count==128,@"paused import has exactly 128 real staged files");
    NSDictionary *oldFile=[NSFileManager.defaultManager attributesOfItemAtPath:[store.dataRoot stringByAppendingPathComponent:@"resources/000.bin"] error:NULL];
    NSError *downloadError=nil,*secondImportError=nil,*cleanupError=nil;
    BOOL adopted=[store installDownloadedFolder:[NSURL fileURLWithPath:download] progress:nil error:&downloadError];
    BOOL secondImported=[store importFolder:[NSURL fileURLWithPath:source] progress:nil error:&secondImportError];
    BOOL cleaned=[store prepareExistingWithProgress:nil error:&cleanupError];
    BOOL stageIntact=[NSFileManager.defaultManager contentsOfDirectoryAtPath:[stage stringByAppendingPathComponent:@"resources"] error:NULL].count==128;
    BOOL oldIntact=[oldFile[NSFileSystemFileNumber] isEqual:[NSFileManager.defaultManager attributesOfItemAtPath:[store.dataRoot stringByAppendingPathComponent:@"resources/000.bin"] error:NULL][NSFileSystemFileNumber]];
    BOOL downloadRetained=[NSFileManager.defaultManager fileExistsAtPath:download];
    dispatch_semaphore_signal(resume);
    check(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,@"paused Files import finishes after release");
    BOOL complete=YES;
    for(NSDictionary *entry in entries)if(![[NSString stringWithContentsOfFile:[store.dataRoot stringByAppendingPathComponent:entry[@"path"]] encoding:NSUTF8StringEncoding error:NULL] isEqual:@"CORE"])complete=NO;
    fprintf(stderr,"CONCURRENT_ASSET_MUTATIONS adopted=%d second_imported=%d cleaned=%d stage_intact=%d old_intact=%d download_retained=%d import_succeeded=%d ready=%d complete=%d\n",adopted,secondImported,cleaned,stageIntact,oldIntact,downloadRetained,imported,[store isReady],complete);
    check(!adopted&&!secondImported&&!cleaned,@"competing download adoption, Files import and cleanup all return without mutating");
    for(NSError *busyError in @[downloadError?:NSNull.null,secondImportError?:NSNull.null,cleanupError?:NSNull.null])
        check([busyError isKindOfClass:NSError.class]&&[busyError.domain isEqual:@"AgePadGameAssets"]&&busyError.code==3&&[busyError.localizedDescription containsString:@"try again"],@"competing mutation reports a clear retryable busy error");
    check(stageIntact&&oldIntact&&downloadRetained,@"busy operations preserve the active stage, installed files and verified download");
    check(imported&&!importError&&complete&&[store isReady],@"released Files import commits all 129 files without a partial ready receipt");
    check([store installDownloadedFolder:[NSURL fileURLWithPath:download] progress:nil error:&error]&&[store isReady],@"download adoption can retry after the import releases the store");
    [NSFileManager.defaultManager removeItemAtPath:home error:NULL];
}
int main(void) { @autoreleasepool {
    NSString *home=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
    AgePadGameAssetStore *store=[[AgePadGameAssetStore alloc] initWithHome:home profileURL:profile(home,@"resources/core.bin")];
    check(store.validProfile && store.requiredBytes==4,@"trusted profile parsed");
    put([store.dataRoot stringByAppendingPathComponent:@"resources/core.bin"],@"BAD!");
    put([store.dataRoot stringByAppendingPathComponent:@"modes/optional.bin"],@"OPTIONAL");
    NSError *error=nil;
    check(![store prepareExistingWithProgress:nil error:&error],@"same-size corrupt assets fail hash validation");
    check([NSFileManager.defaultManager fileExistsAtPath:[store.dataRoot stringByAppendingPathComponent:@"modes/optional.bin"]],@"no pruning before validation");
    put([store.dataRoot stringByAppendingPathComponent:@"resources/core.bin"],@"CORE");
    put([home stringByAppendingPathComponent:@"Documents/saves/keep.save"],@"saved progress");
    put([home stringByAppendingPathComponent:@"Library/Application Support/Steam/userdata/keep"],@"offline state");
    put([home stringByAppendingPathComponent:@"Library/Caches/old.tmp"],@"cache");
    put([home stringByAppendingPathComponent:@"tmp/partial"],@"partial");
    check([store prepareExistingWithProgress:nil error:&error] && [store isReady],@"verified legacy install migrates");
    check(![NSFileManager.defaultManager fileExistsAtPath:[store.dataRoot stringByAppendingPathComponent:@"modes/optional.bin"]],@"known optional asset removed");
    check(![NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"Library/Caches/old.tmp"]] &&
          ![NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"tmp/partial"]],@"stale caches removed");
    check([NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"Documents/saves/keep.save"]] &&
          [NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"Library/Application Support/Steam/userdata/keep"]],@"saves and Steam state preserved");
    NSString *source=[home stringByAppendingPathComponent:@"Source"];
    put([source stringByAppendingPathComponent:@"resources/core.bin"],@"BAD!");
    check(![store importFolder:[NSURL fileURLWithPath:source] progress:nil error:&error] && [store isReady],@"failed import keeps valid old installation");
    put([source stringByAppendingPathComponent:@"resources/core.bin"],@"CORE");
    put([store.dataRoot stringByAppendingPathComponent:@"custom.save"],@"player save");
    check([store importFolder:[NSURL fileURLWithPath:source] progress:nil error:&error] && [store isReady],@"Files folder imports successfully");
    check([NSFileManager.defaultManager fileExistsAtPath:[source stringByAppendingPathComponent:@"resources/core.bin"]],@"source folder retained");
    NSString *preserved=[home stringByAppendingPathComponent:@"Documents/PreservedGameData"];BOOL found=NO;
    for(NSString *name in [NSFileManager.defaultManager enumeratorAtPath:preserved])if([name hasSuffix:@"custom.save"])found=YES;
    check(found,@"unexpected user data preserved outside replaced assets");
    NSString *download=[home stringByAppendingPathComponent:@"Library/Application Support/AgePadDownloads/813780/content"];
    put([download stringByAppendingPathComponent:@"resources/core.bin"],@"BAD!");
    check(![store installDownloadedFolder:[NSURL fileURLWithPath:download] progress:nil error:&error]&&[store isReady],@"corrupt download keeps the installed game");
    check([error.userInfo[@"AgePadInvalidAssetPath"] isEqual:@"resources/core.bin"],@"failed hash identifies only the file needing repair");
    put([download stringByAppendingPathComponent:@"resources/core.bin"],@"CORE");
    NSDictionary *inode=[NSFileManager.defaultManager attributesOfItemAtPath:[download stringByAppendingPathComponent:@"resources/core.bin"] error:NULL];
    check([store installDownloadedFolder:[NSURL fileURLWithPath:download] progress:nil error:&error]&&[store isReady],@"verified Steam download installs");
    check([[NSFileManager.defaultManager attributesOfItemAtPath:[store.dataRoot stringByAppendingPathComponent:@"resources/core.bin"] error:NULL][NSFileSystemFileNumber] isEqual:inode[NSFileSystemFileNumber]],@"download install renames without a second asset copy");
    check(![NSFileManager.defaultManager fileExistsAtPath:download],@"download staging leaves no duplicate asset tree");
    check(![store installDownloadedFolder:[NSURL fileURLWithPath:source] progress:nil error:&error],@"download adoption rejects external folders");
    NSString *parent=[store.dataRoot stringByAppendingPathComponent:@"resources"],*moved=[home stringByAppendingPathComponent:@"MovedResources"];
    [NSFileManager.defaultManager moveItemAtPath:parent toPath:moved error:NULL];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:parent withDestinationPath:moved error:NULL];
    check(![store isReady],@"cached directory validation still rejects a symlinked ancestor");
    [NSFileManager.defaultManager removeItemAtPath:parent error:NULL];[NSFileManager.defaultManager moveItemAtPath:moved toPath:parent error:NULL];
    check([store isReady],@"readiness recovers after a directory is restored");
    NSString *support=[home stringByAppendingPathComponent:@"Library/Application Support/AgePad"];
    put([support stringByAppendingPathComponent:@"InstallStaging-interrupted/partial"],@"partial");
    put([support stringByAppendingPathComponent:@"PreviousInstall-old/custom.save"],@"old save");
    check([store prepareExistingWithProgress:nil error:&error],@"ready install cleans interrupted import leftovers");
    check(![NSFileManager.defaultManager fileExistsAtPath:[support stringByAppendingPathComponent:@"InstallStaging-interrupted"]] &&
          ![NSFileManager.defaultManager fileExistsAtPath:[support stringByAppendingPathComponent:@"PreviousInstall-old"]],@"owned stale stages and backups removed");
    NSString *backup=[support stringByAppendingPathComponent:@"PreviousInstall-recovery"];
    [NSFileManager.defaultManager moveItemAtPath:store.dataRoot toPath:backup error:NULL];
    put([support stringByAppendingPathComponent:@"InstallStaging-interrupted/partial"],@"partial");
    check([store prepareExistingWithProgress:nil error:&error] && [store isReady],@"termination between renames recovers old installation");
    NSString *core=[store.dataRoot stringByAppendingPathComponent:@"resources/core.bin"];
    [NSFileManager.defaultManager removeItemAtPath:core error:NULL];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:core withDestinationPath:[source stringByAppendingPathComponent:@"resources/core.bin"] error:NULL];
    check(![store isReady] && ![store prepareExistingWithProgress:nil error:&error],@"installed asset symlinks cannot escape validation");
    [NSFileManager.defaultManager removeItemAtPath:core error:NULL];put(core,@"CORE");
    [NSFileManager.defaultManager removeItemAtPath:[home stringByAppendingPathComponent:@"Library/Caches"] error:NULL];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:[home stringByAppendingPathComponent:@"Library/Caches"] withDestinationPath:[home stringByAppendingPathComponent:@"Library/Application Support/Steam"] error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:[support stringByAppendingPathComponent:@"InstallReceipt.json"] error:NULL];
    check(![store prepareExistingWithProgress:nil error:&error] &&
          [NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"Library/Application Support/Steam/userdata/keep"]],@"cache alias cannot delete Steam state");
    AgePadGameAssetStore *bad=[[AgePadGameAssetStore alloc] initWithHome:home profileURL:profile(home,@"../escape")];
    check(!bad.validProfile,@"manifest traversal rejected");
    concurrentMutations();
    [NSFileManager.defaultManager removeItemAtPath:home error:NULL];
    printf("%u asset install/cleanup checks passed\n",checks);
}return 0;}
