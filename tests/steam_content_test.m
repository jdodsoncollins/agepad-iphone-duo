#import <Foundation/Foundation.h>
#import "../port/steam-engine/SteamContentClient.m"
#import "SteamDownloadJournal.h"
#import "steam_content_fixtures.h"

static unsigned checks;
static void check(BOOL pass,NSString *label){if(!pass){fprintf(stderr,"FAIL %s\n",label.UTF8String);exit(1);}checks++;}
static NSDictionary *job(NSData *data,NSUInteger compressed){uint8_t digest[20];CC_SHA1(data.bytes,(CC_LONG)data.length,digest);return @{@"sha":SCHex([NSData dataWithBytes:digest length:20]),@"length":@(data.length),@"compressed":@(compressed),@"checksum":@((uint32_t)adler32(0,data.bytes,(uInt)data.length)),@"offset":@0,@"depot":@1,@"path":@"resources/core.bin"};}
int main(int argc,char **argv){@autoreleasepool{
    NSString *root=@(argv[1]);NSData *plain=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"plain"]];NSData *key=[NSMutableData dataWithLength:32];NSError *error=nil;
    for(NSString *kind in @[@"zip",@"vzip",@"zstd"]){NSData *frame=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:kind]];NSData *cipher=encryptFixture(frame,key);NSDictionary *chunk=job(plain,cipher.length);
        check([AgePadSteamDecodeChunk(cipher,key,chunk,&error) isEqual:plain],[kind stringByAppendingString:@" decrypt/decompress/integrity"]);
        NSMutableData *corrupt=[cipher mutableCopy];((uint8_t *)corrupt.mutableBytes)[18]^=1;
        check(!AgePadSteamDecodeChunk(corrupt,key,chunk,&error),[kind stringByAppendingString:@" corrupt ciphertext rejected"]);
        NSMutableDictionary *wrong=[chunk mutableCopy];wrong[@"checksum"]=@7;check(!AgePadSteamDecodeChunk(cipher,key,wrong,&error),@"manifest checksum enforced");
        wrong=[chunk mutableCopy];wrong[@"sha"]=@"0000000000000000000000000000000000000000";check(!AgePadSteamDecodeChunk(cipher,key,wrong,&error),@"chunk SHA enforced");
    }
    check(!AgePadSteamDecodeChunk(NSData.data,key,job(plain,0),&error),@"truncated chunk rejected");
    NSMutableData *mapping=[NSMutableData new];PutString(mapping,1,@"AgeOfEmpires2Data\\resources\\core.bin");PutInt(mapping,2,4);
    NSMutableData *payload=[NSMutableData new];PutBytes(payload,1,mapping);PutBytes(payload,1,mapping);
    NSMutableData *metadata=[NSMutableData new];PutInt(metadata,1,1);PutInt(metadata,2,42);
    NSMutableData *manifest=[NSMutableData new];for(NSArray *section in @[@[@(0x71f617d0),payload],@[@(0x1f4812be),metadata]]){uint32_t magic=[section[0] unsignedIntValue],length=(uint32_t)[section[1] length];[manifest appendBytes:&magic length:4];[manifest appendBytes:&length length:4];[manifest appendData:section[1]];}
    uint32_t end=0x32c415ab;[manifest appendBytes:&end length:4];NSData *archive=storedZip(manifest);
    NSArray *files=AgePadSteamManifestFiles(archive,key,1,42,&error);check(files.count==2,@"repeated manifest mappings preserved");
    check([files[0][@"path"] isEqual:@"AgeOfEmpires2Data/resources/core.bin"],@"Steam path separators normalized");
    check(!AgePadSteamManifestFiles(archive,key,1,43,&error),@"different build manifest rejected");
    NSMutableData *invalid=[manifest mutableCopy];invalid.length-=4;check(!AgePadSteamManifestFiles(storedZip(invalid),key,1,42,&error),@"truncated manifest rejected");
    check(AgePadSteamContentHost(@"cache1-lax1.steamcontent.com")&&!AgePadSteamContentHost(@"steamcontent.com.attacker.test"),@"CDN host allowlist has a domain boundary");
    check(!AgePadSteamContentHost(@"attacker.test/path.steamcontent.com")&&!AgePadSteamContentHost(@"attacker.test@cache.steamcontent.com"),@"CDN host cannot contain a path or credentials");
    NSDictionary *j=job(plain,64);NSDictionary *profile=@{@"entries":@[@{@"path":@"resources/core.bin",@"bytes":@(plain.length)}]};
    NSMutableDictionary *journal=[@{@"profile":@"trusted",@"jobs":@[j],@"total":@64,@"completed":@[@0],@"authorizations":@{@"1":@{@"host":@"cache.steamcontent.com",@"suffix":@""}}} mutableCopy];
    check(AgePadValidDownloadJournal(journal,profile,@"trusted",@{@"1":key}),@"valid resume journal accepted");
    for(NSDictionary *replacement in @[@{@"profile":@"other"},@{@"completed":@[@2]},@{@"completed":@[@(-1)]},@{@"total":@65},@{@"jobs":@[@{@"path":@"../../escape",@"depot":@1}]}]){NSMutableDictionary *bad=[journal mutableCopy];[bad addEntriesFromDictionary:replacement];check(!AgePadValidDownloadJournal(bad,profile,@"trusted",@{@"1":key}),@"invalid restored state rejected");}
    check(!AgePadValidDownloadJournal(journal,profile,@"trusted",@{}),@"lost Keychain key cannot resume unverified data");
    uint32_t records[]={0,1,1,99};NSMutableData *ledger=[NSMutableData dataWithBytes:records length:sizeof records];[ledger appendBytes:"xx" length:2];
    check([AgePadCompletedRecords(ledger,3) isEqual:[NSSet setWithArray:@[@0,@1]]],@"completion ledger ignores duplicates, invalid indexes and torn writes");
    NSString *temporary=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *alias=[temporary stringByAppendingString:@"-alias"];[NSFileManager.defaultManager createSymbolicLinkAtPath:alias withDestinationPath:temporary error:NULL];
    check(AgePadDownloadPathInside(alias,[temporary stringByAppendingPathComponent:@"content/file"]),@"canonical root accepts equivalent symlink spelling such as /var and /private/var");
    check(!AgePadDownloadPathInside(temporary,[temporary stringByAppendingString:@"-escape/file"]),@"sibling path cannot escape download root");
    [NSFileManager.defaultManager removeItemAtPath:alias error:NULL];[NSFileManager.defaultManager removeItemAtPath:temporary error:NULL];
    printf("%u Steam content/integrity/resume checks passed\n",checks);
}return 0;}
