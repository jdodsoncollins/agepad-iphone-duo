#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import "../port/steam-engine/SteamContentClient.m"
#import "steam_content_fixtures.h"

static NSString *testHome;
static NSString *SDTestHome(void){return testHome;}
static NSData *testKey;
static OSStatus SDTestCopy(CFDictionaryRef query,CFTypeRef *value){
    NSData *raw=[NSJSONSerialization dataWithJSONObject:@{@"1":[testKey base64EncodedStringWithOptions:0]} options:0 error:NULL];
    *value=CFBridgingRetain(raw);return errSecSuccess;
}
static OSStatus SDTestAdd(CFDictionaryRef query,CFTypeRef *value){return errSecSuccess;}
static OSStatus SDTestUpdate(CFDictionaryRef query,CFDictionaryRef values){return errSecSuccess;}
static OSStatus SDTestDelete(CFDictionaryRef query){return errSecSuccess;}
#define NSHomeDirectory SDTestHome
#define SecItemCopyMatching SDTestCopy
#define SecItemAdd SDTestAdd
#define SecItemUpdate SDTestUpdate
#define SecItemDelete SDTestDelete
#import "../port/de/SteamAssetDownload.m"
#undef NSHomeDirectory
#undef SecItemCopyMatching
#undef SecItemAdd
#undef SecItemUpdate
#undef SecItemDelete

NSString *const UIApplicationDidBecomeActiveNotification=@"TestActive";
NSString *const UIApplicationDidEnterBackgroundNotification=@"TestBackground";
@implementation UIApplication
+ (UIApplication *)sharedApplication{return nil;}
- (UIApplicationState)applicationState{return UIApplicationStateActive;}
@end

static NSDictionary *nextPlan;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation AgePadSteamRoute
+ (void)prepareContentDownload:(AgePadSteamContentClient *)client profile:(NSDictionary *)profile completion:(void (^)(NSDictionary *,NSError *))completion progress:(void (^)(NSString *))progress{completion(nextPlan,nil);}
@end
#pragma clang diagnostic pop

@interface LocalTask : NSObject
@property(nonatomic,copy) NSString *taskDescription;
@property(nonatomic,strong) NSURLResponse *response;
@property(nonatomic,strong) NSDate *earliestBeginDate;
@property(nonatomic) int64_t countOfBytesClientExpectsToReceive;
@property(nonatomic) NSUInteger resumes,suspends,cancels;
@end
@implementation LocalTask
- (void)resume{self.resumes++;}
- (void)suspend{self.suspends++;}
- (void)cancel{self.cancels++;}
@end

@interface LocalSession : NSObject
@property(nonatomic,strong) NSMutableArray<LocalTask *> *created;
@property(nonatomic,strong) NSArray *restoredTasks;
@end
@implementation LocalSession
- (instancetype)init{if((self=[super init]))_created=[NSMutableArray new];return self;}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url{LocalTask *task=[LocalTask new];[self.created addObject:task];return (id)task;}
- (void)getAllTasksWithCompletionHandler:(void (^)(NSArray *))completion{completion(self.restoredTasks?:@[]);}
@end

@interface LocalStore : NSObject
@property(nonatomic) BOOL ready,failVerification;
@property(nonatomic,copy) NSString *badPath;
@end
@implementation LocalStore
- (BOOL)isReady{return self.ready;}
- (unsigned long long)requiredBytes{return 1024;}
- (BOOL)installDownloadedFolder:(NSURL *)folder progress:(void (^)(NSString *))progress error:(NSError **)error{
    if(!self.failVerification)return YES;
    *error=[NSError errorWithDomain:@"Fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Fixture verification failure",@"AgePadInvalidAssetPath":self.badPath}];return NO;
}
@end

@interface CountedJobs : NSArray
@property(nonatomic,strong) NSArray *values;
@property(nonatomic) NSUInteger reads;
@end
@implementation CountedJobs
- (NSUInteger)count{return self.values.count;}
- (id)objectAtIndex:(NSUInteger)index{self.reads++;return self.values[index];}
@end

