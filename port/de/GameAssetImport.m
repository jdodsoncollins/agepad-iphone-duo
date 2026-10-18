#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import "GameAssetStore.h"
#if __has_include("AgePadSteamRoute.h")
#import "SteamAssetDownload.h"
#endif

@interface AgePadGameAssetImportController : NSObject <UIDocumentPickerDelegate>
@property(nonatomic,strong) AgePadGameAssetStore *store;
@property(nonatomic,weak) UIViewController *host;
@property(nonatomic,strong) UILabel *state;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,copy) void (^changed)(BOOL,BOOL,NSString *);
@property(nonatomic) BOOL busy;
- (void)prepare;
- (void)chooseFolder;
@end
@implementation AgePadGameAssetImportController
- (void)work:(BOOL (^)(NSError **))job {
    if(self.busy)return;
    self.busy=YES;self.button.enabled=NO;
    if(self.changed)self.changed(NO,YES,self.state.text);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
            NSError *error=nil;BOOL ready=job(&error);
            fprintf(stderr,"AGEPAD_ASSET_READINESS ready=%d elapsed_ms=%.0f main_thread=%d\n",ready,1000*(CFAbsoluteTimeGetCurrent()-began),NSThread.isMainThread);
            dispatch_async(dispatch_get_main_queue(),^{
                self.busy=NO;self.button.enabled=YES;
                NSString *message=ready?[NSString stringWithFormat:@"Core game ready · %@",
                    [NSByteCountFormatter stringFromByteCount:(long long)self.store.requiredBytes countStyle:NSByteCountFormatterCountStyleFile]]:
                    error.localizedDescription?:@"Choose your game-data folder from Files.";
                self.state.text=message;if(self.changed)self.changed(ready,NO,message);
            });
        }
    });
}
- (void)report:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(),^{self.state.text=message;});
}
- (void)prepare {
    self.state.text=@"Checking the compact game install…";
    [self work:^BOOL(NSError **error) {
        return [self.store prepareExistingWithProgress:^(NSString *message){[self report:message];} error:error];
    }];
}
- (void)chooseFolder {
    if(self.busy || !self.host)return;
#if __has_include("AgePadSteamRoute.h")
    if(AgePadSteamAssetDownload.shared.busy)return;
#endif
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate=self;picker.allowsMultipleSelection=NO;
    [self.host presentViewController:picker animated:YES completion:nil];
}
- (void)downloadChanged:(NSNotification *)note {
#if __has_include("AgePadSteamRoute.h")
    self.button.enabled=!self.busy&&!AgePadSteamAssetDownload.shared.busy;
#endif
}
- (void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url=urls.firstObject;if(!url)return;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    self.state.text=@"Preparing Files import…";
    [self work:^BOOL(NSError **error) {
        __block BOOL ready=NO;__block NSError *failure=nil;NSError *coordination=nil;
        NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordination byAccessor:^(NSURL *folder) {
            ready=[self.store importFolder:folder progress:^(NSString *message){[self report:message];} error:&failure];
        }];
        if(scoped)[url stopAccessingSecurityScopedResource];
        if(!ready && error)*error=failure?:coordination;
        return ready;
    }];
}
@end

static UIView *AgePadGameAssetControls(UIViewController *host,AgePadGameAssetStore *store,void (^changed)(BOOL,BOOL,NSString *)) {
    AgePadGameAssetImportController *controller=[AgePadGameAssetImportController new];
    controller.host=host;controller.store=store;controller.changed=changed;
    UIStackView *panel=[UIStackView new];panel.axis=UILayoutConstraintAxisVertical;panel.spacing=10;
    controller.state=[UILabel new];controller.state.numberOfLines=0;controller.state.textColor=UIColor.whiteColor;
    controller.state.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    UIButtonConfiguration *style=UIButtonConfiguration.borderedButtonConfiguration;
    style.baseForegroundColor=[UIColor colorWithRed:.88 green:.71 blue:.40 alpha:1];style.title=@"Import game files from Files";
    controller.button=[UIButton buttonWithConfiguration:style primaryAction:nil];
#if __has_include("AgePadSteamRoute.h")
    [NSNotificationCenter.defaultCenter addObserver:controller selector:@selector(downloadChanged:) name:AgePadDownloadChanged object:AgePadSteamAssetDownload.shared];
#endif
    [controller.button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [controller.button addTarget:controller action:@selector(chooseFolder) forControlEvents:UIControlEventPrimaryActionTriggered];
    UILabel *help=[UILabel new];help.numberOfLines=0;help.textColor=[UIColor colorWithWhite:.8 alpha:1];
    help.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    help.text=@"Choose your AgeOfEmpires2Data folder in Files or iCloud Drive. Core matches install first; campaign presentation and extra modes are excluded from this compact pack. Saves and Steam sign-in are kept.";
    for(UIView *view in @[controller.state,controller.button,help])[panel addArrangedSubview:view];
    static char retainedController;
    objc_setAssociatedObject(panel,&retainedController,controller,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [controller prepare];return panel;
}
