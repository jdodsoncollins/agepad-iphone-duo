// Public-API builds skip the desktop launcher's UI through the game's own
// preferences. Its legacy WebKit class imports still need superclass bindings
// when the original image is loaded. Export AgePad classes under those import
// symbols in a dedicated boundary, rather than resolving iOS's private WebView.
// These classes deliberately stop if that unsupported desktop UI is requested.
// The game renderer and public WKWebView account surfaces remain independent.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include "UnsupportedBoundary.h"

@interface DEPublicDesktopWebView : UIView @end
@implementation DEPublicDesktopWebView
- (instancetype)initWithFrame:(CGRect)frame {
    DEUnsupported("public-API build unexpectedly requested the desktop web launcher");
}
- (instancetype)initWithFrame:(CGRect)frame frameName:(NSString *)name groupName:(NSString *)group {
    DEUnsupported("public-API build unexpectedly requested the desktop web launcher");
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    DEUnsupported("public-API build unexpectedly decoded the desktop web launcher");
}
+ (BOOL)resolveClassMethod:(SEL)selector {
    fprintf(stderr,"DE_UNSUPPORTED_SELECTOR +[%s %s]\n",class_getName(self),sel_getName(selector));
    DEUnsupported("public-API build requested an unsupported desktop WebView class method");
}
+ (BOOL)resolveInstanceMethod:(SEL)selector {
    fprintf(stderr,"DE_UNSUPPORTED_SELECTOR -[%s %s]\n",class_getName(self),sel_getName(selector));
    DEUnsupported("public-API build requested an unsupported desktop WebView method");
}
@end

DE_DIAGNOSTIC_CLASS(DEPublicDesktopWebScriptObject)
DE_DIAGNOSTIC_CLASS(DEPublicDesktopWebUndefined)
