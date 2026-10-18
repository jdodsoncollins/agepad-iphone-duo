"""Run the production native-view installer against a strict Objective-C class.

No UIKit instances are used: the fixture models its class hierarchy and fatal
dynamic resolver, which are the runtime operations involved in this failure.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeViewLookupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='agepad-native-view-')
        folder = Path(cls.temporary.name)
        text = (ROOT / 'port/de/WindowViewCompat.m').read_text()
        start = text.index('static void DEUIKitWantsLayer(')
        end = text.index('\n@interface NSWindow', start)
        source = folder / 'lookup.m'
        source.write_text('''#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "UnsupportedBoundary.h"
#include "ExistingMethod.h"
@interface UIView : NSObject @end
@implementation UIView
+ (BOOL)resolveInstanceMethod:(SEL)selector {
    fprintf(stderr,"UNEXPECTED_RESOLVER %s\\n",sel_getName(selector));_exit(78);
}
@end
@interface CFeralNSWebView : UIView @end
@implementation CFeralNSWebView @end
static void ExistingSetter(id object,SEL selector,BOOL value) {}
''' + text[start:end] + '''
int main(int argc,char **argv) { @autoreleasepool {
    BOOL inherited=argc>1 && !strcmp(argv[1],"inherited");
    BOOL own=argc>1 && !strcmp(argv[1],"own");
    if(inherited || own)class_addMethod(inherited?UIView.class:CFeralNSWebView.class,
        @selector(setWantsLayer:),(IMP)ExistingSetter,"v@:B");
    DEInstallNativeViewCompatibility();
    Method method=class_getInstanceMethod(CFeralNSWebView.class,@selector(setWantsLayer:));
    if(!method)return 2;
    if((inherited || own) && method_getImplementation(method)!=(IMP)ExistingSetter)return 3;
    if(argc>1 && !strcmp(argv[1],"unsupported"))
        ((void (*)(id,SEL))objc_msgSend)([CFeralNSWebView new],sel_registerName("unsupportedDesktopMethod"));
    ((void (*)(id,SEL,BOOL))method_getImplementation(method))([CFeralNSWebView new],@selector(setWantsLayer:),YES);
    puts("native view metadata lookup passed");return 0;
} }
''')
        cls.binary = folder / 'lookup'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-DAGEPAD_PUBLIC_API=1',
                        '-I', str(ROOT / 'port/de'), str(source), '-framework',
                        'Foundation', '-o', str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_missing_optional_method_does_not_invoke_fatal_resolver(self):
        run = subprocess.run([str(self.binary)], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_existing_implementations_are_preserved(self):
        for scope in ('inherited', 'own'):
            with self.subTest(scope=scope):
                run = subprocess.run([str(self.binary), scope], capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stderr)

    def test_actual_unsupported_message_still_rejected(self):
        run = subprocess.run([str(self.binary), 'unsupported'], capture_output=True, text=True)
        self.assertEqual(run.returncode, 78)
        self.assertIn('UNEXPECTED_RESOLVER unsupportedDesktopMethod', run.stderr)


if __name__ == '__main__':
    unittest.main()
