"""Build the actual standalone probe from synthetic resources; never launch it."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from agepad_distribution import macho_metadata


def braced_expression(source, start):
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class LoaderProbeBuildTests(unittest.TestCase):
    def test_paired_launch_after_async_asset_readiness(self):
        source = (ROOT / 'port/de/LoaderProbe.m').read_text()
        callback = braced_expression(source, source.index('^(BOOL ready,BOOL busy,NSString *message)'))
        guard = ''
        marker = '__block BOOL pairedGameStarted'
        if marker in source:
            guard = braced_expression(source, source.index(marker)) + ';'
        self.assertIn('if (startPairedGame()) return YES;', source)
        fixture = r'''
#import <Foundation/Foundation.h>
@interface TestLibrary : NSObject
@property BOOL checkingInstallation,installed;
- (void)refresh;
@end
@implementation TestLibrary
- (void)refresh{}
@end
@interface TestSetupView : NSObject
@property NSUInteger removals;
- (void)removeFromSuperview;
@end
@implementation TestSetupView
- (void)removeFromSuperview{self.removals++;}
@end
@interface AgePadSteamAssetDownload : NSObject
+ (instancetype)shared;
- (void)configureStore:(id)store;
@end
@implementation AgePadSteamAssetDownload
+ (instancetype)shared{return nil;}
- (void)configureStore:(id)store{}
@end
static void scenario(BOOL engineRoute,BOOL steamInitialized,BOOL runOriginal,BOOL failFirst){
    if(runOriginal)setenv("AGEPAD_DEVICE_RUN_ORIGINAL","1",1);else unsetenv("AGEPAD_DEVICE_RUN_ORIGINAL");
    __block BOOL hasData=NO;__block NSUInteger starts=0;
    BOOL (^startGame)(void)=^BOOL{starts++;return !failFirst||starts>1;};
    __LAUNCH_GUARD__
    TestLibrary *library=[TestLibrary new];id assetStore=nil;
    TestSetupView *scroll=[TestSetupView new];
    __weak TestSetupView *setupScroll=scroll;
    void (^ready)(BOOL,BOOL,NSString *)=__READY_CALLBACK__;
    startPairedGame();
    ready(NO,YES,@"Checking files");
    if(!library.checkingInstallation||library.installed||hasData){fprintf(stderr,"Initial checking state did not reach the library\n");exit(1);}
    ready(NO,NO,@"Files needed");
    if(library.checkingInstallation||library.installed||hasData){fprintf(stderr,"Checking completion did not reach the library\n");exit(1);}
    ready(YES,YES,@"Importing replacement");
    if(!library.checkingInstallation||!library.installed||hasData){fprintf(stderr,"Import busy state did not suspend readiness\n");exit(1);}
    if(starts){fprintf(stderr,"Launched before assets were ready\n");exit(1);}
    ready(YES,NO,@"Ready");ready(YES,NO,@"Ready again");
    ready(NO,YES,@"Rechecking");
    if(!library.checkingInstallation||hasData){fprintf(stderr,"Later import did not mark the library busy\n");exit(1);}
    ready(YES,NO,@"Ready");
    NSUInteger expected=!engineRoute&&steamInitialized&&runOriginal?(failFirst?2:1):0;
    if(starts!=expected){fprintf(stderr,"Paired readiness launch: expected %lu, got %lu (engine=%d steam=%d run=%d retry=%d)\n",(unsigned long)expected,(unsigned long)starts,engineRoute,steamInitialized,runOriginal,failFirst);exit(1);}
    if(scroll.removals!=(expected?1:0)){fprintf(stderr,"Setup view was removed without one successful paired launch\n");exit(1);}
    if(!hasData||!library.installed||library.checkingInstallation){fprintf(stderr,"Readiness UI did not update\n");exit(1);}
}
int main(void){@autoreleasepool{
    for(int engine=0;engine<2;engine++)for(int steam=0;steam<2;steam++)for(int run=0;run<2;run++)for(int retry=0;retry<2;retry++)scenario(engine,steam,run,retry);
    puts("16 production readiness-callback launch scenarios passed");
}return 0;}
'''.replace('__LAUNCH_GUARD__', guard).replace('__READY_CALLBACK__', callback)
        with tempfile.TemporaryDirectory(prefix='agepad-loader-ready-') as directory:
            folder = Path(directory)
            native = folder / 'readiness.m'
            binary = folder / 'readiness'
            native.write_text(fixture)
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-DAGEPAD_ENGINE_ROUTE=1',
                            str(native), '-framework', 'Foundation', '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_standalone_probe_links_its_importer(self):
        with tempfile.TemporaryDirectory(prefix='agepad-loader-probe-') as directory:
            root = Path(directory)
            game, output = root / 'Fixture.app', root / 'Probe.app'
            executable = game / 'Contents/MacOS/Age Of Empires II'
            shader = game / 'Contents/Resources/feral.metallib'
            executable.parent.mkdir(parents=True)
            shader.parent.mkdir(parents=True)
            executable.write_bytes(b'AgePad non-executable test fixture\n')
            shader.write_bytes(b'AgePad shader test fixture\n')
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/build-de-loader-probe.py'),
                                     str(game), str(output)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = macho_metadata((output / 'DELoaderProbe').read_bytes())
            self.assertEqual((metadata['platform'], metadata['file_type']), (7, 2))
            self.assertTrue(any('/UniformTypeIdentifiers.framework/' in name
                                for name in metadata['dependencies']))
            info = plistlib.loads((output / 'Info.plist').read_bytes())
            self.assertEqual(info['CFBundleExecutable'], 'DELoaderProbe')
            self.assertEqual(info['UIDeviceFamily'], [1, 2])
            self.assertEqual((output / 'OriginalEngine').read_bytes(), executable.read_bytes())
            self.assertEqual((output / 'feral.metallib').read_bytes(), shader.read_bytes())


if __name__ == '__main__':
    unittest.main()
