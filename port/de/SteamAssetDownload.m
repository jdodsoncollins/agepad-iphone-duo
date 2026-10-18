#import "SteamAssetDownload.h"
#import "SteamContentClient.h"
#import "SteamDownloadJournal.h"
#import "AgePadSteamRoute.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import "DataDigest.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

NSString *const AgePadDownloadChanged=@"AgePadDownloadChanged";
NSString *const AgePadDownloadSessionIdentifier=@"com.agepad.steam-assets.background.v1";
static NSString *const SDKeyService=@"AgePad Steam download depot keys";
static NSDictionary *SDKeyQuery(void){return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:SDKeyService,(__bridge id)kSecAttrAccount:@"813780"};}
static BOOL SDSaveKeys(NSDictionary *keys){
    NSMutableDictionary *encoded=[NSMutableDictionary new];for(NSString *depot in keys)encoded[depot]=[keys[depot] base64EncodedStringWithOptions:0];
    NSData *raw=[NSJSONSerialization dataWithJSONObject:encoded options:0 error:NULL];NSMutableDictionary *item=[SDKeyQuery() mutableCopy];
    item[(__bridge id)kSecValueData]=raw;item[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status=SecItemAdd((__bridge CFDictionaryRef)item,NULL);
    if(status==errSecDuplicateItem)status=SecItemUpdate((__bridge CFDictionaryRef)SDKeyQuery(),(__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:raw});return status==errSecSuccess;
}
static NSDictionary *SDLoadKeys(void){NSMutableDictionary *query=[SDKeyQuery() mutableCopy];query[(__bridge id)kSecReturnData]=@YES;CFTypeRef value=NULL;
    if(SecItemCopyMatching((__bridge CFDictionaryRef)query,&value)!=errSecSuccess||!value)return nil;
    NSData *raw=(__bridge_transfer NSData *)value;NSDictionary *encoded=[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
    if(![encoded isKindOfClass:NSDictionary.class])return nil;
    NSMutableDictionary *keys=[NSMutableDictionary new];for(NSString *depot in encoded){if(![encoded[depot] isKindOfClass:NSString.class])return nil;NSData *key=[[NSData alloc] initWithBase64EncodedString:encoded[depot] options:0];if(key.length!=32)return nil;keys[depot]=key;}return keys;
}

@interface AgePadSteamAssetDownload ()
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSOperationQueue *queue;
@property(nonatomic,strong) AgePadGameAssetStore *store;
@property(nonatomic,strong) AgePadSteamContentClient *preparer;
@property(nonatomic,strong) NSDictionary *profile,*keys;
@property(nonatomic,copy) NSString *profileHash,*root,*stage,*journalPath,*progressPath;
@property(nonatomic,strong) NSMutableDictionary *journal;
@property(nonatomic,strong) NSMutableSet<NSNumber *> *completed;
@property(nonatomic) uint64_t completedBytes;
@property(nonatomic) NSUInteger nextJobIndex;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSURLSessionDownloadTask *> *active;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSNumber *> *received;
@property(nonatomic,copy) void (^backgroundCompletion)(void);
@property(atomic,readwrite,copy) NSDictionary *snapshot;
@property(atomic) BOOL foreground;
@property(nonatomic) BOOL restored,finalizing;
@property(nonatomic) NSTimeInterval publishedAt;
@property(nonatomic,copy) NSString *publishedPhase;
@end

@implementation AgePadSteamAssetDownload
+ (instancetype)shared{static AgePadSteamAssetDownload *v;static dispatch_once_t once;dispatch_once(&once,^{v=[self new];});return v;}
- (instancetype)init{
    if(!(self=[super init]))return nil;
    _queue=[NSOperationQueue new];_queue.maxConcurrentOperationCount=1;_queue.qualityOfService=NSQualityOfServiceUtility;
    _active=[NSMutableDictionary new];_received=[NSMutableDictionary new];_completed=[NSMutableSet new];_journal=[NSMutableDictionary new];_snapshot=@{@"phase":@"idle",@"message":@"Download the compact game pack from Steam."};
    _root=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AgePadDownloads/813780"];
    _stage=[_root stringByAppendingPathComponent:@"content"];_journalPath=[_root stringByAppendingPathComponent:@"Download.json"];
    _progressPath=[_root stringByAppendingPathComponent:@"Completed.bin"];
    NSURLSessionConfiguration *configuration=[NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:AgePadDownloadSessionIdentifier];
    configuration.sessionSendsLaunchEvents=YES;configuration.discretionary=NO;configuration.waitsForConnectivity=YES;
    configuration.allowsCellularAccess=NO;configuration.allowsExpensiveNetworkAccess=NO;configuration.allowsConstrainedNetworkAccess=NO;
    configuration.HTTPMaximumConnectionsPerHost=6;configuration.timeoutIntervalForResource=7*24*60*60;
    _session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_queue];
    _foreground=UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enteredBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    // The signed profile is also available before a foreground scene exists.
    NSData *raw=[NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"GameDataProfile" withExtension:@"json"]];
    _profile=raw?[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL]:nil;_profileHash=raw?AgePadSHA256(raw):@"";
    [self.queue addOperationWithBlock:^{[self restore];}];return self;
}
- (void)becameActive{self.foreground=YES;[self.queue addOperationWithBlock:^{[self fill];}];}
- (void)enteredBackground{self.foreground=NO;}
- (BOOL)busy{NSString *phase=self.snapshot[@"phase"];return [@[@"preparing",@"downloading",@"verifying",@"paused",@"error"] containsObject:phase];}
- (void)configureStore:(AgePadGameAssetStore *)store{[self.queue addOperationWithBlock:^{
    self.store=store;
    if((self.journal[@"jobs"]||self.preparer)&&!getenv("AGEPAD_DOWNLOAD_CHECK")&&[store isReady]){
        self.preparer.cancelled=YES;[self.preparer close];self.preparer=nil;
        for(NSURLSessionTask *task in self.active.allValues)[task cancel];
        [self.active removeAllObjects];[self.completed removeAllObjects];[self.received removeAllObjects];
        [NSFileManager.defaultManager removeItemAtPath:self.root error:NULL];
        SecItemDelete((__bridge CFDictionaryRef)SDKeyQuery());self.keys=nil;
        self.journal=[@{@"phase":@"ready"} mutableCopy];[self rebuildProgress];[self publish:@"Installed · ready to play"];
    }
    [self fill];
}];}
- (void)rebuildProgress{
    self.completedBytes=0;self.nextJobIndex=0;NSArray *jobs=self.journal[@"jobs"];
    for(NSNumber *index in self.completed)if(index.unsignedIntegerValue<jobs.count)self.completedBytes+=[jobs[index.unsignedIntegerValue][@"compressed"] unsignedLongLongValue];
}
- (void)publish:(NSString *)message{
    uint64_t partial=0,total=[self.journal[@"total"] unsignedLongLongValue];
    for(NSNumber *i in self.received)partial+=[self.received[i] unsignedLongLongValue];
    NSString *phase=self.journal[@"phase"]?:@"idle";uint64_t have=MIN(total,self.completedBytes+partial);
    NSDictionary *value=@{@"phase":phase,@"message":message?:self.journal[@"message"]?:@"Download the compact game pack from Steam.",@"received":@(have),@"total":@(total),@"progress":total?@((double)have/total):@0};
    self.snapshot=value;
    NSTimeInterval now=NSDate.date.timeIntervalSinceReferenceDate;
    if([phase isEqual:self.publishedPhase]&&now-self.publishedAt<.25)return;
    self.publishedAt=now;self.publishedPhase=phase;
    dispatch_async(dispatch_get_main_queue(),^{[NSNotificationCenter.defaultCenter postNotificationName:AgePadDownloadChanged object:self];});
}
- (BOOL)save{
    // The large immutable job plan is never rewritten for each 1 MB chunk.
    // Completion records append four bytes after the corresponding data fsync.
    self.journal[@"completed"]=@[];
    NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
    if(![fm createDirectoryAtPath:self.root withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error])return NO;
    NSURL *folder=[NSURL fileURLWithPath:self.root];[folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
    NSData *data=[NSJSONSerialization dataWithJSONObject:self.journal options:0 error:&error];return data&&[data writeToFile:self.journalPath options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&error];
}
- (void)fail:(NSString *)message{
    fprintf(stderr,"AGEPAD_CONTENT_ERROR %s\n",message.UTF8String);
    self.journal[@"phase"]=@"error";self.journal[@"message"]=message;
    for(NSURLSessionDownloadTask *task in self.active.allValues)[task suspend];[self save];[self publish:message];
}
- (BOOL)validRestoredPlan{return AgePadValidDownloadJournal(self.journal,self.profile,self.profileHash,self.keys);}
- (void)restore{
    NSData *raw=[NSData dataWithContentsOfFile:self.journalPath options:NSDataReadingMappedIfSafe error:NULL];
    id j=raw.length&&raw.length<(64<<20)?[NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingMutableContainers error:NULL]:nil;
    if([j isKindOfClass:NSDictionary.class]){self.journal=j;self.completed=[NSMutableSet setWithArray:[j[@"completed"] isKindOfClass:NSArray.class]?j[@"completed"]:@[]];self.keys=SDLoadKeys();
        NSData *bits=[NSData dataWithContentsOfFile:self.progressPath];
        [self.completed unionSet:AgePadCompletedRecords(bits,[j[@"jobs"] count])];
        // Drop a torn append before adding new records after relaunch.
        int fd=open(self.progressPath.fileSystemRepresentation,O_WRONLY|O_NOFOLLOW);if(fd>=0){ftruncate(fd,(off_t)(bits.length/4*4));close(fd);}
        if(![j[@"phase"] isEqual:@"preparing"]&&![self validRestoredPlan]){self.journal=[@{@"phase":@"error",@"message":@"The saved download can't be resumed. Cancel it, then download again."} mutableCopy];[self.completed removeAllObjects];self.keys=nil;[self publish:nil];}
        else if([j[@"phase"] isEqual:@"preparing"]){j[@"phase"]=@"paused";j[@"message"]=@"Open AgePad and resume to authorize the download.";}
        // A completed bit is useful only while its actual staging file exists.
        NSMutableSet *missing=[NSMutableSet new];
        for(NSNumber *index in self.completed){NSArray *jobs=self.journal[@"jobs"];if(index.unsignedIntegerValue>=jobs.count)continue;NSDictionary *job=jobs[index.unsignedIntegerValue];struct stat st;
            NSString *path=[self.stage stringByAppendingPathComponent:job[@"path"]];
            if(lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||(uint64_t)st.st_size<[job[@"offset"] unsignedLongLongValue]+[job[@"length"] unsignedLongLongValue])[missing addObject:index];}
        [self.completed minusSet:missing];
    }
    [self rebuildProgress];
    [self.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks){[self.queue addOperationWithBlock:^{
        for(NSURLSessionDownloadTask *task in tasks){NSNumber *index=[self indexForTask:task];if(!index||[self.completed containsObject:index]){[task cancel];continue;}self.active[index]=task;}
        self.restored=YES;[self publish:nil];[self fill];
    }];}];
}
- (NSNumber *)indexForTask:(NSURLSessionTask *)task{
    NSArray *parts=[task.taskDescription componentsSeparatedByString:@":"];if(parts.count!=2||![parts[0] isEqual:self.journal[@"generation"]])return nil;
    NSScanner *scan=[NSScanner scannerWithString:parts[1]];unsigned long long i=0;if(![scan scanUnsignedLongLong:&i]||!scan.isAtEnd||i>=[self.journal[@"jobs"] count])return nil;return @(i);
}
- (void)start{[self.queue addOperationWithBlock:^{[self prepare];}];}
- (void)prepare{
    if(!self.foreground){[self fail:@"Open AgePad to authorize the Steam download."];return;}
    if(self.preparer||self.finalizing)return;
    BOOL check=getenv("AGEPAD_DOWNLOAD_CHECK")&&[self.store isReady];
    if([self.store isReady]&&!check){self.journal[@"phase"]=@"ready";[self publish:@"Installed · ready to play"];return;}
    // Space includes unpacked assets plus a bounded batch of encrypted chunks.
    NSDictionary *disk=[NSFileManager.defaultManager attributesOfFileSystemForPath:NSHomeDirectory() error:NULL];
    if([disk[NSFileSystemFreeSize] unsignedLongLongValue]<(check?32ULL<<20:self.store.requiredBytes+(512ULL<<20))){[self fail:@"Free at least 15.2 GB on this device, then retry the compact download."];return;}
    self.journal[@"phase"]=@"preparing";self.journal[@"profile"]=self.profileHash;[self save];[self publish:@"Authorizing your Steam download…"];
    self.preparer=[AgePadSteamContentClient new];AgePadSteamContentClient *client=self.preparer;
    // Keychain access and the authenticated CM connection are confined to this
    // worker. No credential is added to the download journal or a URL.
    [AgePadSteamRoute prepareContentDownload:client profile:self.profile completion:^(NSDictionary *plan,NSError *error){[self.queue addOperationWithBlock:^{
        if(self.preparer!=client)return;[client close];self.preparer=nil;
        if(!plan){[self fail:error.localizedDescription?:@"Steam couldn't prepare the download. Retry or import from Files."];return;}
        NSMutableArray *jobs=[NSMutableArray new];uint64_t total=0;
        for(NSDictionary *file in plan[@"files"]){for(NSDictionary *chunk in file[@"chunks"]){NSMutableDictionary *job=[chunk mutableCopy];job[@"path"]=file[@"path"];[jobs addObject:job];total+=[chunk[@"compressed"] unsignedLongLongValue];}}
        fprintf(stderr,"AGEPAD_CONTENT_PLAN files=%lu chunks=%lu transfer_bytes=%llu\n",(unsigned long)[plan[@"files"] count],(unsigned long)jobs.count,total);
        // Hardware smoke test: genuine owned manifests and the same background
        // transfer/decode/journal path, capped at 4 chunks. Never adopts data,
        // sets readiness, or removes an existing install. Not enabled in bundle.
        if(check){[jobs sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"compressed"] compare:a[@"compressed"]];}];while(jobs.count>4)[jobs removeLastObject];total=0;for(NSDictionary *j in jobs)total+=[j[@"compressed"] unsignedLongLongValue];self.journal[@"diagnostic"]=@YES;}
        BOOL same=[self.journal[@"jobs"] isEqual:jobs];
        // Renewed authorization means new URLs. Retain verified chunks, but
        // replace suspended daemon tasks so they don't reuse expired tokens.
        for(NSURLSessionDownloadTask *task in self.active.allValues)[task cancel];
        [self.active removeAllObjects];[self.received removeAllObjects];
        if(!same){[self.completed removeAllObjects];[NSFileManager.defaultManager removeItemAtPath:self.stage error:NULL];unlink(self.progressPath.fileSystemRepresentation);}
        self.journal[@"generation"]=NSUUID.UUID.UUIDString;
        if(!SDSaveKeys(plan[@"keys"])){[self fail:@"Couldn't save download keys securely. Unlock the device and retry."];return;}
        self.keys=plan[@"keys"];self.journal[@"jobs"]=jobs;self.journal[@"authorizations"]=plan[@"authorizations"];self.journal[@"total"]=@(total);self.journal[@"phase"]=@"downloading";self.journal[@"message"]=@"Downloading from Steam · Wi-Fi";
        [self rebuildProgress];
        // Empty profile files have no chunks, but still belong in the install.
        for(NSDictionary *file in plan[@"files"])if(![file[@"bytes"] unsignedLongLongValue]){
            NSString *path=[self.stage stringByAppendingPathComponent:file[@"path"]];
            [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:NULL];
            int fd=open(path.fileSystemRepresentation,O_CREAT|O_WRONLY|O_NOFOLLOW,0600);if(fd<0){[self fail:@"Couldn't create the download folder. Check free space and retry."];return;}close(fd);
        }
        if(![self save]){[self fail:@"Couldn't save download progress. Check free space and retry."];return;}[self fill];
    }];} progress:^(NSString *message){[self.queue addOperationWithBlock:^{[self publish:message];}];}];
}
- (void)fill{
    if(!self.restored)return;NSString *phase=self.journal[@"phase"];
    if(![@[@"downloading",@"verifying"] containsObject:phase])return;
    NSArray *jobs=self.journal[@"jobs"];if(!jobs.count)return;
    if(self.completed.count==jobs.count){[self finish];return;}
    // Keep multiple HTTPS tasks with the system, including while suspended.
    // A bounded batch avoids staging gigabytes of encrypted duplicates.
    for(;self.nextJobIndex<jobs.count&&self.active.count<96;self.nextJobIndex++){
        NSUInteger i=self.nextJobIndex;
        NSNumber *index=@(i);if([self.completed containsObject:index]||self.active[index])continue;NSDictionary *job=jobs[i];NSString *depot=[job[@"depot"] stringValue];NSDictionary *auth=self.journal[@"authorizations"][depot];
        NSTimeInterval expiry=[auth[@"expires"] doubleValue];if(expiry>0&&expiry<NSDate.date.timeIntervalSince1970+60){[self fail:@"Steam download authorization expired. Tap Resume while AgePad is open to renew it."];return;}
        NSString *url=[NSString stringWithFormat:@"https://%@/depot/%@/chunk/%@%@",auth[@"host"],depot,job[@"sha"],auth[@"suffix"]?:@""];
        NSURL *address=[NSURL URLWithString:url];
        if(!address||!AgePadSteamContentHost(address.host)||address.user||address.password){[self fail:@"The saved download address is invalid. Cancel and restart the download."];return;}
        NSURLSessionDownloadTask *task=[self.session downloadTaskWithURL:address];task.taskDescription=[NSString stringWithFormat:@"%@:%lu",self.journal[@"generation"],(unsigned long)i];
        if(getenv("AGEPAD_DOWNLOAD_CHECK"))task.earliestBeginDate=[NSDate dateWithTimeIntervalSinceNow:20];
        task.countOfBytesClientExpectsToReceive=[job[@"compressed"] longLongValue];self.active[index]=task;[task resume];
    }
    [self publish:nil];
}
- (void)pause{[self.queue addOperationWithBlock:^{self.preparer.cancelled=YES;[self.preparer close];self.preparer=nil;self.journal[@"phase"]=@"paused";self.journal[@"message"]=@"Download paused · progress saved";for(NSURLSessionTask *task in self.active.allValues)[task suspend];[self save];[self publish:nil];}];}
- (void)resume{[self.queue addOperationWithBlock:^{
    if(!self.journal[@"jobs"]||[self.journal[@"phase"] isEqual:@"error"]){[self prepare];return;}
    self.journal[@"phase"]=@"downloading";self.journal[@"message"]=@"Downloading from Steam · Wi-Fi";
    // Expired CDN tokens require a new foreground authorization, preserving jobs.
    for(NSDictionary *auth in [self.journal[@"authorizations"] allValues])if([auth[@"expires"] doubleValue]>0&&[auth[@"expires"] doubleValue]<NSDate.date.timeIntervalSince1970+60){[self prepare];return;}
    for(NSURLSessionTask *task in self.active.allValues)[task resume];[self save];[self fill];
}];}
- (void)cancel{[self.queue addOperationWithBlock:^{self.preparer.cancelled=YES;[self.preparer close];self.preparer=nil;self.journal=[NSMutableDictionary new];
    for(NSURLSessionTask *task in self.active.allValues)[task cancel];[self.active removeAllObjects];[self.received removeAllObjects];[self.completed removeAllObjects];
    [self rebuildProgress];
    [NSFileManager.defaultManager removeItemAtPath:self.root error:NULL];SecItemDelete((__bridge CFDictionaryRef)SDKeyQuery());self.keys=nil;[self publish:@"Download cancelled. Your installed game and saves are kept."];
}];}
- (void)finish{
    if(self.finalizing)return;self.journal[@"phase"]=@"verifying";
    if(getenv("AGEPAD_DOWNLOAD_CHECK")&&[self.journal[@"diagnostic"] boolValue]){
        fprintf(stderr,"AGEPAD_CONTENT_CHECK verified_chunks=%lu bytes=%llu background_session=1 install_preserved=1\n",(unsigned long)self.completed.count,[self.journal[@"total"] unsignedLongLongValue]);
        SecItemDelete((__bridge CFDictionaryRef)SDKeyQuery());[NSFileManager.defaultManager removeItemAtPath:self.root error:NULL];self.keys=nil;
        [self.active removeAllObjects];[self.completed removeAllObjects];[self.received removeAllObjects];
        self.journal=[NSMutableDictionary new];[self rebuildProgress];[self publish:@"Steam download check complete · installed game preserved"];return;
    }
    if(!self.foreground||!self.store){self.journal[@"message"]=@"Download complete · open AgePad to verify and install";[self save];[self publish:nil];return;}
    self.finalizing=YES;[self save];[self publish:@"Verifying downloaded game files…"];
    NSError *error=nil;BOOL ok=[self.store installDownloadedFolder:[NSURL fileURLWithPath:self.stage] progress:^(NSString *message){[self publish:message];} error:&error];self.finalizing=NO;
    if(!ok){
        NSString *bad=error.userInfo[@"AgePadInvalidAssetPath"];
        if(bad){NSArray *jobs=self.journal[@"jobs"];for(NSUInteger i=0;i<jobs.count;i++)if([jobs[i][@"path"] isEqual:bad])[self.completed removeObject:@(i)];
            [self rebuildProgress];
            NSMutableData *records=[NSMutableData new];for(NSNumber *index in self.completed){uint32_t v=CFSwapInt32HostToLittle(index.unsignedIntValue);[records appendBytes:&v length:4];}
            [records writeToFile:self.progressPath options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:NULL];
            [NSFileManager.defaultManager removeItemAtPath:[self.stage stringByAppendingPathComponent:bad] error:NULL];
        }
        [self fail:error.localizedDescription?:@"The downloaded game didn't pass verification. Retry or import from Files."];return;
    }
    SecItemDelete((__bridge CFDictionaryRef)SDKeyQuery());[NSFileManager.defaultManager removeItemAtPath:self.root error:NULL];self.keys=nil;
    [self.active removeAllObjects];[self.completed removeAllObjects];[self.received removeAllObjects];
    self.journal=[@{@"phase":@"ready",@"message":@"Installed · ready to play"} mutableCopy];[self rebuildProgress];[self publish:nil];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)expected{
    NSNumber *index=[self indexForTask:task];if(!index||[self.completed containsObject:index])return;NSDictionary *job=self.journal[@"jobs"][index.unsignedIntegerValue];self.received[index]=@(MIN(MAX(0,totalBytesWritten),[job[@"compressed"] longLongValue]));[self publish:nil];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location{
    NSNumber *index=[self indexForTask:task];if(!index||[self.completed containsObject:index])return;
    NSDictionary *job=self.journal[@"jobs"][index.unsignedIntegerValue];NSInteger status=[(NSHTTPURLResponse *)task.response statusCode];
    if(status!=200){[self fail:[NSString stringWithFormat:@"Steam download stopped (HTTP %ld). Tap Resume to renew access and keep your progress.",(long)status]];return;}
    NSData *encrypted=[NSData dataWithContentsOfURL:location options:NSDataReadingMappedIfSafe error:NULL];NSError *error=nil;
    NSData *clear=encrypted?AgePadSteamDecodeChunk(encrypted,self.keys[[job[@"depot"] stringValue]],job,&error):nil;
    if(!clear){[self fail:error.localizedDescription?:@"Couldn't read the downloaded chunk. Retry to resume."];return;}
    NSString *path=[self.stage stringByAppendingPathComponent:job[@"path"]];
    if(!AgePadDownloadPathInside(NSHomeDirectory(),self.stage)||!AgePadDownloadPathInside(self.stage,path)){[self fail:@"The download staging folder is invalid. Cancel and restart the download."];return;}
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error];
    int fd=open(path.fileSystemRepresentation,O_CREAT|O_WRONLY|O_NOFOLLOW,0600);BOOL ok=fd>=0;
    for(NSUInteger at=0;ok&&at<clear.length;){ssize_t n=pwrite(fd,(const uint8_t *)clear.bytes+at,clear.length-at,(off_t)[job[@"offset"] unsignedLongLongValue]+at);if(n<=0)ok=NO;else at+=(NSUInteger)n;}
    if(fd>=0){if(fsync(fd))ok=NO;close(fd);}if(!ok){[self fail:@"Couldn't save downloaded game files. Check free space, then resume."];return;}
    [self.received removeObjectForKey:index];
    if(getenv("AGEPAD_DOWNLOAD_CHECK"))fprintf(stderr,"AGEPAD_CONTENT_CHECK_CHUNK index=%lu bytes=%lu foreground=%d verified=1\n",(unsigned long)index.unsignedIntegerValue,(unsigned long)clear.length,self.foreground);
    uint32_t record=CFSwapInt32HostToLittle(index.unsignedIntValue);int progressFD=open(self.progressPath.fileSystemRepresentation,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600);
    BOOL saved=progressFD>=0&&write(progressFD,&record,sizeof record)==sizeof record&&fsync(progressFD)==0;if(progressFD>=0)close(progressFD);
    if(!saved){[self fail:@"Couldn't save download progress. Check free space, then resume."];return;}
    [self.completed addObject:index];self.completedBytes+=[job[@"compressed"] unsignedLongLongValue];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error{
    NSNumber *index=[self indexForTask:task];if(!index)return;[self.active removeObjectForKey:index];[self.received removeObjectForKey:index];
    // Retry holes left by cancelled or failed tasks, including while paused.
    if(![self.completed containsObject:index])self.nextJobIndex=MIN(self.nextJobIndex,index.unsignedIntegerValue);
    if(error&&error.code!=NSURLErrorCancelled&&![self.journal[@"phase"] isEqual:@"paused"]){[self fail:@"The connection was interrupted. Tap Resume to continue from saved progress."];return;}
    [self fill];
}
- (void)handleBackgroundSession:(NSString *)identifier completion:(void (^)(void))completion{
    if(![identifier isEqual:AgePadDownloadSessionIdentifier]){completion();return;}self.backgroundCompletion=completion;
}
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session{
    dispatch_async(dispatch_get_main_queue(),^{void (^done)(void)=self.backgroundCompletion;self.backgroundCompletion=nil;if(done)done();});
}
@end
