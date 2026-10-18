#import "SteamQRSignIn.h"
#import "SteamProtobuf.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <Security/Security.h>

NSString *const AgePadSteamRefreshToken=@"refresh_token";
NSString *const AgePadSteamAccountName=@"account_name";
NSString *const AgePadSteamID64=@"steam_id";

@interface AgePadSteamSignInRequest ()
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSDate *deadline;
@property(nonatomic,readwrite,getter=isCancelled) BOOL cancelled;
@property(nonatomic) BOOL ownsSession,retryableFailure;
- (instancetype)initWithSession:(NSURLSession *)session;
@end
@implementation AgePadSteamSignInRequest
@synthesize cancelled=_cancelled;
- (instancetype)init {
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.HTTPShouldSetCookies=NO;
    if((self=[self initWithSession:[NSURLSession sessionWithConfiguration:configuration]]))_ownsSession=YES;
    return self;
}
- (instancetype)initWithSession:(NSURLSession *)session {
    if ((self=[super init])) _session=session;
    return self;
}
- (BOOL)isCancelled { @synchronized(self) { return _cancelled; } }
- (void)setCancelled:(BOOL)value { @synchronized(self) { _cancelled=value; } }
- (void)cancel { @synchronized(self) { _cancelled=YES;[_task cancel];_task=nil; }if(_ownsSession)[_session invalidateAndCancel]; }
- (void)dealloc { [_task cancel];if(_ownsSession)[_session invalidateAndCancel]; }
@end

BOOL AgePadSteamShouldCancelDetachedPanel(BOOL wasAttached,BOOL hasWindow,BOOL hasSuperview) {
    return wasAttached && !hasWindow && !hasSuperview;
}

BOOL AgePadSteamIsChallengeURL(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length>2048) return NO;
    NSURLComponents *url=[NSURLComponents componentsWithString:value];
    return [url.scheme.lowercaseString isEqualToString:@"https"] &&
        [url.host.lowercaseString isEqualToString:@"s.team"] && !url.user && !url.password &&
        (!url.port || url.port.integerValue==443) && [url.path hasPrefix:@"/q/"];
}
static BOOL Active(AgePadSteamSignInRequest *request,NSString **error) {
    if (!request) { if (error) *error=@"Missing sign-in request.";return NO; }
    if (request.cancelled) { if (error) *error=@"Sign-in cancelled.";return NO; }
    if (request.deadline && request.deadline.timeIntervalSinceNow<=0) { if (error) *error=@"Sign-in timed out.";return NO; }
    return YES;
}
static BOOL Pause(AgePadSteamSignInRequest *request,NSTimeInterval seconds,NSString **error) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow>0) {
        if (!Active(request,error)) return NO;
        [NSThread sleepForTimeInterval:MIN(.1,end.timeIntervalSinceNow)];
    }
    return Active(request,error);
}

