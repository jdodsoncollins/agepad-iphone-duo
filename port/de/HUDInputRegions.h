// Private, opt-in touch ownership for one measured original-HUD layout.
// Regions are host-local UIKit points, never texture or JSON design pixels.
#pragma once
#import <UIKit/UIKit.h>
#import "DataDigest.h"
#include <sys/stat.h>
#include <math.h>

static inline NSString *DEHUDFileFingerprint(NSString *path) {
    struct stat s;
    if(!path.length || stat(path.fileSystemRepresentation,&s)!=0 || !S_ISREG(s.st_mode))return @"missing";
    return [NSString stringWithFormat:@"%llu:%llu:%lld:%lld:%ld:%lld:%ld",
        (unsigned long long)s.st_dev,(unsigned long long)s.st_ino,(long long)s.st_size,
        (long long)s.st_mtimespec.tv_sec,s.st_mtimespec.tv_nsec,
        (long long)s.st_ctimespec.tv_sec,s.st_ctimespec.tv_nsec];
}
static inline BOOL DEHUDNumber(id value,double *number) {
    if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return NO;
    double n=[value doubleValue];if(!isfinite(n))return NO;
    if(number)*number=n;return YES;
}
static inline NSData *DEHUDReadBounded(NSString *path,NSUInteger limit) {
    struct stat s;
    if(!path.length || stat(path.fileSystemRepresentation,&s)!=0 || !S_ISREG(s.st_mode) || s.st_size<=0 || (uint64_t)s.st_size>limit)return nil;
    NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    return data.length<=limit?data:nil;
}
static NSString *DEHUDInputRegionsCachedKey;
static NSArray<NSValue *> *DEHUDInputRegionsCachedRects;
static NSString *DEHUDInputRegionsCacheFiles;
static NSMutableDictionary<NSString *,NSArray<NSValue *> *> *DEHUDInputRegionsCache;
static NSMutableArray<NSString *> *DEHUDInputRegionsCacheOrder;
static inline NSArray<NSValue *> *DEHUDInputRegionsForBounds(CGRect bounds) {
    const char *configured=getenv("AGEPAD_HUD_INPUT_REGIONS");
    if(!configured || !*configured)return @[];
    NSString *manifest=[NSString stringWithUTF8String:configured];
    const char *rootValue=getenv("AGEPAD_CASE_INSENSITIVE_RESOURCE_ROOT");
    if(!rootValue || !*rootValue)rootValue=getenv("AGEPAD_DEVICE_DATA_ROOT");
    NSString *root=rootValue?[NSString stringWithUTF8String:rootValue]:nil;
    NSString *layout=[root stringByAppendingPathComponent:@"widgetui/commandpanel.json"];
    NSString *manifestStamp=DEHUDFileFingerprint(manifest),*layoutStamp=DEHUDFileFingerprint(layout);
    NSString *files=[NSString stringWithFormat:@"%@\n%@\n%@\n%@",manifest,layout,manifestStamp,layoutStamp];
    NSString *key=[files stringByAppendingFormat:@"\n%@",NSStringFromCGRect(bounds)];
    if(![DEHUDInputRegionsCacheFiles isEqual:files]) {
        DEHUDInputRegionsCacheFiles=files;
        DEHUDInputRegionsCache=[NSMutableDictionary new];DEHUDInputRegionsCacheOrder=[NSMutableArray new];
    }
    NSArray *hit=DEHUDInputRegionsCache[key];
    if(hit) {
        DEHUDInputRegionsCachedKey=key;DEHUDInputRegionsCachedRects=hit;
        [DEHUDInputRegionsCacheOrder removeObject:key];[DEHUDInputRegionsCacheOrder addObject:key];
        return hit;
    }
    DEHUDInputRegionsCachedKey=key;DEHUDInputRegionsCachedRects=@[];
    NSString *reason=nil;
    do {
        if(!manifest.isAbsolutePath || !root.isAbsolutePath){reason=@"invalid_utf8_or_nonabsolute_path";break;}
        if(!root.length){reason=@"missing_resource_root";break;}
        if(!CGRectEqualToRect(bounds,(CGRect){CGPointZero,bounds.size}) ||
           !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
           bounds.size.width<=0 || bounds.size.height<=0){reason=@"invalid_host_bounds";break;}
        NSData *bytes=DEHUDReadBounded(manifest,1024*1024);
        if(!bytes.length || bytes.length>1024*1024){reason=@"manifest_unreadable_or_too_large";break;}
        id value=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
        if(![value isKindOfClass:NSDictionary.class]){reason=@"manifest_not_object";break;}
        NSDictionary *document=value;double format;
        if(!DEHUDNumber(document[@"format"],&format) || format!=1 ||
           ![document[@"profile"] isEqual:@"mac-488492.107976-phone-grid-v1"]){reason=@"unsupported_format_or_profile";break;}
        id viewport=document[@"viewport"];double width,height;
        if(![viewport isKindOfClass:NSDictionary.class] || !DEHUDNumber(viewport[@"width"],&width) ||
           !DEHUDNumber(viewport[@"height"],&height) || width!=bounds.size.width || height!=bounds.size.height){reason=@"viewport_mismatch";break;}
        id expected=document[@"layout_sha256"];
        NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
        if(![expected isKindOfClass:NSString.class] || [expected length]!=64 ||
           [expected rangeOfCharacterFromSet:hex.invertedSet].location!=NSNotFound){reason=@"invalid_layout_sha256";break;}
        NSData *layoutBytes=DEHUDReadBounded(layout,16*1024*1024);
        if(!layoutBytes.length || layoutBytes.length>16*1024*1024){reason=@"layout_unreadable_or_too_large";break;}
        if(![AgePadSHA256(layoutBytes) isEqual:expected]){reason=@"layout_sha256_mismatch";break;}
        id regions=document[@"regions"];
        if(![regions isKindOfClass:NSArray.class] || ![regions count] || [regions count]>64){reason=@"invalid_regions";break;}
        NSMutableArray *rects=[NSMutableArray new];
        for(id region in regions) {
            double x,y,w,h;
            if(![region isKindOfClass:NSDictionary.class] || !DEHUDNumber(region[@"x"],&x) || !DEHUDNumber(region[@"y"],&y) ||
               !DEHUDNumber(region[@"width"],&w) || !DEHUDNumber(region[@"height"],&h) || w<=0 || h<=0 || !isfinite(x+w) || !isfinite(y+h) ||
               !CGRectContainsRect(bounds,CGRectMake(x,y,w,h))){reason=@"invalid_region_geometry";break;}
            NSValue *rect=[NSValue valueWithCGRect:CGRectMake(x,y,w,h)];if(![rects containsObject:rect])[rects addObject:rect];
        }
        if(reason)break;
        if(![manifestStamp isEqual:DEHUDFileFingerprint(manifest)] || ![layoutStamp isEqual:DEHUDFileFingerprint(layout)]){reason=@"files_changed_during_validation";break;}
        DEHUDInputRegionsCachedRects=[rects copy];
    }while(0);
    // Several original hosts can query different sizes in one run-loop turn.
    // Cache accepted and rejected bounds without repeatedly hashing the layout.
    while(DEHUDInputRegionsCacheOrder.count>=16) {
        [DEHUDInputRegionsCache removeObjectForKey:DEHUDInputRegionsCacheOrder.firstObject];
        [DEHUDInputRegionsCacheOrder removeObjectAtIndex:0];
    }
    DEHUDInputRegionsCache[key]=DEHUDInputRegionsCachedRects;[DEHUDInputRegionsCacheOrder addObject:key];
    fprintf(stderr,"DE_HUD_INPUT_REGIONS %s count=%lu reason=%s\n",reason?"rejected":"accepted",(unsigned long)DEHUDInputRegionsCachedRects.count,reason.UTF8String?:"verified_layout_and_viewport");
    return DEHUDInputRegionsCachedRects;
}
static inline NSString *DEHUDInputRegionsIdentityForBounds(CGRect bounds) {
    return DEHUDInputRegionsForBounds(bounds).count?DEHUDInputRegionsCachedKey:nil;
}
