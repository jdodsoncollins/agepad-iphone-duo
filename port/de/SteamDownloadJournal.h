#pragma once
#import <Foundation/Foundation.h>
#import "SteamContentClient.h"

static BOOL AgePadDownloadPathInside(NSString *root,NSString *path) {
    return [path.stringByResolvingSymlinksInPath hasPrefix:[root.stringByResolvingSymlinksInPath stringByAppendingString:@"/"]];
}

static NSMutableSet<NSNumber *> *AgePadCompletedRecords(NSData *records,NSUInteger count) {
    NSMutableSet *completed=[NSMutableSet new];
    if(records.length>400000)return completed;
    const uint8_t *b=records.bytes;
    for(NSUInteger p=0;p+4<=records.length;p+=4){uint32_t i;memcpy(&i,b+p,4);i=CFSwapInt32LittleToHost(i);if(i<count)[completed addObject:@(i)];}
    return completed; // A torn trailing record is deliberately ignored.
}

// Validate disk state against the signed asset inventory before any restored
// task can write a byte. A journal cannot expand the allowed file set.
static BOOL AgePadValidDownloadJournal(NSDictionary *journal,NSDictionary *profile,NSString *profileHash,NSDictionary *keys) {
    NSArray *jobs=journal[@"jobs"];
    if(![journal[@"profile"] isEqual:profileHash]||![jobs isKindOfClass:NSArray.class]||jobs.count>100000||
       ![journal[@"completed"] isKindOfClass:NSArray.class]||![journal[@"authorizations"] isKindOfClass:NSDictionary.class])return NO;
    NSMutableDictionary *expected=[NSMutableDictionary new];
    for(NSDictionary *entry in profile[@"entries"])expected[entry[@"path"]]=entry[@"bytes"];
    uint64_t total=0;NSMutableDictionary *ends=[NSMutableDictionary new];
    for(id value in jobs){
        if(![value isKindOfClass:NSDictionary.class])return NO;NSDictionary *job=value;NSString *path=job[@"path"];
        if(![path isKindOfClass:NSString.class]||![job[@"depot"] isKindOfClass:NSNumber.class])return NO;
        for(NSString *field in @[@"offset",@"length",@"compressed",@"checksum"])if(![job[field] isKindOfClass:NSNumber.class]||[job[field] longLongValue]<0)return NO;
        uint64_t offset=[job[@"offset"] unsignedLongLongValue],length=[job[@"length"] unsignedLongLongValue],compressed=[job[@"compressed"] unsignedLongLongValue];
        NSString *sha=job[@"sha"],*depot=[job[@"depot"] stringValue];NSDictionary *auth=journal[@"authorizations"][depot];
        if(![auth isKindOfClass:NSDictionary.class]||![auth[@"host"] isKindOfClass:NSString.class]||![auth[@"suffix"] isKindOfClass:NSString.class]||
           !expected[path]||offset!=[ends[path] unsignedLongLongValue]||!length||length>(4<<20)||compressed<32||compressed>(8<<20)||offset+length<offset||offset+length>[expected[path] unsignedLongLongValue]||
           ![sha isKindOfClass:NSString.class]||sha.length!=40||[sha rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound||
           !AgePadSteamContentHost(auth[@"host"])||![keys[depot] isKindOfClass:NSData.class]||[keys[depot] length]!=32)return NO;
        ends[path]=@(offset+length);total+=compressed;
    }
    for(NSString *path in expected)if([ends[path] unsignedLongLongValue]!=[expected[path] unsignedLongLongValue])return NO;
    for(id i in journal[@"completed"])if(![i isKindOfClass:NSNumber.class]||[i longLongValue]<0||[i unsignedIntegerValue]>=jobs.count)return NO;
    return total==[journal[@"total"] unsignedLongLongValue];
}