// Field number -> NSNumber (varint/fixed) or NSData (length-delimited); last value wins.
static NSDictionary *Parse(NSData *data) {
    NSMutableDictionary *fields=[NSMutableDictionary dictionary];
    const uint8_t *bytes=data.bytes;NSUInteger length=data.length,at=0;
    while (at<length) {
        uint64_t key,value;if (!GetVarint(bytes,length,&at,&key) || !(key>>3) || (key>>3)>0x1fffffff) return nil;
        int type=key&7;NSNumber *field=@(key>>3);
        if (type==0) { if (!GetVarint(bytes,length,&at,&value)) return nil;fields[field]=@(value); }
        else if (type==2) { if (!GetVarint(bytes,length,&at,&value) || value>length-at) return nil;fields[field]=[data subdataWithRange:NSMakeRange(at,value)];at+=value; }
        else if (type==5) { if (length-at<4) return nil;float f;memcpy(&f,bytes+at,4);fields[field]=@(f);at+=4; }
        else if (type==1) { if (length-at<8) return nil;uint64_t v;memcpy(&v,bytes+at,8);fields[field]=@(v);at+=8; }
        else return nil;
        // Repeated fields: every value, in order, under "*<field>".
        NSString *all=[NSString stringWithFormat:@"*%@",field];
        if (!fields[all]) fields[all]=[NSMutableArray array];
        [fields[all] addObject:fields[field]];
    }
    return fields;
}
static NSString *String(id value) { return [value isKindOfClass:NSData.class]?[[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding]:nil; }
static uint64_t Integer(id value) { return [value isKindOfClass:NSNumber.class]?[value unsignedLongLongValue]:0; }
static double Number(id value) { return [value isKindOfClass:NSNumber.class]?[value doubleValue]:0; }

static NSDictionary *Call(NSString *method,NSData *body,AgePadSteamSignInRequest *attempt,int *eresult,NSString **error) {
    *eresult=0;
    attempt.retryableFailure=NO;
    if (!Active(attempt,error)) return nil;
    NSString *encoded=[[body base64EncodedStringWithOptions:0] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    BOOL get=[method isEqualToString:@"GetPasswordRSAPublicKey"]; // a GET method in Steam's Web API
    NSString *address=[NSString stringWithFormat:@"https://api.steampowered.com/IAuthenticationService/%@/v1/",method];
    if (get) address=[address stringByAppendingFormat:@"?input_protobuf_encoded=%@",encoded];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    request.timeoutInterval=MIN(20,MAX(.1,attempt.deadline.timeIntervalSinceNow));
    request.cachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    request.HTTPShouldHandleCookies=NO;
    if (!get) {
        request.HTTPMethod=@"POST";
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody=[[@"input_protobuf_encoded=" stringByAppendingString:encoded] dataUsingEncoding:NSUTF8StringEncoding];
    }
    __block NSData *reply=nil;__block NSHTTPURLResponse *response=nil;__block NSError *failure=nil;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    NSURLSessionDataTask *task=[attempt.session dataTaskWithRequest:request completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) {
        reply=d;response=(NSHTTPURLResponse *)r;failure=e;dispatch_semaphore_signal(done);
    }];
    @synchronized(attempt) { if (attempt.cancelled) { [task cancel];if (error) *error=@"Sign-in cancelled.";return nil; }attempt.task=task;[task resume]; }
    while (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_MSEC*100))) {
        if (!Active(attempt,error)) { [task cancel];return nil; }
    }
    @synchronized(attempt) { if (attempt.task==task) attempt.task=nil; }
    if (!Active(attempt,error)) return nil;
    NSString *header=[response valueForHTTPHeaderField:@"x-eresult"];
    *eresult=header?header.intValue:(response.statusCode==200?1:0);
    if(*eresult!=1)fprintf(stderr,"AGEPAD_STEAM_AUTH_RESULT method=%s result=%d\n",method.UTF8String,*eresult);
    if (failure || response.statusCode!=200) {
        attempt.retryableFailure=(failure && [failure.domain isEqual:NSURLErrorDomain] &&
            (failure.code==NSURLErrorNetworkConnectionLost || failure.code==NSURLErrorTimedOut ||
             failure.code==NSURLErrorNotConnectedToInternet || failure.code==NSURLErrorCannotConnectToHost || failure.code==NSURLErrorDNSLookupFailed)) ||
            response.statusCode==429 || response.statusCode==500 || response.statusCode==502 || response.statusCode==503 || response.statusCode==504;
        fprintf(stderr,"AGEPAD_STEAM_AUTH_TRANSPORT method=%s http=%ld retryable=%d\n",method.UTF8String,(long)response.statusCode,attempt.retryableFailure);
        // Do not include URLSession's error text: it can contain the encoded
        // request URL, including an account name on the RSA-key GET endpoint.
        if (error) *error=failure?@"Couldn't reach Steam. Check the connection and try again.":[NSString stringWithFormat:@"Steam request failed (HTTP %ld, result %d).",(long)response.statusCode,*eresult];
        return nil;
    }
    if (reply.length>1024*1024) { if (error) *error=@"Steam returned an oversized sign-in response.";return nil; }
    NSDictionary *parsed=Parse(reply?:[NSData data]);
    if (!parsed && error) *error=@"Steam returned an invalid sign-in response.";
    return parsed;
}

