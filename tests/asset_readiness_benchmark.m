#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "GameAssetStore.h"
static NSString *digest(NSData *data){uint8_t bytes[32];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);NSMutableString *s=[NSMutableString new];for(int i=0;i<32;i++)[s appendFormat:@"%02x",bytes[i]];return s;}
int main(void){@autoreleasepool{
    NSFileManager *fm=NSFileManager.defaultManager;NSString *home=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *root=[home stringByAppendingPathComponent:@"Documents/AgeOfEmpires2Data"],*support=[home stringByAppendingPathComponent:@"Library/Application Support/AgePad"];
    [fm createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:NULL];NSMutableArray *entries=[NSMutableArray new];
    NSData *data=[@"x" dataUsingEncoding:NSUTF8StringEncoding];NSString *hash=digest(data);
    for(int i=0;i<17199;i++){@autoreleasepool{
        NSString *relative=[NSString stringWithFormat:@"resources/common/group%d/file%d.bin",i/128,i];NSString *path=[root stringByAppendingPathComponent:relative];
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];[data writeToFile:path atomically:NO];
        [entries addObject:@{@"path":relative,@"bytes":@1,@"sha256":hash}];
    }}
    NSDictionary *profile=@{@"schema_version":@1,@"profile_id":@"readiness-benchmark",@"steam_app_id":@813780,@"entries":entries,@"excluded":@[],@"files":@(entries.count),@"bytes":@(entries.count)};
    NSData *raw=[NSJSONSerialization dataWithJSONObject:profile options:0 error:NULL];NSString *path=[home stringByAppendingPathComponent:@"profile.json"];[raw writeToFile:path atomically:YES];
    [[NSJSONSerialization dataWithJSONObject:@{@"profile_sha256":digest(raw)} options:0 error:NULL] writeToFile:[support stringByAppendingPathComponent:@"InstallReceipt.json"] atomically:YES];
    AgePadGameAssetStore *store=[[AgePadGameAssetStore alloc] initWithHome:home profileURL:[NSURL fileURLWithPath:path]];
    CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();BOOL ready=[store isReady];double elapsed=CFAbsoluteTimeGetCurrent()-start;
    printf("{\"files\":17199,\"ready\":%s,\"readiness_seconds\":%.6f}\n",ready?"true":"false",elapsed);[fm removeItemAtPath:home error:NULL];return ready?0:1;
}}
