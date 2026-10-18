#import <Foundation/Foundation.h>
#include "HostMetalMetadata.h"
#include <assert.h>

int main(void) { @autoreleasepool {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    setenv("AGEPAD_HOST_METAL_METADATA",path.fileSystemRepresentation,1);
    NSArray *rows=@[@"not a device",@{@"registry_id":@42,@"unified":@YES},
                    @{@"registry_id":@43,@"unified":@NO},
                    @{@"registry_id":@44,@"unified":@"true"},@{@"registry_id":@45}];
    [[NSJSONSerialization dataWithJSONObject:rows options:0 error:NULL] writeToFile:path atomically:YES];
    assert(DEHostMetalUnifiedMemory(42));
    assert(!DEHostMetalUnifiedMemory(43));
    assert(!DEHostMetalUnifiedMemory(44));
    assert(!DEHostMetalUnifiedMemory(45));
    assert(!DEHostMetalUnifiedMemory(99));
    assert(!DEHostMetalUnifiedMemory(0));
    [@"{}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    assert(!DEHostMetalUnifiedMemory(42));
    [@"invalid JSON" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    assert(!DEHostMetalUnifiedMemory(42));
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    assert(!DEHostMetalUnifiedMemory(42));
    unsetenv("AGEPAD_HOST_METAL_METADATA");
    assert(!DEHostMetalUnifiedMemory(42));
    puts("PASS: backing-GPU metadata requires exact identity and a typed unified-memory value; unavailable/malformed surveys fail closed");
} return 0; }
