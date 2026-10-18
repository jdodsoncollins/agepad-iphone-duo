#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

static inline NSString *AgePadSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString stringWithCapacity:64];
    for(NSUInteger i=0;i<sizeof digest;i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}
