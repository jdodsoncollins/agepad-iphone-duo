#pragma once
#import <Foundation/Foundation.h>

static inline void PutVarint(NSMutableData *out,uint64_t value) {
    do {
        uint8_t byte=value&0x7f;
        value>>=7;
        if(value)byte|=0x80;
        [out appendBytes:&byte length:1];
    } while(value);
}

static inline void PutInt(NSMutableData *out,int field,uint64_t value) {
    PutVarint(out,(uint64_t)field<<3);
    PutVarint(out,value);
}

static inline void PutBytes(NSMutableData *out,int field,NSData *value) {
    PutVarint(out,((uint64_t)field<<3)|2);
    PutVarint(out,value.length);
    [out appendData:value];
}

static inline void PutString(NSMutableData *out,int field,NSString *value) {
    PutBytes(out,field,[value dataUsingEncoding:NSUTF8StringEncoding]);
}

static inline BOOL GetVarint(const uint8_t *bytes,NSUInteger length,NSUInteger *at,uint64_t *value) {
    *value=0;
    for(int shift=0;*at<length&&shift<64;shift+=7) {
        uint8_t byte=bytes[(*at)++];
        if(shift==63&&byte>1)return NO;
        *value|=(uint64_t)(byte&0x7f)<<shift;
        if(!(byte&0x80))return YES;
    }
    return NO;
}
