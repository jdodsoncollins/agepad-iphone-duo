// The in-iPad Steam route: Valve's engine inside AgePad, a one-time QR
// sign-in, and a saved sign-in (token in this iPad's Keychain; the account
// ID and name in Documents/AgePadSteamAccount.env). No password is handled.
#import <UIKit/UIKit.h>
#include <mach/mach.h>

typedef kern_return_t (*AgePadBootstrapLookUp)(mach_port_t,const char *,mach_port_t *);
@class AgePadSteamContentClient;

@interface AgePadSteamRoute : NSObject
+ (BOOL)hasAccount;
+ (NSString *)accountName;
+ (void)forgetAccount;
// Starts Valve's engine early (signed out) so it is warm by the time the
// sign-in finishes. Engine work runs on one serial queue.
+ (void)prepareWithClient:(void *)clientImage;
// Starts Valve's engine, signs in with the saved sign-in (Steam's offline mode
// when there is no connection) and registers with the in-app ipcserver.
// status and completion run on the main queue; error is nil when the game may start.
+ (void)startWithClient:(void *)clientImage path:(NSString *)clientPath lookUp:(AgePadBootstrapLookUp)lookUp
                 status:(void (^)(NSString *message))status completion:(void (^)(NSString *error))completion;
// QR sign-in panel. signedIn runs on the main queue once the account is saved.
+ (UIView *)signInViewWithCompletion:(void (^)(void))signedIn;
// Separately authorizes asset downloads. This does not launch the game or
// expose the saved Steam token to the UI/download journal.
+ (void)prepareContentDownload:(AgePadSteamContentClient *)client profile:(NSDictionary *)profile
    completion:(void (^)(NSDictionary *plan,NSError *error))completion progress:(void (^)(NSString *))progress;
@end
