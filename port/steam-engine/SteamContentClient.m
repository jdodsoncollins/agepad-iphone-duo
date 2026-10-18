#import "SteamContentClient.h"
#import "SteamProtobuf.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include "../third_party/xz/include/lzma.h"

// Zstandard's BSD-licensed, pinned standalone decoder (see third_party/README).
size_t ZSTD_decompress(void *,size_t,const void *,size_t);
unsigned ZSTD_isError(size_t);

static id SCFail(NSError **error,NSString *message) {
    if(error)*error=[NSError errorWithDomain:@"AgePadSteamContent" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return nil;
}
static uint32_t SC32(const void *bytes){uint32_t v;memcpy(&v,bytes,4);return CFSwapInt32LittleToHost(v);}
static void SCFixed(NSMutableData *out,int field,uint64_t value){PutVarint(out,((uint64_t)field<<3)|1);value=CFSwapInt64HostToLittle(value);[out appendBytes:&value length:8];}
// Always arrays: repeated mappings and chunks must never be silently dropped.
static NSDictionary *SCParse(NSData *data) {
    if(![data isKindOfClass:NSData.class])return nil;
    NSMutableDictionary *out=[NSMutableDictionary new];const uint8_t *b=data.bytes;NSUInteger p=0,n=data.length;
    while(p<n){uint64_t tag=0,v=0;if(!GetVarint(b,n,&p,&tag)||!(tag>>3)||(tag>>3)>0x1fffffff)return nil;
        NSNumber *k=@(tag>>3);id value=nil;
        switch(tag&7){
        case 0:if(!GetVarint(b,n,&p,&v))return nil;value=@(v);break;
        case 1:if(n-p<8)return nil;memcpy(&v,b+p,8);p+=8;value=@(CFSwapInt64LittleToHost(v));break;
        case 5:if(n-p<4)return nil;value=@(SC32(b+p));p+=4;break;
        case 2:if(!GetVarint(b,n,&p,&v)||v>n-p)return nil;value=[data subdataWithRange:NSMakeRange(p,v)];p+=v;break;
        default:return nil;
        }
        if(!out[k])out[k]=[NSMutableArray new];[out[k] addObject:value];
    }return out;
}
static id SCField(NSDictionary *p,int f){return [p[@(f)] firstObject];}
static uint64_t SCNumber(NSDictionary *p,int f){id v=SCField(p,f);return [v isKindOfClass:NSNumber.class]?[v unsignedLongLongValue]:0;}
static NSString *SCText(NSDictionary *p,int f){id v=SCField(p,f);return [v isKindOfClass:NSData.class]?[[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding]:nil;}
static NSString *SCHex(NSData *d){NSMutableString *s=[NSMutableString new];for(NSUInteger i=0;i<d.length;i++)[s appendFormat:@"%02x",((const uint8_t *)d.bytes)[i]];return s;}
BOOL AgePadSteamContentHost(NSString *host){
    if(![host isKindOfClass:NSString.class]||!host.length||host.length>253)return NO;
    NSString *h=host.lowercaseString;
    if([h rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789.-"].invertedSet].location!=NSNotFound)return NO;
    return [h hasSuffix:@".steamcontent.com"]||[h hasSuffix:@".steampowered.com"];
}
static NSData *SCInflate(NSData *input,NSUInteger limit,int window,NSError **error){
    if(!input.length||!limit||limit>(64<<20))return SCFail(error,@"Steam sent an invalid compressed response.");
    NSMutableData *out=[NSMutableData dataWithLength:limit];z_stream z={0};
    z.next_in=(Bytef *)input.bytes;z.avail_in=(uInt)input.length;z.next_out=out.mutableBytes;z.avail_out=(uInt)out.length;
    if(inflateInit2(&z,window)!=Z_OK)return SCFail(error,@"Couldn't initialize content decompression.");
    int result=inflate(&z,Z_FINISH);inflateEnd(&z);
    if(result!=Z_STREAM_END)return SCFail(error,@"Steam sent incomplete or oversized compressed content.");out.length=z.total_out;return out;
}
static NSData *SCUnzip(NSData *zip,NSUInteger limit,NSError **error){
    const uint8_t *b=zip.bytes;NSUInteger n=zip.length;
    if(n<30||SC32(b)!=0x04034b50)return SCFail(error,@"Steam returned an invalid content archive.");
    uint16_t flags=b[6]|b[7]<<8,method=b[8]|b[9]<<8;
    NSUInteger start=30+(b[26]|b[27]<<8)+(b[28]|b[29]<<8);
    if((flags&1)||start>=n)return SCFail(error,@"Steam returned an invalid content archive.");
    // A ZIP data descriptor is allowed. zlib stops at the end of the stream.
    if(method==8)return SCInflate([zip subdataWithRange:NSMakeRange(start,n-start)],limit,-MAX_WBITS,error);
    uint32_t size=SC32(b+18);if(method==0&&size<=limit&&size<=n-start)return [zip subdataWithRange:NSMakeRange(start,size)];
    return SCFail(error,@"Steam returned an unsupported content archive.");
}
static NSData *SCDecrypt(NSData *data,NSData *key,NSError **error){
    if(key.length!=32||data.length<32||data.length%16)return SCFail(error,@"Steam content encryption metadata is invalid.");
    uint8_t iv[16];size_t count=0;
    if(CCCrypt(kCCDecrypt,kCCAlgorithmAES,kCCOptionECBMode,key.bytes,key.length,NULL,data.bytes,16,iv,16,&count)!=kCCSuccess)
        return SCFail(error,@"Couldn't decrypt Steam content.");
    NSMutableData *out=[NSMutableData dataWithLength:data.length];
    if(CCCrypt(kCCDecrypt,kCCAlgorithmAES,kCCOptionPKCS7Padding,key.bytes,key.length,iv,(const uint8_t *)data.bytes+16,data.length-16,out.mutableBytes,out.length,&count)!=kCCSuccess)
        return SCFail(error,@"Couldn't verify Steam content encryption.");out.length=count;return out;
}
NSData *AgePadSteamDecodeChunk(NSData *encrypted,NSData *key,NSDictionary *chunk,NSError **error){
    NSUInteger wanted=[chunk[@"length"] unsignedIntegerValue];
    if(!wanted||wanted>(4<<20)||encrypted.length!=[chunk[@"compressed"] unsignedIntegerValue])return SCFail(error,@"The Steam download is incomplete. Retry to resume it.");
    NSData *plain=SCDecrypt(encrypted,key,error);if(!plain)return nil;
    const uint8_t *b=plain.bytes;NSUInteger n=plain.length;NSData *output=nil;
    if(n>22&&!memcmp(b,"VZa",3)&&b[n-2]=='z'&&b[n-1]=='v'){
        if(SC32(b+n-6)!=wanted)return SCFail(error,@"Steam chunk size doesn't match its manifest.");
        // VZip contains five LZMA properties, no .lzma size header. Add that
        // header and use the system's bounded liblzma decoder.
        NSMutableData *alone=[NSMutableData dataWithBytes:b+7 length:5];uint64_t size=CFSwapInt64HostToLittle(wanted);
        [alone appendBytes:&size length:8];[alone appendBytes:b+12 length:n-22];
        NSMutableData *decoded=[NSMutableData dataWithLength:wanted];lzma_stream stream=LZMA_STREAM_INIT;
        lzma_ret result=lzma_alone_decoder(&stream,32<<20);
        if(result==LZMA_OK){stream.next_in=alone.bytes;stream.avail_in=alone.length;stream.next_out=decoded.mutableBytes;stream.avail_out=decoded.length;result=lzma_code(&stream,LZMA_FINISH);}
        BOOL ok=result==LZMA_STREAM_END&&stream.total_out==wanted;lzma_end(&stream);
        if(!ok)return SCFail(error,@"Steam's LZMA chunk is corrupt.");
        if((uint32_t)crc32(0,decoded.bytes,(uInt)decoded.length)!=SC32(b+n-10))return SCFail(error,@"Steam chunk CRC verification failed.");output=decoded;
    }else if(n>23&&!memcmp(b,"VSZa",4)&&!memcmp(b+n-3,"zsv",3)){
        if(SC32(b+n-11)!=wanted)return SCFail(error,@"Steam chunk size doesn't match its manifest.");
        NSMutableData *decoded=[NSMutableData dataWithLength:wanted];size_t size=ZSTD_decompress(decoded.mutableBytes,wanted,b+8,n-23);
        if(ZSTD_isError(size)||size!=wanted||(uint32_t)crc32(0,decoded.bytes,(uInt)decoded.length)!=SC32(b+n-15))return SCFail(error,@"Steam's Zstandard chunk is corrupt.");output=decoded;
    }else output=SCUnzip(plain,wanted,error);
    if(!output)return nil;
    // Valve's chunk checksum uses an Adler seed of zero, unlike zlib's default.
    uint32_t checksum=(uint32_t)adler32(0,output.bytes,(uInt)output.length);
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];CC_SHA1(output.bytes,(CC_LONG)output.length,digest);
    if(output.length!=wanted||checksum!=[chunk[@"checksum"] unsignedIntValue]||![SCHex([NSData dataWithBytes:digest length:sizeof digest]) isEqual:chunk[@"sha"]])return SCFail(error,@"Steam chunk integrity verification failed. Retry to resume.");
    return output;
}
NSArray *AgePadSteamManifestFiles(NSData *zip,NSData *key,uint32_t depot,uint64_t manifest,NSError **error){
    NSData *raw=SCUnzip(zip,64<<20,error);if(!raw)return nil;
    const uint8_t *b=raw.bytes;NSUInteger p=0,n=raw.length;NSDictionary *payload=nil,*metadata=nil;BOOL ended=NO;
    while(p+4<=n){uint32_t magic=SC32(b+p);p+=4;if(magic==0x32c415ab){ended=YES;break;}
        if(p+4>n)return SCFail(error,@"The Steam manifest is truncated.");NSUInteger size=SC32(b+p);p+=4;
        if(size>n-p)return SCFail(error,@"The Steam manifest is truncated.");
        if(magic==0x71f617d0)payload=SCParse([raw subdataWithRange:NSMakeRange(p,size)]);
        else if(magic==0x1f4812be)metadata=SCParse([raw subdataWithRange:NSMakeRange(p,size)]);
        else if(magic!=0x1b81b817)return SCFail(error,@"Steam returned an unsupported manifest format.");p+=size;
    }
    if(!ended||!payload||SCNumber(metadata,1)!=depot||SCNumber(metadata,2)!=manifest)return SCFail(error,@"Steam returned a different game version. Your existing install is preserved.");
    NSMutableArray *files=[NSMutableArray new];
    for(NSData *mapping in payload[@1]){
        NSDictionary *f=SCParse(mapping);NSString *name=SCText(f,1);
        if(SCNumber(metadata,4)){
            NSData *encrypted=[[NSData alloc] initWithBase64EncodedString:name?:@"" options:0];
            NSData *clear=encrypted?SCDecrypt(encrypted,key,error):nil;if(!clear)return nil;
            const uint8_t *c=clear.bytes;NSUInteger count=clear.length;while(count&&c[count-1]==0)count--;
            name=[[NSString alloc] initWithBytes:c length:count encoding:NSUTF8StringEncoding];
        }
        name=[name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if(!name)return SCFail(error,@"Steam returned an invalid filename.");
        NSMutableArray *chunks=[NSMutableArray new];
        for(NSData *part in f[@6]){NSDictionary *c=SCParse(part);NSData *sha=SCField(c,1);
            if(sha.length!=20)return SCFail(error,@"Steam returned invalid chunk metadata.");
            [chunks addObject:@{@"sha":SCHex(sha),@"offset":@(SCNumber(c,3)),@"length":@(SCNumber(c,4)),@"compressed":@(SCNumber(c,5)),@"checksum":@(SCNumber(c,2)),@"depot":@(depot)}];
        }
        [files addObject:@{@"path":name,@"bytes":@(SCNumber(f,2)),@"flags":@(SCNumber(f,3)),@"link":SCText(f,7)?:@"",@"chunks":chunks}];
    }return files;
}

@interface AgePadSteamContentClient ()
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionWebSocketTask *socket;
@property(nonatomic,strong) NSMutableArray *inbox;
@property(nonatomic) uint64_t steamID,job;
@property(nonatomic) uint32_t sessionID;
@property(nonatomic,strong) dispatch_source_t heartbeat;
@end
@implementation AgePadSteamContentClient
- (instancetype)init{if((self=[super init])){NSURLSessionConfiguration *c=NSURLSessionConfiguration.ephemeralSessionConfiguration;c.URLCache=nil;c.HTTPCookieStorage=nil;_session=[NSURLSession sessionWithConfiguration:c];_inbox=[NSMutableArray new];}return self;}
- (NSData *)http:(NSString *)url error:(NSError **)error{
    __block NSData *data=nil;__block NSInteger status=0;dispatch_semaphore_t done=dispatch_semaphore_create(0);
    NSURLSessionDataTask *task=[self.session dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *d,NSURLResponse *r,NSError *e){if(!e)data=d;status=[(NSHTTPURLResponse *)r statusCode];dispatch_semaphore_signal(done);}];[task resume];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))){[task cancel];return SCFail(error,@"Steam content request timed out. Try again.");}
    if(self.cancelled)return SCFail(error,@"Download preparation paused.");
    if(status!=200||!data||data.length>(64<<20))return SCFail(error,[NSString stringWithFormat:@"Steam content request failed (HTTP %ld). Retry to resume.",(long)status]);return data;
}
- (BOOL)send:(uint32_t)message body:(NSData *)body job:(uint64_t)job method:(NSString *)method error:(NSError **)error{
    if(self.cancelled){SCFail(error,@"Download preparation paused.");return NO;}
    NSMutableData *header=[NSMutableData new];SCFixed(header,1,self.steamID);PutInt(header,2,self.sessionID);
    if(job)SCFixed(header,10,job);if(method)PutString(header,12,method);
    NSMutableData *packet=[NSMutableData new];uint32_t m=CFSwapInt32HostToLittle(message|0x80000000),len=CFSwapInt32HostToLittle((uint32_t)header.length);
    [packet appendBytes:&m length:4];[packet appendBytes:&len length:4];[packet appendData:header];[packet appendData:body];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL ok=NO;
    [self.socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:packet] completionHandler:^(NSError *e){ok=!e;dispatch_semaphore_signal(done);}];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))||!ok){SCFail(error,@"Steam content connection was interrupted. Retry to resume.");return NO;}return YES;
}
- (BOOL)unpack:(NSData *)packet depth:(int)depth error:(NSError **)error{
    if(depth>8||packet.length<8||packet.length>(64<<20)){SCFail(error,@"Steam sent an invalid content message.");return NO;}
    const uint8_t *b=packet.bytes;uint32_t message=SC32(b),size=SC32(b+4);
    if(!(message&0x80000000)||size>packet.length-8){SCFail(error,@"Steam sent an invalid content message.");return NO;}
    message&=0x7fffffff;NSDictionary *header=SCParse([packet subdataWithRange:NSMakeRange(8,size)]);
    NSData *body=[packet subdataWithRange:NSMakeRange(8+size,packet.length-8-size)];
    if(message==1){NSDictionary *multi=SCParse(body);NSData *parts=SCField(multi,2);NSUInteger expanded=SCNumber(multi,1);
        if(expanded){parts=SCInflate(parts,expanded,MAX_WBITS+32,error);if(!parts||parts.length!=expanded)return NO;}
        const uint8_t *p=parts.bytes;NSUInteger at=0;
        while(at+4<=parts.length){NSUInteger count=SC32(p+at);at+=4;if(count>parts.length-at){SCFail(error,@"Steam sent a truncated content message.");return NO;}
            if(![self unpack:[parts subdataWithRange:NSMakeRange(at,count)] depth:depth+1 error:error])return NO;at+=count;}
        return at==parts.length;
    }
    if(message==5515){self.sessionID=(uint32_t)SCNumber(header,2);if(SCNumber(header,1))self.steamID=SCNumber(header,1);}
    // Ignore unsolicited chat/license/account payloads; never persist or log them.
    if(message==5515||message==5439||message==147||message==5517)[self.inbox addObject:@{@"message":@(message),@"header":header?:@{},@"body":body}];return YES;
}
- (NSDictionary *)wait:(uint32_t)message job:(uint64_t)job error:(NSError **)error{
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:35];
    while(!self.cancelled&&end.timeIntervalSinceNow>0){
        for(NSDictionary *reply in self.inbox.copy){
            if([reply[@"message"] unsignedIntValue]==5517)return SCFail(error,@"Steam ended the content session. Return to the library and retry.");
            if([reply[@"message"] unsignedIntValue]==message&&(!job||SCNumber(reply[@"header"],11)==job)){[self.inbox removeObject:reply];return reply;}
        }
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSData *data=nil;
        [self.socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *m,NSError *e){if(!e)data=m.data;dispatch_semaphore_signal(done);}];
        if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))||!data)return SCFail(error,@"Steam content connection timed out. Retry to resume.");
        if(![self unpack:data depth:0 error:error])return nil;
    }return SCFail(error,@"Download preparation paused or timed out.");
}
- (NSDictionary *)service:(NSString *)method body:(NSData *)body error:(NSError **)error{
    uint64_t job=++self.job;if(![self send:151 body:body job:job method:method error:error])return nil;
    NSDictionary *reply=[self wait:147 job:job error:error];if(!reply)return nil;
    uint64_t result=SCNumber(reply[@"header"],13);
    if(result!=1)return SCFail(error,[NSString stringWithFormat:@"Steam declined content authorization (result %llu). No game files were changed.",result]);return SCParse(reply[@"body"]);
}
- (BOOL)connectToken:(NSString *)token steamID:(uint64_t)steamID account:(NSString *)account error:(NSError **)error{
    NSData *directory=[self http:@"https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cmtype=websockets&cellid=0" error:error];if(!directory)return NO;
    NSDictionary *json=[NSJSONSerialization JSONObjectWithData:directory options:0 error:NULL];NSString *host=nil;
    for(NSDictionary *entry in json[@"response"][@"serverlist"]){NSString *candidate=entry[@"endpoint"];NSURL *url=[NSURL URLWithString:[@"wss://" stringByAppendingString:candidate?:@""]];
        if(AgePadSteamContentHost(url.host)&&!url.user&&!url.password){host=candidate;break;}}
    if(!host){SCFail(error,@"Steam didn't return a usable content connection. Try again.");return NO;}
    self.steamID=steamID;self.socket=[self.session webSocketTaskWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"wss://%@/cmsocket/",host]]];self.socket.maximumMessageSize=64<<20;[self.socket resume];
    NSMutableData *hello=[NSMutableData new];PutInt(hello,1,65580);if(![self send:4006 body:hello job:0 method:nil error:error])return NO;
    NSMutableData *logon=[NSMutableData new];PutInt(logon,1,65580);PutInt(logon,2,arc4random());PutString(logon,6,@"english");PutInt(logon,7,0xfffffffb);PutInt(logon,8,1);
    PutString(logon,50,account);PutString(logon,96,@"AgePad content download");PutString(logon,108,token);
    if(![self send:5514 body:logon job:0 method:nil error:error])return NO;
    NSDictionary *reply=[self wait:5515 job:0 error:error];if(!reply)return NO;
    uint64_t result=SCNumber(SCParse(reply[@"body"]),1);fprintf(stderr,"AGEPAD_CONTENT_LOGON result=%llu\n",result);
    if(result!=1){SCFail(error,[NSString stringWithFormat:@"Steam couldn't authorize downloads (result %llu). Reconnect Steam and retry.",result]);return NO;}
    self.heartbeat=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(self.heartbeat,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),15*NSEC_PER_SEC,NSEC_PER_SEC);
    __weak typeof(self) weak=self;dispatch_source_set_event_handler(self.heartbeat,^{[weak send:703 body:NSData.data job:0 method:nil error:NULL];});dispatch_resume(self.heartbeat);return YES;
}
- (NSDictionary *)prepareProfile:(NSDictionary *)profile appManifest:(NSString *)manifest token:(NSString *)token steamID:(uint64_t)steamID account:(NSString *)account progress:(void (^)(NSString *))progress error:(NSError **)error{
    if([profile[@"steam_app_id"] unsignedIntValue]!=813780||!token.length||!steamID)return SCFail(error,@"Sign in to Steam before downloading your game.");
    if(![self connectToken:token steamID:steamID account:account error:error])return nil;
    NSMutableData *serverRequest=[NSMutableData new];PutInt(serverRequest,1,0);PutInt(serverRequest,2,20);
    NSDictionary *servers=[self service:@"ContentServerDirectory.GetServersForSteamPipe#1" body:serverRequest error:error];if(!servers)return nil;
    NSString *host=nil;for(NSData *server in servers[@1]){NSDictionary *s=SCParse(server);NSString *h=SCText(s,8);
        if(AgePadSteamContentHost(h)&&!SCNumber(s,10)&&![SCText(s,12) isEqual:@"none"]){host=h;break;}}
    if(!host)return SCFail(error,@"Steam has no HTTPS content server available. Try again.");
    NSRegularExpression *depotPattern=[NSRegularExpression regularExpressionWithPattern:@"\"(\\d+)\"\\s*\\{\\s*\"manifest\"\\s*\"(\\d+)\"" options:0 error:NULL];
    NSMutableDictionary *wanted=[NSMutableDictionary new];for(NSDictionary *entry in profile[@"entries"])wanted[entry[@"path"]]=entry;
    NSMutableDictionary *found=[NSMutableDictionary new],*keys=[NSMutableDictionary new],*authorizations=[NSMutableDictionary new];
    NSUInteger count=0;NSArray *depots=[depotPattern matchesInString:manifest options:0 range:NSMakeRange(0,manifest.length)];
    if(!depots.count||depots.count>64)return SCFail(error,@"This build has no pinned Steam content manifests.");
    for(NSTextCheckingResult *match in depots){
        uint32_t depot=[[manifest substringWithRange:[match rangeAtIndex:1]] intValue];uint64_t gid=strtoull([[manifest substringWithRange:[match rangeAtIndex:2]] UTF8String],NULL,10);
        if(progress)progress([NSString stringWithFormat:@"Preparing Steam download · depot %lu of %lu",(unsigned long)++count,(unsigned long)depots.count]);
        NSMutableData *keyRequest=[NSMutableData new];PutInt(keyRequest,1,depot);PutInt(keyRequest,2,813780);uint64_t job=++self.job;
        if(![self send:5438 body:keyRequest job:job method:nil error:error])return nil;
        NSDictionary *keyReply=[self wait:5439 job:job error:error];if(!keyReply)return nil;NSDictionary *keyBody=SCParse(keyReply[@"body"]);
        uint64_t result=SCNumber(keyBody,1);if(result==9||result==15)continue; // Missing DLC: never invent entitlement.
        NSData *key=SCField(keyBody,3);if(result!=1||SCNumber(keyBody,2)!=depot||key.length!=32)return SCFail(error,@"Steam didn't authorize a required depot. Your existing install is preserved.");
        NSMutableData *codeRequest=[NSMutableData new];PutInt(codeRequest,1,813780);PutInt(codeRequest,2,depot);PutInt(codeRequest,3,gid);PutString(codeRequest,4,@"public");
        NSDictionary *code=[self service:@"ContentServerDirectory.GetManifestRequestCode#1" body:codeRequest error:error];if(!code)return nil;
        uint64_t requestCode=SCNumber(code,1);if(!requestCode)return SCFail(error,@"Steam no longer serves this supported game version. Import the matching game folder from Files.");
        NSMutableData *authRequest=[NSMutableData new];PutInt(authRequest,1,depot);PutString(authRequest,2,host);PutInt(authRequest,3,813780);
        NSDictionary *auth=[self service:@"ContentServerDirectory.GetCDNAuthToken#1" body:authRequest error:error];if(!auth)return nil;
        NSString *authToken=SCText(auth,1)?:@"";NSString *suffix=authToken.length?([authToken hasPrefix:@"?"]?authToken:[@"?" stringByAppendingString:authToken]):@"";
        NSString *url=[NSString stringWithFormat:@"https://%@/depot/%u/manifest/%llu/5/%llu%@",host,depot,gid,requestCode,suffix];
        NSData *archive=[self http:url error:error];if(!archive)return nil;
        NSArray *files=AgePadSteamManifestFiles(archive,key,depot,gid,error);if(!files)return nil;
        NSString *depotKey=@(depot).stringValue;keys[depotKey]=key;authorizations[depotKey]=@{@"host":host,@"suffix":suffix,@"expires":@(SCNumber(auth,2))};
        for(NSDictionary *file in files){NSString *path=file[@"path"];NSString *prefix=@"AgeOfEmpires2Data/";if(![path hasPrefix:prefix])continue;
            NSString *relative=[path substringFromIndex:prefix.length];NSDictionary *entry=wanted[relative];if(!entry)continue;
            if([file[@"flags"] unsignedIntValue]&(64|512)||[file[@"link"] length]||[file[@"bytes"] unsignedLongLongValue]!=[entry[@"bytes"] unsignedLongLongValue])return SCFail(error,@"Steam's assets don't match this AgePad build. Import the matching game folder from Files.");
            NSArray *chunks=[file[@"chunks"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"offset"] compare:b[@"offset"]];}];
            uint64_t end=0;for(NSDictionary *chunk in chunks){uint64_t length=[chunk[@"length"] unsignedLongLongValue],compressed=[chunk[@"compressed"] unsignedLongLongValue];
                if([chunk[@"offset"] unsignedLongLongValue]!=end||!length||length>(4<<20)||compressed<32||compressed>(8<<20)||end+length<[chunk[@"offset"] unsignedLongLongValue])return SCFail(error,@"Steam returned invalid asset offsets.");end+=length;}
            if(end!=[entry[@"bytes"] unsignedLongLongValue])return SCFail(error,@"Steam returned incomplete asset chunks.");
            found[relative]=@{@"path":relative,@"bytes":entry[@"bytes"],@"sha256":entry[@"sha256"],@"chunks":chunks};
        }
    }
    if(found.count!=wanted.count)return SCFail(error,@"Steam couldn't supply every asset in this supported core pack. Some files may require an owned DLC. Import the matching game folder from Files.");
    return @{@"files":[found.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"path"] compare:b[@"path"]];}],@"keys":keys,@"authorizations":authorizations};
}
- (void)close{if(self.heartbeat){dispatch_source_cancel(self.heartbeat);self.heartbeat=nil;}[self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];[self.session invalidateAndCancel];}
- (void)dealloc{[self close];}
@end
