#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>

// Match agepad-kit.py's section digest across re-signing.
static inline NSString *DESteamModuleSectionsDigest(NSString *path) {
    NSData *file=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *d=file.bytes;size_t n=file.length;
    if (n<32 || *(const uint32_t *)d!=0xfeedfacf) return nil;
    uint32_t count=*(const uint32_t *)(d+16);size_t offset=32;
    CC_SHA256_CTX context;CC_SHA256_Init(&context);
    for (uint32_t i=0;i<count && offset+8<=n;i++) {
        uint32_t cmd=*(const uint32_t *)(d+offset),size=*(const uint32_t *)(d+offset+4);
        if (cmd==0x19 && offset+72<=n) {
            uint32_t sections=*(const uint32_t *)(d+offset+64);
            for (uint32_t s=0;s<sections && offset+72+80*(s+1)<=n;s++) {
                const uint8_t *section=d+offset+72+80*s;
                uint32_t type=*(const uint32_t *)(section+64)&SECTION_TYPE;
                if(type==S_ZEROFILL || type==S_GB_ZEROFILL || type==S_THREAD_LOCAL_ZEROFILL)continue;
                uint64_t length=*(const uint64_t *)(section+40);uint32_t start=*(const uint32_t *)(section+48);
                if (start && start+length<=n) CC_SHA256_Update(&context,d+start,(CC_LONG)length);
            }
        }
        if (!size) return nil;
        offset+=size;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);
    NSMutableString *text=[NSMutableString stringWithCapacity:64];
    for (unsigned i=0;i<sizeof(digest);i++) [text appendFormat:@"%02x",digest[i]];
    return text;
}
