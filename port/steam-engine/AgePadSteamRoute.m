#import "AgePadSteamRoute.h"
#import <Security/Security.h>
#import <Network/Network.h>
#include "SteamEngineHost.h"
#import "SteamQRSignIn.h"
#import "SteamContentClient.h"

static NSString *const KeychainService=@"AgePad Steam sign-in";
static dispatch_queue_t EngineQueue(void) {
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("agepad.steam-engine",DISPATCH_QUEUE_SERIAL); });
    return queue;
}
// Whether the iPad has any usable network path right now (airplane mode: no).
static BOOL NetworkAvailable(void) {
    if (getenv("AGEPAD_TEST_OFFLINE")) return NO;
    __block BOOL available=YES;
    dispatch_semaphore_t known=dispatch_semaphore_create(0);
    nw_path_monitor_t monitor=nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0));
    nw_path_monitor_set_update_handler(monitor,^(nw_path_t path) {
        available=nw_path_get_status(path)==nw_path_status_satisfied;
        dispatch_semaphore_signal(known);
    });
    nw_path_monitor_start(monitor);
    dispatch_semaphore_wait(known,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
    nw_path_monitor_cancel(monitor);
    return available;
}
// Steam's own answer to this launch's sign-in, as its connection log records
// it ('OK', 'Revoked', 'Invalid Protocol', …), reading only what was written
// after `from`. Test switch: AGEPAD_TEST_LOGON_VERDICT (with Steam's Internet
// connections blocked by IPCSystemCompat) stands in for the server's answer.
static NSString *ConnectionLog(void) {
    return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject
        stringByAppendingPathComponent:@"Steam/logs/connection_log.txt"];
}
static unsigned long long ConnectionLogSize(void) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:ConnectionLog() error:nil] fileSize];
}
static NSString *LogOnVerdict(unsigned long long from) {
    if (getenv("AGEPAD_TEST_LOGON_VERDICT")) return @(getenv("AGEPAD_TEST_LOGON_VERDICT"));
    NSFileHandle *log=[NSFileHandle fileHandleForReadingAtPath:ConnectionLog()];
    if (!log) return nil;
    if (ConnectionLogSize()<from) from=0; // Steam started a new log
    [log seekToFileOffset:from];
    NSString *text=[[NSString alloc] initWithData:[log readDataToEndOfFile] encoding:NSUTF8StringEncoding]?:@"";
    [log closeFile];
    if ([text containsString:@"newer protocol version"]) return @"Invalid Protocol";
    NSString *verdict=nil;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSRange response=[line rangeOfString:@"RecvMsgClientLogOnResponse() : ["];
        if (response.location==NSNotFound) continue;
        NSRange open=[line rangeOfString:@"'" options:0 range:NSMakeRange(response.location,line.length-response.location)];
        NSRange close=[line rangeOfString:@"'" options:NSBackwardsSearch];
        if (open.location!=NSNotFound && close.location>open.location)
            verdict=[line substringWithRange:NSMakeRange(open.location+1,close.location-open.location-1)];
    }
    return verdict;
}
// Tells the in-app Steam engine that AoE II: DE is installed on this iPad (the
// build the imported files match; record baked in at build time), as Steam on
// the Mac knows. The install folder is a separate empty folder, never the game
// files, and updates are left to "launch through Steam", which AgePad never does.
static void InstallAppManifest(void) {
    NSString *record=[NSBundle.mainBundle pathForResource:@"SteamAppManifest_813780" ofType:@"acf"];
    if (!record) return;
    NSString *library=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject
        stringByAppendingPathComponent:@"Steam/steamapps"];
    NSFileManager *files=NSFileManager.defaultManager;
    [files createDirectoryAtPath:[library stringByAppendingPathComponent:@"common/AoE2DE"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *destination=[library stringByAppendingPathComponent:@"appmanifest_813780.acf"];
    NSData *wanted=[NSData dataWithContentsOfFile:record];
    // Test switch: record an older build, as after a game update AgePad does not have yet.
    if (getenv("AGEPAD_TEST_OLD_BUILD")) {
        NSString *text=[[NSString alloc] initWithData:wanted encoding:NSUTF8StringEncoding];
        NSRegularExpression *build=[NSRegularExpression regularExpressionWithPattern:@"(\"(?:buildid|TargetBuildID)\"\\s+\")\\d+" options:0 error:nil];
        text=[build stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"$1"
            @"25000000"];
        wanted=[text dataUsingEncoding:NSUTF8StringEncoding];
    }
    BOOL present=[[NSData dataWithContentsOfFile:destination] isEqualToData:wanted];
    if (!present) [wanted writeToFile:destination atomically:YES];
    fprintf(stderr,"AGEPAD_STEAM_APP_RECORD written=%d\n",!present);
}
// Steam's own view of the installed game, from the install record it maintains.
static NSDictionary<NSString *,NSString *> *AppRecordState(void) {
    NSString *path=[[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject
        stringByAppendingPathComponent:@"Steam/steamapps"] stringByAppendingPathComponent:@"appmanifest_813780.acf"];
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]?:@"";
    NSMutableDictionary *state=[NSMutableDictionary dictionary];
    for (NSString *key in @[@"buildid",@"TargetBuildID",@"StateFlags",@"UpdateResult"]) {
        NSRegularExpression *field=[NSRegularExpression regularExpressionWithPattern:
            [NSString stringWithFormat:@"\"%@\"\\s+\"([^\"]*)\"",key] options:0 error:nil];
        NSTextCheckingResult *match=[field firstMatchInString:text options:0 range:NSMakeRange(0,text.length)];
        if (match) state[key]=[text substringWithRange:[match rangeAtIndex:1]];
    }
    return state;
}
// The game's current public build as Valve's servers last told this iPad's
// Steam: appcache/appinfo.vdf (format 0x07564429: string table, binary
// key-values) → appinfo/depots/branches/public/buildid. 0 if unknown.
static long long PublicGameBuild(uint32_t app) {
    NSData *file=[NSData dataWithContentsOfFile:[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject
        stringByAppendingPathComponent:@"Steam/appcache/appinfo.vdf"] options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *d=file.bytes;size_t n=file.length;
    if (n<16 || *(const uint32_t *)d!=0x07564429) return 0;
    uint64_t table=*(const uint64_t *)(d+8);
    if (table+4>n) return 0;
    uint32_t count=*(const uint32_t *)(d+table);
    const char **strings=calloc(count,sizeof *strings);size_t p=table+4;
    for (uint32_t i=0;i<count && p<n;i++) { strings[i]=(const char *)d+p;const uint8_t *end=memchr(d+p,0,n-p);if (!end) break;p=end-d+1; }
    long long build=0;
    for (p=16;p+8<=table;) {
        uint32_t id=*(const uint32_t *)(d+p),size=*(const uint32_t *)(d+p+4);
        if (!id) break;
        if (id==app) {
            // Walk the key-values; remember the path of section names.
            const char *path[16];int depth=0;size_t q=p+8+4+4+8+20+4+20,stop=p+8+size;
            while (q<stop && q<n) {
                uint8_t type=d[q++];
                if (type==8) { if (--depth<0) break;continue; }
                if (q+4>n) break;
                int32_t key=*(const int32_t *)(d+q);q+=4;
                const char *name=key>=0 && (uint32_t)key<count?strings[key]:"";
                if (type==0) { if (depth<16) path[depth]=name;depth++;continue; }
                if (type==1) { const uint8_t *end=memchr(d+q,0,n-q);if (!end) break;q=end-d+1;continue; }
                if (type==7) { q+=8;continue; }
                if (type!=2) break;
                int32_t value=*(const int32_t *)(d+q);q+=4;
                if (depth==4 && !strcmp(name,"buildid") && !strcmp(path[1],"depots") && !strcmp(path[2],"branches") && !strcmp(path[3],"public"))
                    build=value;
            }
            break;
        }
        p+=8+size;
    }
    free(strings);
    return build;
}
static void LogAppRecordState(const char *when) {
    NSDictionary *state=AppRecordState();
    long long have=[state[@"buildid"] longLongValue],latest=PublicGameBuild(813780);
    fprintf(stderr,"AGEPAD_STEAM_APP_STATE when=%s buildid=%s public=%lld target=%s state_flags=%s update_result=%s\n",when,
        [state[@"buildid"] UTF8String]?:"-",latest,[state[@"TargetBuildID"] UTF8String]?:"-",
        [state[@"StateFlags"] UTF8String]?:"-",[state[@"UpdateResult"] UTF8String]?:"-");
    // Valve's public build is newer than the one on this iPad: remember it so
    // the next launch can say so even if this one has already started.
    if (have && latest>have) [NSUserDefaults.standardUserDefaults setObject:@(latest).stringValue forKey:@"AgePadNewerGameBuild"];
    else if (have && latest==have) [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AgePadNewerGameBuild"];
}
static NSString *GameUpdateNote(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:@"AgePadNewerGameBuild"]?
        @"Steam has a newer version of Age of Empires II than this iPad has. Single player and offline play work as usual; online matches need the update. Once AgePad supports that version, let Steam update the game on your Mac, then run  scripts/agepad-ipad.sh setup  with the iPad connected (or, if you installed from a release, inject the new release and copy the game folder again).":nil;
}

static NSString *AccountFile(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject
        stringByAppendingPathComponent:@"AgePadSteamAccount.env"];
}
static NSDictionary *KeychainQuery(NSString *account) {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:KeychainService,(__bridge id)kSecAttrAccount:account};
}
static BOOL SaveToken(NSString *account,NSString *token) {
    NSMutableDictionary *item=[KeychainQuery(account) mutableCopy];
    item[(__bridge id)kSecValueData]=[token dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    item[(__bridge id)kSecAttrSynchronizable]=@NO;
    OSStatus status=SecItemAdd((__bridge CFDictionaryRef)item,NULL);
    if (status==errSecDuplicateItem) status=SecItemUpdate((__bridge CFDictionaryRef)KeychainQuery(account),
        (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:item[(__bridge id)kSecValueData],
            (__bridge id)kSecAttrAccessible:item[(__bridge id)kSecAttrAccessible]});
    fprintf(stderr,"AGEPAD_STEAM_SIGNIN_SAVED keychain=%d\n",(int)status);
    return status==errSecSuccess;
}

@interface AgePadSteamSignInPanel : UIStackView
@property(nonatomic,copy) void (^signedIn)(void);
@property(nonatomic,strong) AgePadSteamSignInRequest *attempt;
@property(nonatomic,strong) UIImageView *code;
@property(nonatomic,strong) UIView *qrContainer;
@property(nonatomic,strong) UILabel *state;
@property(nonatomic,strong) UIButton *retry,*passwordButton;
@property(nonatomic) BOOL wasAttached,finished;
- (void)beginQR;
@end
static NSString *LoadToken(NSString *account) {
    NSMutableDictionary *query=[KeychainQuery(account) mutableCopy];
    query[(__bridge id)kSecReturnData]=@YES;
    CFTypeRef data=NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query,&data)!=errSecSuccess || !data) return nil;
    return [[NSString alloc] initWithData:(__bridge_transfer NSData *)data encoding:NSUTF8StringEncoding];
}

