"""Exercise the production downloader with local tasks and synthetic content."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="agepad-download-") as directory:
    folder = Path(directory)
    headers = folder / "UIKit"
    headers.mkdir()
    (headers / "UIKit.h").write_text("""#import <Foundation/Foundation.h>
@class UIView;
typedef NS_ENUM(NSInteger, UIApplicationState) {
    UIApplicationStateActive, UIApplicationStateInactive, UIApplicationStateBackground
};
@interface UIApplication : NSObject
@property(class, nonatomic, readonly) UIApplication *sharedApplication;
@property(nonatomic, readonly) UIApplicationState applicationState;
@end
FOUNDATION_EXPORT NSString *const UIApplicationDidBecomeActiveNotification;
FOUNDATION_EXPORT NSString *const UIApplicationDidEnterBackgroundNotification;
""")
    binary = folder / "download-test"
    subprocess.run([
        "xcrun", "clang", "-fobjc-arc", "-Wno-deprecated-declarations",
        "-I", str(folder), "-I", str(ROOT / "port/de"),
        "-I", str(ROOT / "port/steam-engine"),
        str(ROOT / "tests/steam_asset_download_test.m"),
        str(ROOT / "port/de/GameAssetStore.m"),
        str(ROOT / "port/third_party/zstd/zstddeclib.c"),
        "-llzma", "-lz", "-framework", "Foundation", "-framework", "Security",
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), str(folder)], check=True, timeout=90)