@interface CountedCompleted : NSMutableSet
@property(nonatomic,strong) NSMutableSet *values;
@property(nonatomic) NSUInteger lookups;
@end
@implementation CountedCompleted
- (instancetype)init{if((self=[super init]))_values=[NSMutableSet new];return self;}
- (NSUInteger)count{return self.values.count;}
- (id)member:(id)value{return [self.values member:value];}
- (BOOL)containsObject:(id)value{self.lookups++;return [self.values containsObject:value];}
- (NSEnumerator *)objectEnumerator{return self.values.objectEnumerator;}
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])objects count:(NSUInteger)count{return [self.values countByEnumeratingWithState:state objects:objects count:count];}
- (void)addObject:(id)value{[self.values addObject:value];}
- (void)removeObject:(id)value{[self.values removeObject:value];}
@end

static unsigned checks;
static void check(BOOL ok,NSString *label){if(!ok){fprintf(stderr,"FAIL %s\n",label.UTF8String);exit(1);}checks++;}
static NSDictionary *chunk(NSUInteger index){return @{@"path":[NSString stringWithFormat:@"resources/%lu.bin",(unsigned long)index],@"offset":@0,@"length":@16,@"compressed":@(64+index),@"depot":@1,@"sha":@"0000000000000000000000000000000000000000",@"checksum":@0};}
static NSMutableArray *jobs(NSUInteger count){NSMutableArray *out=[NSMutableArray new];for(NSUInteger i=0;i<count;i++)[out addObject:chunk(i)];return out;}
static NSDictionary *auth(void){return @{@"1":@{@"host":@"cache.steamcontent.com",@"suffix":@"",@"expires":@(NSDate.date.timeIntervalSince1970+3600)}};}
static AgePadSteamAssetDownload *download(NSArray *plan){
    AgePadSteamAssetDownload *d=class_createInstance(AgePadSteamAssetDownload.class,0);
    d.queue=[NSOperationQueue new];d.queue.maxConcurrentOperationCount=1;
    d.session=(id)[LocalSession new];d.active=[NSMutableDictionary new];d.received=[NSMutableDictionary new];d.completed=[NSMutableSet new];
    d.root=[testHome stringByAppendingPathComponent:NSUUID.UUID.UUIDString];d.stage=[d.root stringByAppendingPathComponent:@"content"];
    d.journalPath=[d.root stringByAppendingPathComponent:@"Download.json"];d.progressPath=[d.root stringByAppendingPathComponent:@"Completed.bin"];
    uint64_t total=0;NSMutableArray *entries=[NSMutableArray new];for(NSDictionary *job in plan){total+=[job[@"compressed"] unsignedLongLongValue];[entries addObject:@{@"path":job[@"path"],@"bytes":job[@"length"]}];}
    d.profile=@{@"entries":entries};d.profileHash=@"fixture";d.keys=@{@"1":testKey};
    d.journal=[@{@"jobs":plan,@"generation":@"fixture",@"phase":@"downloading",@"authorizations":auth(),@"total":@(total),@"profile":d.profileHash,@"completed":@[]} mutableCopy];
    d.snapshot=@{};d.publishedAt=NSDate.date.timeIntervalSinceReferenceDate;d.publishedPhase=@"downloading";d.restored=YES;d.foreground=YES;return d;
}
static void drain(AgePadSteamAssetDownload *d){[d.queue waitUntilAllOperationsAreFinished];}
static void complete(AgePadSteamAssetDownload *d,NSNumber *index,NSError *error){[d URLSession:d.session task:d.active[index] didCompleteWithError:error];}
static void setPlan(AgePadSteamAssetDownload *d,NSArray *plan){NSMutableArray *files=[NSMutableArray new];for(NSDictionary *job in plan)[files addObject:@{@"path":job[@"path"],@"bytes":job[@"length"],@"chunks":@[job]}];nextPlan=@{@"files":files,@"keys":@{@"1":testKey},@"authorizations":auth()};[d prepare];drain(d);}
static AgePadSteamAssetDownload *chunkDownload(NSURL **location){
    NSData *plain=[@"download fixture" dataUsingEncoding:NSUTF8StringEncoding],*cipher=encryptFixture(storedZip(plain),testKey);uint8_t hash[20];CC_SHA1(plain.bytes,(CC_LONG)plain.length,hash);
    NSMutableDictionary *job=[chunk(0) mutableCopy];job[@"sha"]=SCHex([NSData dataWithBytes:hash length:20]);job[@"checksum"]=@((uint32_t)adler32(0,plain.bytes,(uInt)plain.length));job[@"length"]=@(plain.length);job[@"compressed"]=@(cipher.length);
    AgePadSteamAssetDownload *d=download(@[job]);[d save];[d fill];LocalTask *task=(id)d.active[@0];task.response=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://cache.steamcontent.com"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    NSString *path=[d.root stringByAppendingPathComponent:@"encrypted"];[cipher writeToFile:path atomically:YES];*location=[NSURL fileURLWithPath:path];return d;
}