@implementation AgePadSteamRoute
+ (void)prepareContentDownload:(AgePadSteamContentClient *)client profile:(NSDictionary *)profile
    completion:(void (^)(NSDictionary *,NSError *))completion progress:(void (^)(NSString *))progress {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool {
        const char *savedID=getenv("AGEPAD_STEAM_ENGINE_ID");NSString *identity=savedID?@(savedID):@"";
        NSString *token=identity.length?LoadToken(identity):nil;NSError *error=nil;NSDictionary *plan=nil;
        if(!token.length||!AgePadEngineLoggedOn()||!AgePadEngineConnected()||!AgePadEngineOwnsApp(813780))
            error=[NSError errorWithDomain:@"AgePadSteamContent" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Connect to Steam online and verify your library before downloading."}];
        else {
            NSString *manifest=[NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"SteamAppManifest_813780" ofType:@"acf"] encoding:NSUTF8StringEncoding error:NULL];
            plan=[client prepareProfile:profile appManifest:manifest?:@"" token:token steamID:strtoull(identity.UTF8String,NULL,10) account:self.accountName progress:progress error:&error];
        }
        completion(plan,error);
    }});
}
+ (BOOL)hasAccount { return getenv("AGEPAD_STEAM_ENGINE_ID")!=NULL; }
+ (NSString *)accountName { const char *name=getenv("AGEPAD_STEAM_ENGINE_NAME");return name?@(name):@""; }
+ (void)forgetAccount {
    const char *steamID=getenv("AGEPAD_STEAM_ENGINE_ID");
    if (steamID) SecItemDelete((__bridge CFDictionaryRef)KeychainQuery(@(steamID)));
    [NSFileManager.defaultManager removeItemAtPath:AccountFile() error:nil];
    unsetenv("AGEPAD_STEAM_ENGINE_ID");unsetenv("AGEPAD_STEAM_ENGINE_NAME");
    [NSUserDefaults.standardUserDefaults setObject:@"Not signed in" forKey:@"AgePadSteamAccountName"];
}
+ (void)prepareWithClient:(void *)client {
    dispatch_async(EngineQueue(),^{
        InstallAppManifest();
        char error[160]={0};
        bool started=AgePadEngineStart(client,error,sizeof error);
        fprintf(stderr,"AGEPAD_ENGINE_PREPARED started=%d error=%s\n",started,started?"none":error);fflush(stderr);
        // Opt-in diagnostic: an anonymous Steam logon exercises the server
        // connection and logon message without any account.
        if (started && getenv("AGEPAD_ENGINE_ANON_TEST")) {
            int result=AgePadEngineLogOn(0x01A0000000000000ULL);
            for (int second=0;second<30;second+=2) {
                fprintf(stderr,"AGEPAD_ENGINE_ANON t=%d result=%d connected=%d logged_on=%d logon_state=%d\n",second,result,
                    AgePadEngineConnected(),AgePadEngineLoggedOn(),AgePadEngineLogonState());fflush(stderr);
                if (AgePadEngineLoggedOn()) break;
                sleep(2);
            }
            AgePadEngineLogOff();
        }
    });
}
+ (BOOL)saveSignIn:(NSDictionary *)signIn error:(NSString **)error {
    NSString *steamID=signIn[AgePadSteamID64],*name=signIn[AgePadSteamAccountName];
    if (!steamID.length || !name.length || name.length>128 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound ||
        [name containsString:@"\0"] || ![signIn[AgePadSteamRefreshToken] length]) {
        if (error) *error=@"Steam returned incomplete account details. Try signing in again.";return NO;
    }
    if (!SaveToken(steamID,signIn[AgePadSteamRefreshToken])) {
        if (error) *error=@"Couldn't save your Steam sign-in securely. Unlock this device and try again.";return NO;
    }
    NSString *file=[NSString stringWithFormat:@"AGEPAD_STEAM_ENGINE_ID=%@\nAGEPAD_STEAM_ENGINE_NAME=%@\n",steamID,name];
    if (![file writeToFile:AccountFile() atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        if (error) *error=@"Couldn't save the account record. Check free space and try again.";return NO;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
        ofItemAtPath:AccountFile() error:nil];
    setenv("AGEPAD_STEAM_ENGINE_ID",steamID.UTF8String,1);setenv("AGEPAD_STEAM_ENGINE_NAME",name.UTF8String,1);
    [NSUserDefaults.standardUserDefaults setObject:name forKey:@"AgePadSteamAccountName"];
    return YES;
}
+ (void)startWithClient:(void *)client path:(NSString *)clientPath lookUp:(AgePadBootstrapLookUp)lookUp
                 status:(void (^)(NSString *))status completion:(void (^)(NSString *))completion {
    NSString *steamID=@(getenv("AGEPAD_STEAM_ENGINE_ID")?:""),*name=[self accountName];
    void (^say)(NSString *)=^(NSString *message) { dispatch_async(dispatch_get_main_queue(),^{ status(message); }); };
    void (^finish)(NSString *)=^(NSString *error) { dispatch_async(dispatch_get_main_queue(),^{ completion(error); }); };
    dispatch_async(EngineQueue(),^{
        // The game's own Steam connection must reach this engine, not a Mac relay.
        for (NSString *key in @[@"AGEPAD_STEAM_TUNNEL_HOST",@"AGEPAD_HOST_PATH_RELAY_TCP_HOST",@"AGEPAD_STEAM_TUNNEL_PORT",
                @"AGEPAD_HOST_PATH_RELAY_TCP_PORT",@"AGEPAD_STEAM_LOOPBACK_PORT",@"AGEPAD_RELAY_TOKEN"]) unsetenv(key.UTF8String);
        char error[160]={0};
        InstallAppManifest();
        if (!AgePadEngineStart(client,error,sizeof error)) {
            fprintf(stderr,"AGEPAD_ENGINE_START_FAILED %s\n",error);
            finish([NSString stringWithFormat:@"Steam couldn't start inside AgePad (%s).",error]);return;
        }
        NSString *account=steamID,*token=LoadToken(account);
        // Opt-in diagnostic: attach the game to an anonymous engine session
        // (tests the ipcserver/game plumbing; the game is not licensed there).
        BOOL anonymous=getenv("AGEPAD_ENGINE_ANON_GAME")!=NULL;
        fprintf(stderr,"AGEPAD_ENGINE_STARTED saved_sign_in=%d anonymous_test=%d\n",token!=nil,anonymous);
        if (anonymous) { account=@"117093590311632896";token=nil; } // 0x01A0000000000000
        if (!token && !anonymous) { finish(@"Your Steam sign-in is missing on this iPad. Sign in again.");return; }
        if (token) AgePadEngineSetLoginToken(token.UTF8String,name.UTF8String);
        say([NSString stringWithFormat:@"Signing in to Steam as %@…",name]);
        // No network (airplane mode): Steam's own offline mode straight away.
        __block BOOL offline=!anonymous && !NetworkAvailable();
        if (offline) say(@"No Internet. Starting in Steam's offline mode (multiplayer is unavailable)…");
        unsigned long long logStart=ConnectionLogSize();
        NSString *verdict=nil;
        // Steam's offline mode applies to a logon in progress (it names the
        // account), so the normal logon always starts first.
        int result=AgePadEngineLogOn(strtoull(account.UTF8String,NULL,10));
        if (offline) { usleep(500000);result=AgePadEngineLogOnOffline(); }
        // In Steam's offline mode the account is never "logged on" (the real
        // client behaves the same); it is ready once Steam knows the account
        // and its cached licenses answer for the game.
        BOOL (^ready)(void)=^BOOL{
            return AgePadEngineLoggedOn() || (offline && AgePadEngineSteamID()!=0 && AgePadEngineOwnsApp(813780));
        };
        for (int tenth=0;tenth<600 && !ready();tenth++) {
            if (tenth%20==0) fprintf(stderr,"AGEPAD_ENGINE_STATE t=%d result=%d connected=%d logged_on=0 logon_state=%d offline=%d steam_id=%d owned=%d\n",
                tenth/10,result,AgePadEngineConnected(),AgePadEngineLogonState(),offline,AgePadEngineSteamID()!=0,AgePadEngineOwnsApp(813780));
            // The iPad has a network but Steam's servers cannot be reached for
            // 45 s: Steam's own offline mode (needs one earlier online sign-in).
            // Slow connections (15 s has been seen) stay online.
            if (tenth==450 && !offline && !AgePadEngineConnected()) {
                offline=YES;result=AgePadEngineLogOnOffline();
                say(@"Can't reach Steam. Starting in Steam's offline mode (multiplayer is unavailable)…");
            }
            // Steam answered the sign-in with something other than OK: stop waiting.
            if (!offline && tenth%10==5 && (verdict=LogOnVerdict(logStart)) && ![verdict isEqualToString:@"OK"]) break;
            usleep(100000);
        }
        // Steam turned the sign-in down. A withdrawn sign-in needs a new one; an
        // outdated Steam engine (or any other refusal) still plays offline.
        BOOL signInRefused=[@[@"Invalid Password",@"Access Denied",@"Expired",@"Revoked",@"Account Logon Denied",
                               @"Invalid Login Auth Code"] containsObject:verdict?:@""];
        BOOL outdated=[verdict isEqualToString:@"Invalid Protocol"];
        if (verdict && ![verdict isEqualToString:@"OK"]) fprintf(stderr,"AGEPAD_ENGINE_LOGON_REFUSED verdict=%s outdated=%d sign_in_refused=%d\n",
            verdict.UTF8String,outdated,signInRefused);
        if (signInRefused && !ready()) {
            finish(@"Steam no longer accepts this iPad's sign-in (it was signed out, expired or revoked). Sign in again.");return;
        }
        if (!ready() && !offline && !anonymous) {
            say(outdated?@"Steam has retired the version of Steam inside AgePad, so online play is off. To fix it, update Steam on your Mac and run  scripts/agepad-ipad.sh build  again (or, if you installed from a release, inject the latest release). Starting offline now…":
                [NSString stringWithFormat:@"Steam didn't accept the sign-in (%@). Starting in Steam's offline mode…",verdict?:@"no answer"]);
            offline=YES;result=AgePadEngineLogOnOffline();
            for (int tenth=0;tenth<150 && !ready();tenth++) usleep(100000);
            if (ready()) sleep(outdated?8:3); // leave the explanation on screen
        }
        BOOL loggedOn=AgePadEngineLoggedOn();
        fprintf(stderr,"AGEPAD_ENGINE_LOGON logged_on=%d offline=%d logon_state=%d ready=%d\n",loggedOn,offline,AgePadEngineLogonState(),ready());
        if (!ready()) {
            finish(offline?@"Steam couldn't start offline. Open AgePad once with Internet on this iPad; after that, offline mode works.":
                           @"Steam didn't finish signing in. Check the connection and try again.");return;
        }
        // The game may attach only once Steam has loaded this account's
        // licenses; wait for Steam's own ownership answer for AoE II: DE.
        BOOL owns=NO;
        for (int tenth=0;tenth<300 && !(owns=AgePadEngineOwnsApp(813780));tenth++) {
            if (tenth==10) say(@"Checking your Steam library…");
            usleep(100000);
        }
        fprintf(stderr,"AGEPAD_ENGINE_OWNERSHIP app=813780 owned=%d anonymous_test=%d can_logon_offline=%d\n",
            owns,anonymous,AgePadEngineCanLogOnOffline());
        if (!owns && !anonymous) {
            finish(@"Steam says this account doesn't own Age of Empires II: Definitive Edition (or couldn't confirm it yet). Check the account, then try again.");return;
        }
        kern_return_t registered=AgePadEngineRegister(clientPath.fileSystemRepresentation,lookUp);
        fprintf(stderr,"AGEPAD_ENGINE_REGISTERED status=%d\n",registered);
        if (!offline) LogAppRecordState("registered");
        NSString *updateNote=offline?nil:GameUpdateNote();
        if (updateNote && registered==KERN_SUCCESS) { say(updateNote);fprintf(stderr,"AGEPAD_GAME_UPDATE_NOTE shown=1\n");sleep(8); }
        if (!offline) for (int seconds=20;seconds<=120;seconds+=50)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)seconds*NSEC_PER_SEC),EngineQueue(),^{
                LogAppRecordState(seconds==20?"20s":seconds==70?"70s":"120s"); });
        finish(registered==KERN_SUCCESS?nil:@"Steam started, but the game couldn't be connected to it.");
    });
}
 + (UIView *)signInViewWithCompletion:(void (^)(void))signedIn {
    AgePadSteamSignInPanel *panel=[AgePadSteamSignInPanel new];
    panel.signedIn=signedIn;
    return panel;
}
@end

