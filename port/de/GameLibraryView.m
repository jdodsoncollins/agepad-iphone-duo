#import <UIKit/UIKit.h>
#import "SteamAssetDownload.h"
#include "GameArtwork.h"

// Launch requires an explicit Play action.
@interface AgePadGameLibraryView : UIStackView
@property(nonatomic,strong) AgePadSteamAssetDownload *download;
@property(nonatomic,strong) UILabel *state,*detail;
@property(nonatomic,strong) UIButton *primary,*pauseButton,*cancelButton;
@property(nonatomic,strong) UIProgressView *progress;
@property(nonatomic,copy) void (^play)(void);
@property(nonatomic,copy) void (^installedChanged)(void);
@property(nonatomic) BOOL owned,installed,launching,checkingInstallation;
@property(nonatomic,copy) NSString *lastLoggedState;
@property(nonatomic) BOOL artworkAvailable;
- (instancetype)initWithStore:(AgePadGameAssetStore *)store;
- (void)refresh;
@end
@implementation AgePadGameLibraryView
- (UIButton *)action:(NSString *)title selector:(SEL)selector filled:(BOOL)filled {
    UIButtonConfiguration *c=filled?UIButtonConfiguration.filledButtonConfiguration:UIButtonConfiguration.plainButtonConfiguration;
    UIColor *gold=[UIColor colorWithRed:.88 green:.71 blue:.40 alpha:1];c.title=title;c.baseBackgroundColor=gold;c.baseForegroundColor=filled?UIColor.blackColor:gold;
    UIButton *b=[UIButton buttonWithConfiguration:c primaryAction:nil];[b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [b addTarget:self action:selector forControlEvents:UIControlEventPrimaryActionTriggered];return b;
}
- (instancetype)initWithStore:(AgePadGameAssetStore *)store {
    if(!(self=[super init]))return nil;self.axis=UILayoutConstraintAxisVertical;self.spacing=12;
    self.layoutMargins=UIEdgeInsetsMake(16,16,16,16);self.layoutMarginsRelativeArrangement=YES;
    self.backgroundColor=[UIColor colorWithRed:.15 green:.20 blue:.22 alpha:1];self.layer.cornerRadius=12;
    self.layer.borderWidth=1;self.layer.borderColor=[UIColor colorWithRed:.88 green:.71 blue:.40 alpha:.6].CGColor;
    UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.alignment=UIStackViewAlignmentCenter;row.spacing=16;
    UIImage *cover=[UIImage imageWithContentsOfFile:AgePadGameArtworkURL(NSBundle.mainBundle).path];
    self.artworkAvailable=cover!=nil;
    if(!cover)cover=[UIImage systemImageNamed:@"gamecontroller.fill"];
    UIImageView *art=[[UIImageView alloc] initWithImage:cover];art.contentMode=UIViewContentModeScaleAspectFit;art.clipsToBounds=YES;art.layer.cornerRadius=6;
    art.isAccessibilityElement=YES;art.accessibilityLabel=@"Age of Empires II: Definitive Edition cover";
    [art.widthAnchor constraintEqualToConstant:144].active=YES;[art.heightAnchor constraintEqualToConstant:68].active=YES;
    UIStackView *text=[UIStackView new];text.axis=UILayoutConstraintAxisVertical;text.spacing=6;
    UILabel *title=[UILabel new];title.text=@"Age of Empires II\nDefinitive Edition";title.numberOfLines=0;title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];title.textColor=UIColor.whiteColor;
    self.detail=[UILabel new];self.detail.numberOfLines=0;self.detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.detail.textColor=[UIColor colorWithWhite:.8 alpha:1];
    [text addArrangedSubview:title];[text addArrangedSubview:self.detail];
    self.primary=[self action:@"Download" selector:@selector(primaryTapped) filled:YES];[self.primary.widthAnchor constraintGreaterThanOrEqualToConstant:110].active=YES;
    [row addArrangedSubview:art];[row addArrangedSubview:text];[row addArrangedSubview:self.primary];[self addArrangedSubview:row];
    self.state=[UILabel new];self.state.numberOfLines=0;self.state.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.state.textColor=UIColor.whiteColor;self.state.accessibilityIdentifier=@"gameDownloadStatus";[self addArrangedSubview:self.state];
    self.progress=[UIProgressView new];self.progress.progressTintColor=[UIColor colorWithRed:.88 green:.71 blue:.40 alpha:1];self.progress.accessibilityLabel=@"Steam download progress";[self addArrangedSubview:self.progress];
    UIStackView *controls=[UIStackView new];controls.spacing=12;controls.axis=UILayoutConstraintAxisHorizontal;
    self.pauseButton=[self action:@"Pause" selector:@selector(pauseTapped) filled:NO];self.cancelButton=[self action:@"Cancel download" selector:@selector(cancelTapped) filled:NO];
    [controls addArrangedSubview:self.pauseButton];[controls addArrangedSubview:self.cancelButton];[self addArrangedSubview:controls];
    self.checkingInstallation=store!=nil;
    self.download=AgePadSteamAssetDownload.shared;[self.download configureStore:store];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(downloadChanged:) name:AgePadDownloadChanged object:self.download];self.hidden=YES;[self refresh];return self;
}
- (void)downloadChanged:(NSNotification *)note {
    if([self.download.snapshot[@"phase"] isEqual:@"ready"]&&!self.installed){self.installed=YES;if(self.installedChanged)self.installedChanged();}
    [self refresh];
}
- (void)refresh {
    self.hidden=NO;
    NSDictionary *s=self.download.snapshot;NSString *phase=s[@"phase"];
    BOOL working=[@[@"preparing",@"downloading",@"verifying"] containsObject:phase];
    BOOL retry=[@[@"paused",@"error"] containsObject:phase];
    NSString *detail=@"In your Steam library · 14.6 GB core pack";
    if(!self.owned)detail=@"Waiting for Steam library verification";
    else if(self.checkingInstallation)detail=@"In your Steam library · Checking files…";
    else if(self.installed)detail=@"In your Steam library · Installed";
    self.detail.text=detail;

    NSString *title=@"Download";
    if(!self.owned||self.checkingInstallation)title=@"Checking…";
    else if(self.launching)title=@"Starting…";
    else if(self.installed)title=@"Play";
    else if(retry)title=@"Resume";
    else if(working)title=@"Downloading…";
    UIButtonConfiguration *c=self.primary.configuration;
    c.title=title;
    self.primary.configuration=c;
    self.primary.enabled=self.owned&&!self.checkingInstallation&&!self.launching&&!working;
    self.progress.hidden=!working&&!retry;self.progress.progress=[s[@"progress"] floatValue];
    self.pauseButton.hidden=!working||[phase isEqual:@"verifying"];self.cancelButton.hidden=!working&&!retry;
    NSString *message=self.installed?@"Core game ready · 14.6 GB":s[@"message"];
    if(self.checkingInstallation)message=@"Checking installed game files…";
    if([phase isEqual:@"preparing"])message=[NSString stringWithFormat:@"%@\nKeep AgePad open until the download starts.",s[@"message"]];
    if([phase isEqual:@"downloading"]&&[s[@"total"] longLongValue]>0){NSString *have=[NSByteCountFormatter stringFromByteCount:[s[@"received"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];NSString *total=[NSByteCountFormatter stringFromByteCount:[s[@"total"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
        message=[NSString stringWithFormat:@"Downloading · %.0f%% · %@ of %@\nWi-Fi download continues in the background. Open AgePad to finish verification.",[s[@"progress"] doubleValue]*100,have,total];}
    self.state.text=self.launching?@"Starting Age of Empires II…":message;
    NSString *marker=[NSString stringWithFormat:@"owned=%d installed=%d checking=%d launching=%d artwork=%d",self.owned,self.installed,self.checkingInstallation,self.launching,self.artworkAvailable];
    if(![marker isEqual:self.lastLoggedState]){self.lastLoggedState=marker;fprintf(stderr,"AGEPAD_LIBRARY_CARD %s\n",marker.UTF8String);}
}
- (void)primaryTapped {if(self.installed){if(self.play)self.play();return;}NSString *phase=self.download.snapshot[@"phase"];if([@[@"paused",@"error"] containsObject:phase])[self.download resume];else[self.download start];}
- (void)pauseTapped{[self.download pause];}
- (void)cancelTapped{[self.download cancel];}
- (void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];}
@end
