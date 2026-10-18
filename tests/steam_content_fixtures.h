#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCryptor.h>

static NSData *encryptFixture(NSData *plain,NSData *key){
    uint8_t iv[16]={0};uint8_t encoded[16];size_t count=0;
    CCCrypt(kCCEncrypt,kCCAlgorithmAES,kCCOptionECBMode,key.bytes,key.length,NULL,iv,16,encoded,16,&count);
    NSMutableData *body=[NSMutableData dataWithLength:plain.length+16];CCCrypt(kCCEncrypt,kCCAlgorithmAES,kCCOptionPKCS7Padding,key.bytes,key.length,iv,plain.bytes,plain.length,body.mutableBytes,body.length,&count);body.length=count;
    NSMutableData *out=[NSMutableData dataWithBytes:encoded length:16];[out appendData:body];return out;
}
static NSData *storedZip(NSData *data){
    uint8_t header[30]={0x50,0x4b,3,4};uint32_t n=(uint32_t)data.length;memcpy(header+18,&n,4);memcpy(header+22,&n,4);header[26]=1;
    NSMutableData *out=[NSMutableData dataWithBytes:header length:30];[out appendBytes:"x" length:1];[out appendData:data];return out;
}