@implementation AgePadSteamSignInPanel
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self=[super initWithFrame:frame])) return nil;
    self.axis=UILayoutConstraintAxisVertical;self.spacing=14;self.alignment=UIStackViewAlignmentFill;
    UILabel *title=[UILabel new];title.text=@"Sign in to Steam";title.numberOfLines=0;
    title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];title.textColor=UIColor.whiteColor;
    UILabel *how=[UILabel new];how.numberOfLines=0;
    how.text=@"Sign in here, then confirm with Steam Guard. QR sign-in requires Steam Guard on another device.";
    how.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];how.textColor=[UIColor colorWithRed:.75 green:.81 blue:.84 alpha:1];
    self.code=[UIImageView new];self.code.backgroundColor=UIColor.whiteColor;
    self.code.contentMode=UIViewContentModeScaleAspectFit;
    [self.code setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.code setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    self.code.layer.magnificationFilter=kCAFilterNearest;self.code.translatesAutoresizingMaskIntoConstraints=NO;
    UIView *qr=[UIView new];self.qrContainer=qr;qr.hidden=YES;[qr addSubview:self.code];
    NSLayoutConstraint *preferred=[self.code.widthAnchor constraintEqualToConstant:240];preferred.priority=750;
    [NSLayoutConstraint activateConstraints:@[preferred,
        [self.code.widthAnchor constraintLessThanOrEqualToAnchor:qr.widthAnchor],
        [self.code.heightAnchor constraintEqualToAnchor:self.code.widthAnchor],
        [self.code.centerXAnchor constraintEqualToAnchor:qr.centerXAnchor],
        [self.code.topAnchor constraintEqualToAnchor:qr.topAnchor],
        [self.code.bottomAnchor constraintEqualToAnchor:qr.bottomAnchor]]];
    self.state=[UILabel new];self.state.numberOfLines=0;self.state.textColor=UIColor.whiteColor;
    self.state.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.state.accessibilityTraits|=UIAccessibilityTraitUpdatesFrequently;
    self.retry=[self button:@"Use QR on another device" action:@selector(beginQR)];
    self.passwordButton=[self button:@"Sign in with account name and password" action:@selector(passwordSignIn)];
    UIButtonConfiguration *primary=UIButtonConfiguration.filledButtonConfiguration;
    primary.title=@"Sign in with account name and password";
    primary.baseBackgroundColor=[UIColor colorWithRed:.88 green:.71 blue:.40 alpha:1];
    primary.baseForegroundColor=UIColor.blackColor;self.passwordButton.configuration=primary;
    for (UIView *view in @[title,how,self.passwordButton,self.retry,qr,self.state]) [self addArrangedSubview:view];
    return self;
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButtonConfiguration *style=UIButtonConfiguration.plainButtonConfiguration;
    style.baseForegroundColor=[UIColor colorWithRed:.88 green:.71 blue:.40 alpha:1];style.title=title;
    style.contentInsets=NSDirectionalEdgeInsetsMake(10,0,10,0);
    UIButton *button=[UIButton buttonWithConfiguration:style primaryAction:nil];
    button.titleLabel.numberOfLines=0;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];return button;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) self.wasAttached=YES;
    else if (self.wasAttached) {
        // A window/scene transition is not removal of this sign-in panel.
        // Defer one turn so UIStackView reparenting can finish as well.
        __weak typeof(self) weakSelf=self;
        dispatch_async(dispatch_get_main_queue(),^{
            AgePadSteamSignInPanel *panel=weakSelf;
            if(panel && AgePadSteamShouldCancelDetachedPanel(panel.wasAttached,panel.window!=nil,panel.superview!=nil)) {
                panel.finished=YES;[panel.attempt cancel];panel.attempt=nil;
                fprintf(stderr,"AGEPAD_STEAM_PANEL_REMOVED cancelled=1\n");
            }
        });
    }
}
- (void)dealloc { [_attempt cancel]; }
- (BOOL)accepts:(AgePadSteamSignInRequest *)attempt { return !self.finished && self.attempt==attempt && !attempt.cancelled; }
- (void)complete:(NSDictionary *)signIn error:(NSString *)error attempt:(AgePadSteamSignInRequest *)attempt {
    if (![self accepts:attempt]) return;
    fprintf(stderr,"AGEPAD_STEAM_AUTH_COMPLETE token_received=%d cancelled=%d\n",signIn!=nil,attempt.cancelled);
    if (signIn && [AgePadSteamRoute saveSignIn:signIn error:&error]) {
        self.finished=YES;[attempt cancel];self.code.image=nil;self.qrContainer.hidden=YES;
        self.passwordButton.enabled=NO;self.retry.enabled=NO;
        self.state.text=[NSString stringWithFormat:@"Signed in as %@.",signIn[AgePadSteamAccountName]];
        fprintf(stderr,"AGEPAD_STEAM_SIGNIN_OK\n");
        if (self.signedIn) self.signedIn();
    } else {
        self.code.image=nil;self.qrContainer.hidden=YES;
        self.passwordButton.enabled=YES;self.retry.enabled=YES;
        self.state.text=error?:@"Sign-in didn't finish. Choose a sign-in method to try again.";
    }
}
- (AgePadSteamSignInRequest *)newAttempt {
    [self.attempt cancel];self.attempt=[AgePadSteamSignInRequest new];
    AgePadSteamSignInRequest *attempt=self.attempt;
    __weak typeof(self) weakSelf=self;
    __weak AgePadSteamSignInRequest *weakAttempt=attempt;
    attempt.progress=^(NSString *message) { dispatch_async(dispatch_get_main_queue(),^{
        if([weakSelf accepts:weakAttempt])weakSelf.state.text=message;
    }); };
    self.code.image=nil;self.qrContainer.hidden=YES;return attempt;
}
- (void)beginQR {
    if (self.finished) return;
    AgePadSteamSignInRequest *attempt=[self newAttempt];
    UIButtonConfiguration *retryStyle=[self.retry.configuration copy];retryStyle.title=@"Get a new QR code";self.retry.configuration=retryStyle;
    self.state.text=@"Getting a sign-in code…";self.passwordButton.enabled=YES;self.retry.enabled=YES;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *error=nil;
        NSDictionary *signIn=AgePadSteamQRSignInWithRequest(@"AgePad (iOS)",600,attempt,^(NSString *challenge) {
            UIImage *image=[UIImage imageWithData:AgePadSteamQRPNG(challenge,600)];
            dispatch_async(dispatch_get_main_queue(),^{
                AgePadSteamSignInPanel *panel=weakSelf;if (![panel accepts:attempt]) return;
                panel.code.image=image;panel.qrContainer.hidden=image==nil;
                panel.state.text=@"Scan this code using Steam Guard on another device, then approve the request there.";
            });
        },&error);
        dispatch_async(dispatch_get_main_queue(),^{ [weakSelf complete:signIn error:error attempt:attempt]; });
    });
}
- (UIViewController *)presentingController {
    UIViewController *host=self.window.rootViewController;
    while (host.presentedViewController) host=host.presentedViewController;return host;
}
- (void)passwordSignIn {
    UIViewController *host=[self presentingController];if (!host || self.finished) return;
    [self.attempt cancel];self.attempt=nil;self.code.image=nil;self.qrContainer.hidden=YES;
    self.state.text=@"Enter your Steam account details in the sign-in form.";
    UIButtonConfiguration *retryStyle=[self.retry.configuration copy];retryStyle.title=@"Use QR on another device";self.retry.configuration=retryStyle;
    UIAlertController *form=[UIAlertController alertControllerWithTitle:@"Sign in to Steam"
        message:@"Your password is encrypted with Steam's key and sent only to Steam. AgePad doesn't save it." preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder=@"Steam account name";field.autocapitalizationType=UITextAutocapitalizationTypeNone;
        field.autocorrectionType=UITextAutocorrectionTypeNo;field.textContentType=UITextContentTypeUsername; }];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder=@"Password";field.secureTextEntry=YES;field.textContentType=UITextContentTypePassword; }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;__weak UIAlertController *weakForm=form;
    void (^submit)(BOOL)=^(BOOL prefersGuardCode) {
        AgePadSteamSignInPanel *panel=weakSelf;if (!panel || panel.finished) return;
        NSString *account=weakForm.textFields[0].text,*password=weakForm.textFields[1].text;
        weakForm.textFields[1].text=@"";
        AgePadSteamSignInRequest *attempt=[panel newAttempt];panel.passwordButton.enabled=NO;panel.retry.enabled=YES;
        attempt.prefersGuardCode=prefersGuardCode;
        panel.state.text=@"Signing in to Steam…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *error=nil;
            NSDictionary *signIn=AgePadSteamPasswordSignInWithRequest(account,password,@"AgePad (iOS)",attempt,^NSString *(int codeType) {
                __block NSString *entered=nil;dispatch_semaphore_t answered=dispatch_semaphore_create(0);
                __block UIAlertController *guard=nil;
                dispatch_async(dispatch_get_main_queue(),^{
                    AgePadSteamSignInPanel *current=weakSelf;
                    if (![current accepts:attempt]) { dispatch_semaphore_signal(answered);return; }
                    guard=[UIAlertController alertControllerWithTitle:@"Steam Guard code"
                        message:codeType==2?@"Enter the code Steam emailed you.":@"Enter the code from Steam Guard in the Steam app."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [guard addTextFieldWithConfigurationHandler:^(UITextField *field) {
                        field.autocapitalizationType=UITextAutocapitalizationTypeAllCharacters;field.textContentType=UITextContentTypeOneTimeCode; }];
                    __weak UIAlertController *weakGuard=guard;
                    [guard addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *c) { dispatch_semaphore_signal(answered); }]];
                    [guard addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *c) {
                        entered=weakGuard.textFields[0].text;dispatch_semaphore_signal(answered); }]];
                    [[current presentingController] presentViewController:guard animated:YES completion:nil];
                });
                NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:300];
                while (dispatch_semaphore_wait(answered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_MSEC*100))) {
                    if (attempt.cancelled || deadline.timeIntervalSinceNow<=0) {
                        dispatch_async(dispatch_get_main_queue(),^{ [guard dismissViewControllerAnimated:YES completion:nil]; });return nil;
                    }
                }
                return entered;
            },^{ dispatch_async(dispatch_get_main_queue(),^{
                if ([weakSelf accepts:attempt]) weakSelf.state.text=@"Approve the sign-in request in Steam Guard, then return to AgePad…";
            }); },&error);
            dispatch_async(dispatch_get_main_queue(),^{ [weakSelf complete:signIn error:error attempt:attempt]; });
        });
    };
    [form addAction:[UIAlertAction actionWithTitle:@"Sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { submit(NO); }]];
    [form addAction:[UIAlertAction actionWithTitle:@"Use Steam Guard code" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { submit(YES); }]];
    [host presentViewController:form animated:YES completion:nil];
}
@end