static NSString *SteamIDFromToken(NSString *token) {
    NSArray *parts=[token componentsSeparatedByString:@"."];
    if (parts.count!=3 || token.length>32768) return nil;
    NSString *payload=[[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (payload.length%4) payload=[payload stringByAppendingString:@"="];
    NSData *json=[[NSData alloc] initWithBase64EncodedString:payload options:0];
    NSDictionary *claims=json?[NSJSONSerialization JSONObjectWithData:json options:0 error:nil]:nil;
    id subject=[claims isKindOfClass:NSDictionary.class]?claims[@"sub"]:nil;
    if (![subject isKindOfClass:NSString.class] || [subject length]!=17 ||
        [subject rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location!=NSNotFound ||
        !strtoull([subject UTF8String],NULL,10)) return nil;
    return subject;
}

// Waits for an approved auth session and returns its Steam-client token.
static NSDictionary *PollForToken(uint64_t clientID,NSData *requestID,double interval,AgePadSteamSignInRequest *attempt,
                                  NSString *challenge,AgePadSteamChallengeHandler onChallenge,NSString **error) {
    int eresult=0;unsigned failures=0;
    while (Active(attempt,error)) {
        if (!Pause(attempt,interval,error)) return nil;
        NSMutableData *poll=[NSMutableData data];
        PutInt(poll,1,clientID);PutBytes(poll,2,requestID);
        NSString *pollError=nil;
        NSDictionary *status=Call(@"PollAuthSessionStatus",poll,attempt,&eresult,&pollError);
        if (!status && attempt.retryableFailure && failures++<5 && Active(attempt,error)) {
            if(attempt.progress)attempt.progress(@"Reconnecting to Steam to finish approval…");
            if(!Pause(attempt,MIN(5,failures),error))return nil;
            continue; // Keep the approved session; never begin another QR here.
        }
        if (!status) { if (error) *error=pollError;return nil; }
        failures=0;
        if (eresult!=1) { if (error) *error=@"Steam declined or expired this sign-in. Try again.";return nil; }
        if (status[@1]) { uint64_t nextID=Integer(status[@1]);if (!nextID) { if (error) *error=@"Steam returned an invalid session identifier.";return nil; }clientID=nextID; }
        NSString *next=String(status[@2]);
        if (next.length && !AgePadSteamIsChallengeURL(next)) { if (error) *error=@"Steam returned an invalid sign-in link.";return nil; }
        if (onChallenge && next.length && ![next isEqualToString:challenge]) { challenge=next;onChallenge(challenge); }
        if(Integer(status[@5]) && attempt.progress)attempt.progress(@"Steam approval received. Finishing sign-in…");
        NSString *token=String(status[@3]);
        if (token.length) {
            NSString *account=String(status[@6])?:@"";
            NSString *steamID=SteamIDFromToken(token);
            if (!steamID) { if (error) *error=@"Steam token did not name an account";return nil; }
            return @{AgePadSteamRefreshToken:token,AgePadSteamAccountName:account,AgePadSteamID64:steamID};
        }
    }
    return nil;
}
static NSData *DeviceDetails(NSString *deviceName) {
    // k_EAuthTokenPlatformType_SteamClient = 1: the token audience Valve's client engine logs on with.
    NSMutableData *details=[NSMutableData data];
    PutString(details,1,deviceName);PutInt(details,2,1);
    return details;
}

NSDictionary *AgePadSteamQRSignIn(NSString *deviceName,NSTimeInterval timeout,AgePadSteamChallengeHandler onChallenge,NSString **error) {
    return AgePadSteamQRSignInWithRequest(deviceName,timeout,[AgePadSteamSignInRequest new],onChallenge,error);
}
NSDictionary *AgePadSteamQRSignInWithRequest(NSString *deviceName,NSTimeInterval timeout,AgePadSteamSignInRequest *attempt,AgePadSteamChallengeHandler onChallenge,NSString **error) {
    if (error) *error=nil;
    if (!isfinite(timeout) || timeout<=0 || timeout>600) { if (error) *error=@"Invalid sign-in timeout.";return nil; }
    attempt.deadline=[NSDate dateWithTimeIntervalSinceNow:timeout];
    NSMutableData *begin=[NSMutableData data];
    PutString(begin,1,deviceName);PutInt(begin,2,1);PutBytes(begin,3,DeviceDetails(deviceName));PutString(begin,4,@"Client");
    int eresult=0;
    NSDictionary *session=Call(@"BeginAuthSessionViaQR",begin,attempt,&eresult,error);
    if (!session || eresult!=1) { if (error && !*error) *error=[NSString stringWithFormat:@"BeginAuthSessionViaQR eresult %d",eresult];return nil; }
    uint64_t clientID=Integer(session[@1]);
    NSData *requestID=session[@3];
    NSString *challenge=String(session[@2]);
    if (!clientID || ![requestID isKindOfClass:NSData.class] || !requestID.length || !AgePadSteamIsChallengeURL(challenge)) { if (error) *error=@"Steam returned an incomplete QR session";return nil; }
    if (onChallenge) onChallenge(challenge);
    double interval=Number(session[@4]);
    return PollForToken(clientID,requestID,isfinite(interval)&&interval>0?MIN(30,MAX(1,interval)):5,attempt,challenge,onChallenge,error);
}

// DER RSAPublicKey { modulus, exponent } from Steam's hex strings.
static NSData *DERInteger(NSString *hex) {
    if (!hex.length || hex.length%2 || hex.length>16384 ||
        [hex rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet].location!=NSNotFound) return nil;
    NSMutableData *value=[NSMutableData data];
    for (NSUInteger i=0;i+1<hex.length;i+=2) { unsigned byte;sscanf([hex substringWithRange:NSMakeRange(i,2)].UTF8String,"%2x",&byte);uint8_t b=byte;[value appendBytes:&b length:1]; }
    while (value.length>1 && ((uint8_t *)value.bytes)[0]==0) [value replaceBytesInRange:NSMakeRange(0,1) withBytes:NULL length:0];
    if (value.length && ((uint8_t *)value.bytes)[0]&0x80) [value replaceBytesInRange:NSMakeRange(0,0) withBytes:"\0" length:1]; // stays positive
    return value;
}
static void PutDER(NSMutableData *out,uint8_t tag,NSData *content) {
    [out appendBytes:&tag length:1];
    NSUInteger length=content.length;
    if (length<128) { uint8_t b=length;[out appendBytes:&b length:1]; }
    else { uint8_t lengthBytes[4];int count=0;for (NSUInteger l=length;l;l>>=8) lengthBytes[count++]=l&0xff;
           uint8_t b=0x80|count;[out appendBytes:&b length:1];for (int i=count-1;i>=0;i--) [out appendBytes:&lengthBytes[i] length:1]; }
    [out appendData:content];
}

NSDictionary *AgePadSteamPasswordSignIn(NSString *accountName,NSString *password,NSString *deviceName,
        NSString *(^askCode)(int codeType),void (^waitingForApproval)(void),NSString **error) {
    return AgePadSteamPasswordSignInWithRequest(accountName,password,deviceName,[AgePadSteamSignInRequest new],askCode,waitingForApproval,error);
}
NSDictionary *AgePadSteamPasswordSignInWithRequest(NSString *accountName,NSString *password,NSString *deviceName,
        AgePadSteamSignInRequest *attempt,NSString *(^askCode)(int codeType),void (^waitingForApproval)(void),NSString **error) {
    if (error) *error=nil;
    attempt.deadline=[NSDate dateWithTimeIntervalSinceNow:300];
    if (!accountName.length || accountName.length>128 || !password.length || password.length>1024) {
        if (error) *error=@"Enter your Steam account name and password.";return nil;
    }
    int eresult=0;
    NSMutableData *keyRequest=[NSMutableData data];PutString(keyRequest,1,accountName);
    NSDictionary *rsa=Call(@"GetPasswordRSAPublicKey",keyRequest,attempt,&eresult,error);
    NSString *modulus=String(rsa[@1]),*exponent=String(rsa[@2]);
    NSData *n=DERInteger(modulus),*e=DERInteger(exponent);
    if (!rsa || eresult!=1 || !n || !e || !Integer(rsa[@3])) { if (error && !*error) *error=@"Steam didn't return its sign-in key";return nil; }
    NSMutableData *integers=[NSMutableData data],*der=[NSMutableData data];
    PutDER(integers,0x02,n);PutDER(integers,0x02,e);PutDER(der,0x30,integers);
    SecKeyRef key=SecKeyCreateWithData((__bridge CFDataRef)der,(__bridge CFDictionaryRef)@{
        (__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeRSA,(__bridge id)kSecAttrKeyClass:(__bridge id)kSecAttrKeyClassPublic},NULL);
    // The password exists only here, in memory, and only its encrypted form is sent.
    NSData *encrypted=key?(__bridge_transfer NSData *)SecKeyCreateEncryptedData(key,kSecKeyAlgorithmRSAEncryptionPKCS1,
        (__bridge CFDataRef)[password dataUsingEncoding:NSUTF8StringEncoding],NULL):nil;
    if (key) CFRelease(key);
    if (!encrypted) { if (error) *error=@"Couldn't encrypt the password with Steam's key";return nil; }
    NSMutableData *begin=[NSMutableData data];
    PutString(begin,1,deviceName);PutString(begin,2,accountName);
    PutString(begin,3,[encrypted base64EncodedStringWithOptions:0]);PutInt(begin,4,Integer(rsa[@3]));
    PutInt(begin,5,1);PutInt(begin,6,1);PutInt(begin,7,1);PutString(begin,8,@"Client");PutBytes(begin,9,DeviceDetails(deviceName));
    NSDictionary *session=Call(@"BeginAuthSessionViaCredentials",begin,attempt,&eresult,error);
    if (!session || eresult!=1) {
        if (error) *error=eresult==5?@"Wrong account name or password.":eresult==84?@"Too many attempts. Wait a while and try again.":
            (*error?:[NSString stringWithFormat:@"Steam refused the sign-in (error %d).",eresult]);
        return nil;
    }
    uint64_t clientID=Integer(session[@1]),steamID=Integer(session[@5]);
    NSData *requestID=session[@2];
    if (!clientID || !steamID || ![requestID isKindOfClass:NSData.class] || !requestID.length) {
        if (error) *error=@"Steam returned an incomplete sign-in session.";return nil;
    }
    // Steam Guard: 2 email code, 3 authenticator code, 4 approve in the Steam app, 1 none.
    int codeType=0;BOOL approval=NO;
    for (NSData *confirmation in session[@"*4"]) {
        if (![confirmation isKindOfClass:NSData.class]) { if (error) *error=@"Steam returned an invalid confirmation method.";return nil; }
        int type=(int)Integer(Parse(confirmation)[@1]);
        if ((type==3 || type==2) && !codeType) codeType=type;
        if (type==4) approval=YES;
    }
    // These are alternative confirmation methods. Never hold up approval
    // polling behind a code prompt just because Steam offered both methods.
    if (approval && (!attempt.prefersGuardCode || !codeType)) {
        if(waitingForApproval)waitingForApproval();
        codeType=0;
    }
    if (codeType) {
        NSString *code=askCode?askCode(codeType):nil;
        if (!Active(attempt,error)) return nil;
        if (!code.length) { if (error) *error=@"Sign-in cancelled.";return nil; }
        NSMutableData *update=[NSMutableData data];
        PutInt(update,1,clientID);
        PutVarint(update,2<<3|1);[update appendBytes:&steamID length:8]; // fixed64 steamid
        PutString(update,3,code);PutInt(update,4,codeType);
        if (!Call(@"UpdateAuthSessionWithSteamGuardCode",update,attempt,&eresult,error)) return nil;
        // Steam may have accepted mobile approval before this code arrived.
        // DuplicateRequest (29) still requires a genuine token on the next poll.
        if (eresult!=1 && eresult!=29) { if (error) *error=eresult==65?@"That Steam Guard code didn't work.":[NSString stringWithFormat:@"Steam Guard code rejected (error %d).",eresult];return nil; }
    }
    double interval=Number(session[@3]);
    return PollForToken(clientID,requestID,isfinite(interval)&&interval>0?MIN(30,MAX(1,interval)):5,attempt,nil,nil,error);
}

NSData *AgePadSteamQRPNG(NSString *challengeURL,CGFloat pixels) {
    if (!AgePadSteamIsChallengeURL(challengeURL) || !isfinite(pixels) || pixels<32 || pixels>4096) return nil;
    CIFilter *filter=[CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[challengeURL dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *code=filter.outputImage;
    if (!code) return nil;
    // Four-module white quiet zone so phone cameras lock on reliably.
    CGFloat modules=code.extent.size.width+8,scale=MAX(1,floor(pixels/modules));
    code=[code imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
    CGRect frame=CGRectInset(code.extent,-4*scale,-4*scale);
    code=[code imageByCompositingOverImage:[[CIImage imageWithColor:CIColor.whiteColor] imageByCroppingToRect:frame]];
    CGImageRef image=[[CIContext context] createCGImage:code fromRect:frame];
    if (!image) return nil;
    NSMutableData *png=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL);
    if (!destination) { CGImageRelease(image);return nil; }
    CGImageDestinationAddImage(destination,image,NULL);CGImageDestinationFinalize(destination);
    CFRelease(destination);CGImageRelease(image);
    return png;
}
