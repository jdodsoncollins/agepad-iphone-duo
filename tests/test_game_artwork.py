"""Verify the production JPEG resource lookup and decoding without a Simulator."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='agepad-artwork-') as directory:
    folder = Path(directory)
    bundle = folder / 'Artwork.bundle'
    bundle.mkdir()
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.agepad.artwork-test', 'CFBundlePackageType': 'BNDL'}))
    source = folder / 'artwork.m'
    source.write_text('''#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "GameArtwork.h"
int main(int argc,char **argv){@autoreleasepool{
    NSURL *fixture=[NSURL fileURLWithPath:[@(argv[1]) stringByAppendingPathComponent:@"AoE2DEHeader.jpg"]];
    CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(NULL,64,32,8,0,colors,(CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(context,.7,.3,.1,1);CGContextFillRect(context,CGRectMake(0,0,64,32));
    CGImageRef synthetic=CGBitmapContextCreateImage(context);
    CGImageDestinationRef writer=CGImageDestinationCreateWithURL((__bridge CFURLRef)fixture,CFSTR("public.jpeg"),1,NULL);
    NSCAssert(writer && synthetic,@"synthetic JPEG fixture created");
    CGImageDestinationAddImage(writer,synthetic,NULL);NSCAssert(CGImageDestinationFinalize(writer),@"JPEG written");
    CFRelease(writer);CGImageRelease(synthetic);CGContextRelease(context);CGColorSpaceRelease(colors);
    NSBundle *bundle=[NSBundle bundleWithPath:@(argv[1])];
    NSURL *url=AgePadGameArtworkURL(bundle);
    NSCAssert([url.lastPathComponent isEqual:@"AoE2DEHeader.jpg"],@"exact JPEG resource found");
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,NULL):NULL;
    NSCAssert(image && CGImageGetWidth(image)==64 && CGImageGetHeight(image)==32,@"synthetic artwork decodes");
    if(image)CGImageRelease(image);if(source)CFRelease(source);
    NSCAssert(!AgePadGameArtworkURL([NSBundle bundleWithPath:@(argv[2])]),@"missing resource handled");
    puts("exact JPEG resource lookup, synthetic decoding and missing-artwork fallback passed");
}return 0;}
''')
    binary = folder / 'artwork'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-I', str(ROOT / 'port/de'),
                    str(source), '-framework', 'Foundation', '-framework', 'ImageIO',
                    '-framework', 'CoreGraphics', '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(bundle), str(folder / 'Missing.bundle')], check=True)