int main(int argc,char **argv){@autoreleasepool{
    testHome=@(argv[1]);testKey=[NSMutableData dataWithLength:32];
    AgePadSteamAssetDownload *d=download(jobs(120));[d fill];
    check(d.active.count==96,@"daemon batch is bounded at 96");
    LocalTask *first=(id)d.active[@0];check([first.taskDescription isEqual:@"fixture:0"],@"first task has a generation and ordered index");
    [d pause];drain(d);check([d.snapshot[@"phase"] isEqual:@"paused"]&&first.suspends==1,@"pause suspends the active batch");
    complete(d,@5,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
    check(!d.active[@5]&&d.active.count==95,@"cancellation while paused leaves a saved retry position");
    [d resume];drain(d);check(first.resumes==2&&d.active.count==96,@"resume retains active tasks without duplicates");
    check(d.active[@5],@"resume fills the hole left while paused");
    complete(d,@0,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
    check(d.active.count==96&&d.active[@0]!=(id)first,@"cancelled incomplete slot is retried before later chunks");
    LocalTask *retry=(id)d.active[@0];complete(d,@0,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]);
    check([d.snapshot[@"phase"] isEqual:@"error"]&&!d.active[@0],@"connection failure preserves a retryable hole");
    LocalStore *store=[LocalStore new];d.store=(id)store;setPlan(d,d.journal[@"jobs"]);
    check(d.active[@0]&&d.active.count==96,@"reauthorization schedules the failed early chunk");
    NSDictionary *before=d.snapshot;[d URLSession:d.session downloadTask:(id)first didWriteData:50 totalBytesWritten:50 totalBytesExpectedToWrite:64];
    [d URLSession:d.session task:(id)retry didCompleteWithError:nil];
    check(d.snapshot==before&&d.active[@0],@"old-generation progress and completion cannot change the new plan");

    NSURL *location=nil;d=chunkDownload(&location);LocalTask *task=(id)d.active[@0];
    [d URLSession:d.session downloadTask:(id)task didWriteData:20 totalBytesWritten:20 totalBytesExpectedToWrite:80];
    check([d.snapshot[@"received"] unsignedLongLongValue]==20,@"live progress publishes immediately");
    [d URLSession:d.session downloadTask:(id)task didFinishDownloadingToURL:location];[d publish:nil];
    uint64_t compressed=[d.journal[@"total"] unsignedLongLongValue];
    check(d.completed.count==1&&[d.snapshot[@"received"] unsignedLongLongValue]==compressed,@"verified chunk advances completed bytes");
    check([NSData dataWithContentsOfFile:d.progressPath].length==4,@"completion follows the real decoded data and ledger writes");
    [d URLSession:d.session downloadTask:(id)task didFinishDownloadingToURL:location];[d publish:nil];
    check(d.completed.count==1&&[d.snapshot[@"received"] unsignedLongLongValue]==compressed,@"duplicate completion counts bytes once");
    check([NSData dataWithContentsOfFile:d.progressPath].length==4,@"duplicate completion does not append a second ledger record");
    check([[NSData dataWithContentsOfFile:[d.stage stringByAppendingPathComponent:@"resources/0.bin"]] isEqual:[@"download fixture" dataUsingEncoding:NSUTF8StringEncoding]],@"production decoder and delegate write the exact file");
    d.foreground=NO;complete(d,@0,nil);check([d.snapshot[@"phase"] isEqual:@"verifying"],@"background completion defers installation");
    d.foreground=YES;store=[LocalStore new];store.failVerification=YES;store.badPath=@"resources/0.bin";d.store=(id)store;[d finish];
    check(!d.completed.count&&[d.snapshot[@"received"] unsignedLongLongValue]==0,@"failed-file repair removes completed bytes");
    setPlan(d,d.journal[@"jobs"]);check(d.active[@0],@"repair requeues the invalid file after reauthorization");

    d=chunkDownload(&location);[NSFileManager.defaultManager createDirectoryAtPath:d.progressPath withIntermediateDirectories:YES attributes:nil error:NULL];task=(id)d.active[@0];
    [d URLSession:d.session downloadTask:(id)task didFinishDownloadingToURL:location];
    check(!d.completed.count&&[d.snapshot[@"received"] unsignedLongLongValue]==0&&[d.snapshot[@"phase"] isEqual:@"error"],@"ledger failure never counts an undurable completion");

    d=chunkDownload(&location);NSURLResponse *response=((LocalTask *)(id)d.active[@0]).response;
    NSDictionary *one=d.journal[@"jobs"][0];NSMutableDictionary *two=[one mutableCopy];two[@"path"]=@"resources/second.bin";
    setPlan(d,@[one,two]);task=(id)d.active[@0];task.response=response;
    [d URLSession:d.session downloadTask:(id)task didFinishDownloadingToURL:location];[d publish:nil];
    [d URLSession:d.session downloadTask:(id)task didWriteData:10 totalBytesWritten:10 totalBytesExpectedToWrite:64];
    check([d.snapshot[@"received"] unsignedLongLongValue]==[one[@"compressed"] unsignedLongLongValue],@"late progress cannot double-count a completed chunk");
    LocalTask *second=(id)d.active[@1];
    [d URLSession:d.session downloadTask:(id)second didWriteData:100 totalBytesWritten:1000 totalBytesExpectedToWrite:64];
    check([d.snapshot[@"received"] unsignedLongLongValue]==2*[one[@"compressed"] unsignedLongLongValue],@"partial progress stays bounded by the chunk's compressed length");
    [d URLSession:d.session downloadTask:(id)second didWriteData:0 totalBytesWritten:-1 totalBytesExpectedToWrite:64];
    check([d.snapshot[@"received"] unsignedLongLongValue]==[one[@"compressed"] unsignedLongLongValue],@"negative partial progress cannot wrap the byte total");
    store=[LocalStore new];store.ready=YES;[d configureStore:(id)store];drain(d);
    check([d.snapshot[@"phase"] isEqual:@"ready"]&&!d.completed.count&&!d.received.count&&[d.snapshot[@"received"] unsignedLongLongValue]==0,@"an existing install clears obsolete download bookkeeping");

    d=download(@[]);[d.journal removeObjectForKey:@"jobs"];d.journal[@"phase"]=@"preparing";
    AgePadSteamContentClient *authorizing=[AgePadSteamContentClient new];d.preparer=authorizing;
    [d configureStore:(id)store];drain(d);
    check(!d.preparer&&authorizing.cancelled&&[d.snapshot[@"phase"] isEqual:@"ready"],@"Files completion cancels redundant Steam authorization before chunks are queued");

    d=chunkDownload(&location);store=[LocalStore new];d.store=(id)store;task=(id)d.active[@0];
    [d URLSession:d.session downloadTask:(id)task didFinishDownloadingToURL:location];complete(d,@0,nil);
    check([d.snapshot[@"phase"] isEqual:@"ready"]&&!d.completed.count&&!d.active.count&&!d.received.count&&!d.keys,@"successful installation releases the finished chunk bookkeeping");

    d=download(jobs(4));[d save];[NSFileManager.defaultManager createDirectoryAtPath:d.stage withIntermediateDirectories:YES attributes:nil error:NULL];
    for(NSUInteger i=0;i<2;i++){NSString *path=[d.stage stringByAppendingPathComponent:chunk(i)[@"path"]];[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];[[NSMutableData dataWithLength:i?4:16] writeToFile:path atomically:YES];}
    uint32_t records[]={0,0,1,2,99};NSMutableData *ledger=[NSMutableData dataWithBytes:records length:sizeof records];[ledger appendBytes:"xx" length:2];[ledger writeToFile:d.progressPath atomically:YES];
    LocalSession *session=(id)d.session;LocalTask *stale=[LocalTask new];stale.taskDescription=@"old:3";LocalTask *done=[LocalTask new];done.taskDescription=@"fixture:0";LocalTask *pending=[LocalTask new];pending.taskDescription=@"fixture:3";session.restoredTasks=@[stale,done,pending];d.restored=NO;
    [d restore];drain(d);
    check([d.completed isEqual:[NSSet setWithObject:@0]],@"restore discards duplicate, missing and truncated chunk files");
    check([d.snapshot[@"received"] unsignedLongLongValue]==64,@"restore recomputes bytes only from surviving files");
    check(stale.cancels==1&&done.cancels==1&&d.active[@3]==(id)pending&&d.active.count==3,@"restore retains the current daemon task and schedules every hole");
    check([NSData dataWithContentsOfFile:d.progressPath].length==20,@"restore truncates torn ledger records before appending");
    setPlan(d,d.journal[@"jobs"]);check([d.completed containsObject:@0]&&[d.snapshot[@"received"] unsignedLongLongValue]==64,@"same-plan authorization retains verified progress");
    setPlan(d,jobs(5));check(!d.completed.count&&[d.snapshot[@"received"] unsignedLongLongValue]==0&&d.active.count==5,@"changed plan resets completed bytes and submission position");
    LocalTask *old=(id)d.active[@0];[d cancel];drain(d);[d URLSession:d.session task:(id)old didCompleteWithError:nil];
    check(!d.completed.count&&!d.active.count&&[d.snapshot[@"received"] unsignedLongLongValue]==0,@"cancel clears progress and rejects lingering callbacks");

    CountedJobs *counted=[CountedJobs new];counted.values=jobs(16000);d=download(counted);
    for(NSUInteger i=0;i<15000;i++)[d.completed addObject:@(i)];
    setPlan(d,counted);counted.reads=0;d.journal[@"jobs"]=counted;
    NSTimeInterval start=NSDate.date.timeIntervalSinceReferenceDate;
    for(NSUInteger i=0;i<1000;i++){@autoreleasepool{[d publish:nil];}}
    double elapsed=NSDate.date.timeIntervalSinceReferenceDate-start;
    check([d.snapshot[@"received"] unsignedLongLongValue]==113452500,@"large-plan progress equals the completed chunk sum");
    check(counted.reads==0,@"progress updates do not rescan completed job metadata");
    printf("BENCH publish calls=1000 completed=15000 jobs=16000 seconds=%.6f job_reads=%lu\n",elapsed,(unsigned long)counted.reads);

    d=chunkDownload(&location);NSDictionary *template=d.journal[@"jobs"][0];NSMutableArray *many=[NSMutableArray new];
    for(NSUInteger i=0;i<16000;i++){NSMutableDictionary *job=[template mutableCopy];job[@"path"]=chunk(i)[@"path"];[many addObject:job];}
    CountedCompleted *completed=[CountedCompleted new];for(NSUInteger i=0;i<15000;i++)[completed addObject:@(i)];
    d.completed=completed;d.journal[@"jobs"]=many;setPlan(d,many);completed.lookups=0;
    start=NSDate.date.timeIntervalSinceReferenceDate;
    for(NSUInteger i=15000;i<15064;i++){
        LocalTask *next=(id)d.active[@(i)];next.response=((LocalTask *)[(LocalSession *)d.session created].firstObject).response;
        [d URLSession:d.session downloadTask:(id)next didFinishDownloadingToURL:location];complete(d,@(i),nil);
    }
    elapsed=NSDate.date.timeIntervalSinceReferenceDate-start;
    check(d.active.count==96&&[d.completed containsObject:@15063]&&d.active[@15159],@"successive completions fill later slots without exceeding the batch");
    check(completed.lookups<=256,@"normal queue refill work stays bounded per completion");
    printf("BENCH fill completions=64 completed=15000 jobs=16000 seconds=%.6f membership_checks=%lu\n",elapsed,(unsigned long)completed.lookups);
    printf("%u production downloader checks passed\n",checks);
}return 0;}
