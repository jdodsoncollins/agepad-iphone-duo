// Exercises the production HTTPS/protobuf sign-in code with a URLProtocol that
// never opens a socket. All names, tokens and account IDs below are synthetic.
#import <Foundation/Foundation.h>
#import "../port/steam-engine/SteamQRSignIn.m"

static NSMutableArray<NSDictionary *> *replies;
static NSMutableArray<NSURLRequest *> *requests;
static NSUInteger stops,passed;
@interface FixtureSteamProtocol : NSURLProtocol @end
@implementation FixtureSteamProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSDictionary *fixture=nil;
    @synchronized(FixtureSteamProtocol.class) {
        NSMutableURLRequest *record=[self.request mutableCopy];
        if (!record.HTTPBody && record.HTTPBodyStream) {
            NSMutableData *body=[NSMutableData data];NSInputStream *stream=record.HTTPBodyStream;[stream open];uint8_t bytes[4096];NSInteger n;
            while ((n=[stream read:bytes maxLength:sizeof bytes])>0) [body appendBytes:bytes length:n];[stream close];record.HTTPBody=body;
        }
        [requests addObject:record];
        NSCAssert(replies.count,@"Unexpected request: %@",self.request.URL.path);
        fixture=replies.firstObject;[replies removeObjectAtIndex:0];
    }
    if ([fixture[@"hang"] boolValue]) return;
    if (fixture[@"network_error"]) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:[fixture[@"network_error"] integerValue] userInfo:nil]];
        return;
    }
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:[fixture[@"http"] integerValue] HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"x-eresult":[fixture[@"result"] stringValue]}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:fixture[@"data"]];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading { @synchronized(FixtureSteamProtocol.class) { stops++; } }
@end
static void check(BOOL value,NSString *name) { NSCAssert(value,@"%@",name);passed++; }
static NSDictionary *reply(NSData *data,int result) { return @{@"data":data,@"result":@(result),@"http":@200}; }
static NSData *begin(void) {
    NSMutableData *data=[NSMutableData data];PutInt(data,1,42);PutString(data,2,@"https://s.team/q/1/fixture");
    PutBytes(data,3,[@"request-id" dataUsingEncoding:NSUTF8StringEncoding]);PutVarint(data,4<<3|5);float interval=1;[data appendBytes:&interval length:4];return data;
}
static NSString *fixtureToken(NSString *subject) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"sub":subject} options:0 error:nil];
    NSString *payload=[[[json base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [NSString stringWithFormat:@"fixture.%@.fixture",[payload stringByReplacingOccurrencesOfString:@"=" withString:@""]];
}
static NSData *success(void) {
    NSMutableData *data=[NSMutableData data];PutString(data,3,fixtureToken(@"76561198000000001"));PutString(data,6,@"fixture_account");return data;
}
static AgePadSteamSignInRequest *attempt(NSArray *fixtures) {
    replies=[fixtures mutableCopy];requests=[NSMutableArray new];stops=0;
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses=@[FixtureSteamProtocol.class];
    return [[AgePadSteamSignInRequest alloc] initWithSession:[NSURLSession sessionWithConfiguration:configuration]];
}
static NSDictionary *requestBody(NSURLRequest *request) {
    NSString *form=[[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
    NSString *encoded=[form substringFromIndex:[@"input_protobuf_encoded=" length]];
    return Parse([[NSData alloc] initWithBase64EncodedString:encoded.stringByRemovingPercentEncoding options:0]);
}
static NSData *derPart(NSData *data,NSUInteger *at,uint8_t tag) {
    const uint8_t *p=data.bytes;NSCAssert(*at+2<=data.length && p[(*at)++]==tag,@"Fixture DER tag");
    NSUInteger n=p[(*at)++];
    if (n&128) { NSUInteger count=n&127;n=0;while(count--) { NSCAssert(*at<data.length,@"Fixture DER length");n=n*256+p[(*at)++]; } }
    NSCAssert(n<=data.length-*at,@"Fixture DER extent");NSData *value=[data subdataWithRange:NSMakeRange(*at,n)];*at+=n;return value;
}
static NSString *hex(NSData *data) {
    NSMutableString *value=[NSMutableString new];const uint8_t *p=data.bytes;
    for (NSUInteger i=0;i<data.length;i++) [value appendFormat:@"%02x",p[i]];return value;
}
int main(void) { @autoreleasepool {
    check(!AgePadSteamShouldCancelDetachedPanel(YES,NO,YES),@"Temporary window loss keeps the Steam approval request alive");
    check(!AgePadSteamShouldCancelDetachedPanel(YES,YES,YES),@"Reattached sign-in panel retains its request");
    check(AgePadSteamShouldCancelDetachedPanel(YES,NO,NO),@"Removed sign-in panel cancels its request");
    NSString *error=nil;__block NSUInteger challenges=0;
    AgePadSteamSignInRequest *a=attempt(@[reply(begin(),1),reply(success(),1)]);
    NSDictionary *signedIn=AgePadSteamQRSignInWithRequest(@"AgePad fixture",10,a,^(NSString *url){challenges++;},&error);
    check(signedIn && !error && challenges==1,@"QR auth returns the approved account");
    check([signedIn[AgePadSteamAccountName] isEqual:@"fixture_account"] && [signedIn[AgePadSteamID64] isEqual:@"76561198000000001"],@"Token subject and name preserved");
    NSURLRequest *first=requests.firstObject;
    check([first.URL.host isEqual:@"api.steampowered.com"] && [first.URL.path isEqual:@"/IAuthenticationService/BeginAuthSessionViaQR/v1"] && [first.HTTPMethod isEqual:@"POST"],@"Real Valve QR endpoint and HTTP method");
    NSDictionary *body=requestBody(first);
    check([String(body[@1]) isEqual:@"AgePad fixture"] && Integer(body[@2])==1 && [String(body[@4]) isEqual:@"Client"] && Integer(Parse(body[@3])[@2])==1,@"Client platform and audience request");
    NSDictionary *poll=requestBody(requests.lastObject);
    check(Integer(poll[@1])==42 && [String(poll[@2]) isEqual:@"request-id"],@"Polling uses returned session credentials");
    check(!first.HTTPShouldHandleCookies && first.cachePolicy==NSURLRequestReloadIgnoringLocalCacheData,@"Auth bypasses cookies and URL cache");

    a=attempt(@[reply(begin(),1),@{@"network_error":@(NSURLErrorNetworkConnectionLost)},reply(success(),1)]);
    signedIn=AgePadSteamQRSignInWithRequest(@"AgePad fixture",15,a,nil,&error);
    check(signedIn && !error && requests.count==3,@"Steam approval survives a transient disconnect while switching apps");

    NSMutableData *rotate=[NSMutableData data];PutInt(rotate,1,43);PutString(rotate,2,@"https://s.team/q/1/rotated");
    a=attempt(@[reply(begin(),1),reply(rotate,1),reply(success(),1)]);challenges=0;
    signedIn=AgePadSteamQRSignInWithRequest(@"AgePad",15,a,^(NSString *url){challenges++;},&error);
    check(signedIn && challenges==2 && Integer(requestBody(requests.lastObject)[@1])==43,@"Rotating QR and client ID update");

    a=attempt(@[reply(begin(),1),reply(success(),15)]);
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",10,a,nil,&error) && [error containsString:@"declined"],@"Declined poll never returns a token");
    a=attempt(@[reply(begin(),15)]);
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",10,a,nil,&error) && error,@"Declined begin terminates");
    uint8_t malformed[]={0x08,0x80};a=attempt(@[reply([NSData dataWithBytes:malformed length:sizeof malformed],1)]);
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",10,a,nil,&error) && [error containsString:@"invalid"],@"Truncated protobuf fails closed");
    NSMutableData *wrong=[NSMutableData data];PutString(wrong,1,@"not-an-integer");PutString(wrong,2,@"https://s.team/q/1/fixture");PutString(wrong,3,@"request");
    a=attempt(@[reply(wrong,1)]);
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",10,a,nil,&error),@"Wrong wire types fail without exception");

    a=attempt(@[]);[a cancel];
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",10,a,nil,&error) && requests.count==0 && [error containsString:@"cancelled"],@"Cancelled attempt does not start HTTP");
    a=attempt(@[@{@"hang":@YES}]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_MSEC*100),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{ [a cancel]; });
    NSDate *start=NSDate.date;
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",10,a,nil,&error) && -start.timeIntervalSinceNow<1 && [error containsString:@"cancelled"],@"Cancellation bounds an in-flight request");
    a=attempt(@[@{@"hang":@YES}]);start=NSDate.date;
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",.2,a,nil,&error) && -start.timeIntervalSinceNow<1 && [error containsString:@"timed out"],@"Overall deadline bounds transport");
    a=attempt(@[]);
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",NAN,a,nil,&error) && !requests.count,@"Non-finite deadline rejected before HTTP");
    check(!AgePadSteamQRSignInWithRequest(@"AgePad",601,a,nil,&error) && !requests.count,@"Oversized timeout rejected before HTTP");

    check(AgePadSteamIsChallengeURL(@"https://s.team/q/1/fixture") && !AgePadSteamIsChallengeURL(@"http://s.team/q/x") &&
        !AgePadSteamIsChallengeURL(@"https://s.team.evil.example/q/x") && !AgePadSteamIsChallengeURL(@"https://user@s.team/q/x") &&
        !AgePadSteamIsChallengeURL(@"https://s.team:444/q/x") && !AgePadSteamIsChallengeURL(@"file:///q/x"),@"Only Valve HTTPS challenge URLs may open");
    check(!SteamIDFromToken(fixtureToken(@"bad\naccount")) && !SteamIDFromToken(@"not-a-token"),@"Malformed token subjects rejected");
    check(!AgePadSteamQRPNG(@"https://evil.example",600) && !AgePadSteamQRPNG(@"https://s.team/q/x",INFINITY),@"Invalid QR inputs do not render");
    check(AgePadSteamQRPNG(@"https://s.team/q/1/fixture",240).length>0,@"Real CoreImage QR rendering");
    a=attempt(@[]);
    check(!AgePadSteamPasswordSignInWithRequest(@"",@"password",@"AgePad",a,nil,nil,&error) && !requests.count,@"Empty account is validated without transport");
    NSMutableData *rsa=[NSMutableData data];PutString(rsa,1,@"not-hex");PutString(rsa,2,@"010001");PutInt(rsa,3,1);
    a=attempt(@[reply(rsa,1)]);
    check(!AgePadSteamPasswordSignInWithRequest(@"fixture_account",@"fixture_password",@"AgePad",a,nil,nil,&error),@"Invalid RSA material is rejected");
    check([requests.firstObject.HTTPMethod isEqual:@"GET"] && [requests.firstObject.URL.path containsString:@"GetPasswordRSAPublicKey"] && ![requests.firstObject.URL.absoluteString containsString:@"fixture_password"],@"Password never enters RSA-key request");

    // Ephemeral RSA key exists only for this fixture. Prove that the production
    // password path sends encrypted bytes and the expected Steam Guard request.
    SecKeyRef privateKey=SecKeyCreateRandomKey((__bridge CFDictionaryRef)@{
        (__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeRSA,(__bridge id)kSecAttrKeySizeInBits:@2048},NULL);
    SecKeyRef publicKey=SecKeyCopyPublicKey(privateKey);
    NSData *der=(__bridge_transfer NSData *)SecKeyCopyExternalRepresentation(publicKey,NULL);CFRelease(publicKey);
    NSUInteger at=0;NSData *sequence=derPart(der,&at,0x30);at=0;
    NSData *modulus=derPart(sequence,&at,0x02),*exponent=derPart(sequence,&at,0x02);
    rsa=[NSMutableData data];PutString(rsa,1,hex(modulus));PutString(rsa,2,hex(exponent));PutInt(rsa,3,1234);
    NSMutableData *credentials=[NSMutableData data],*confirmation=[NSMutableData data];
    PutInt(credentials,1,42);PutString(credentials,2,@"request-id");PutInt(credentials,5,76561198000000001ULL);
    PutInt(confirmation,1,3);PutBytes(credentials,4,confirmation);
    PutVarint(credentials,3<<3|5);float interval=1;[credentials appendBytes:&interval length:4];
    a=attempt(@[reply(rsa,1),reply(credentials,1),reply(NSData.data,1),reply(success(),1)]);
    __block int asked=0;
    signedIn=AgePadSteamPasswordSignInWithRequest(@"fixture_account",@"fixture_password",@"AgePad",a,^NSString *(int type) { asked=type;return @"ABC12"; },nil,&error);
    check(signedIn && asked==3 && requests.count==4,@"Real password and Steam Guard protocol completes");
    NSDictionary *sent=requestBody(requests[1]);
    NSData *encrypted=[[NSData alloc] initWithBase64EncodedString:String(sent[@3]) options:0];
    NSData *decrypted=(__bridge_transfer NSData *)SecKeyCreateDecryptedData(privateKey,kSecKeyAlgorithmRSAEncryptionPKCS1,(__bridge CFDataRef)encrypted,NULL);
    check([String(decrypted) isEqual:@"fixture_password"] && ![requests[1].HTTPBody rangeOfData:[@"fixture_password" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0,requests[1].HTTPBody.length)].length,@"Only Steam-key encrypted password is transmitted");
    NSDictionary *guard=requestBody(requests[2]);
    check(Integer(guard[@1])==42 && Integer(guard[@2])==76561198000000001ULL && [String(guard[@3]) isEqual:@"ABC12"] && Integer(guard[@4])==3,@"Guard update uses fixed64 account and requested code type");
    // Steam has already accepted mobile approval when the user submits a code.
    // Result 29 is DuplicateRequest; it must still poll for the real token.
    a=attempt(@[reply(rsa,1),reply(credentials,1),reply(NSData.data,29),reply(success(),1)]);
    signedIn=AgePadSteamPasswordSignInWithRequest(@"fixture_account",@"fixture_password",@"AgePad",a,^NSString *(int type) { return @"ABC12"; },nil,&error);
    check(signedIn && !error && requests.count==4,@"Mobile approval followed by Guard code (result 29) continues polling instead of reporting rejection");
    check([requests.lastObject.URL.path containsString:@"PollAuthSessionStatus"] &&
          Integer(requestBody(requests.lastObject)[@1])==42 && [String(requestBody(requests.lastObject)[@2]) isEqual:@"request-id"],
          @"Duplicate Guard submission retains the original approved session");
    a=attempt(@[reply(rsa,1),reply(credentials,1),reply(NSData.data,29),reply(NSData.data,15)]);
    check(!AgePadSteamPasswordSignInWithRequest(@"fixture_account",@"fixture_password",@"AgePad",a,^NSString *(int type) { return @"ABC12"; },nil,&error) &&
          requests.count==4 && [error containsString:@"declined"],@"DuplicateRequest alone never authenticates a player");
    for(NSNumber *result in @[@65,@88,@27,@15]) {
        a=attempt(@[reply(rsa,1),reply(credentials,1),reply(NSData.data,result.intValue)]);
        check(!AgePadSteamPasswordSignInWithRequest(@"fixture_account",@"fixture_password",@"AgePad",a,^NSString *(int type) { return @"ABC12"; },nil,&error) &&
              requests.count==3 && error.length,@"Rejected, expired or mismatched Guard codes still fail before polling");
    }
    NSMutableData *both=[credentials mutableCopy],*mobile=[NSMutableData data];
    PutInt(mobile,1,4);PutBytes(both,4,mobile);
    a=attempt(@[reply(rsa,1),reply(both,1),reply(success(),1)]);
    __block unsigned codePrompts=0,approvalPrompts=0;
    signedIn=AgePadSteamPasswordSignInWithRequest(@"fixture_account",@"fixture_password",@"AgePad",a,^NSString *(int type) {
        codePrompts++;return nil;
    },^{approvalPrompts++;},&error);
    check(signedIn && !error && codePrompts==0 && approvalPrompts==1 && requests.count==3,
          @"When Steam offers approval and a code, normal sign-in polls approval without blocking on a code prompt");
    a=attempt(@[reply(rsa,1),reply(both,1),reply(NSData.data,1),reply(success(),1)]);
    a.prefersGuardCode=YES;codePrompts=0;approvalPrompts=0;
    signedIn=AgePadSteamPasswordSignInWithRequest(@"fixture_account",@"fixture_password",@"AgePad",a,^NSString *(int type) {
        codePrompts++;return @"ABC12";
    },^{approvalPrompts++;},&error);
    check(signedIn && !error && codePrompts==1 && approvalPrompts==0 && requests.count==4,
          @"Explicit Guard-code sign-in keeps the alternative method available without requesting both");
    CFRelease(privateKey);
    NSLog(@"Steam auth: %lu production protocol checks passed; no network or real account used",(unsigned long)passed);
}return 0; }
