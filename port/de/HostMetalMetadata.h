// Desktop-only metadata for the Simulator's exact backing GPU. This does not
// change Metal capability queries or permit a different registry identity.
#pragma once
#import <Foundation/Foundation.h>

static inline NSDictionary *DEHostMetalMetadata(uint64_t registryID) {
    if (!registryID) return nil;
    const char *path=getenv("AGEPAD_HOST_METAL_METADATA");
    NSData *data=path?[NSData dataWithContentsOfFile:@(path)]:nil;
    id rows=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    if (![rows isKindOfClass:NSArray.class]) return nil;
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        id identity=row[@"registry_id"];
        if ([identity isKindOfClass:NSNumber.class] && [identity unsignedLongLongValue]==registryID) return row;
    }
    return nil;
}

static inline BOOL DEHostMetalUnifiedMemory(uint64_t registryID) {
    id unified=DEHostMetalMetadata(registryID)[@"unified"];
    return [unified isKindOfClass:NSNumber.class] && [unified boolValue];
}
