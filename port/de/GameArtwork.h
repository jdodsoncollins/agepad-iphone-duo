#pragma once
#import <Foundation/Foundation.h>
static inline NSURL *AgePadGameArtworkURL(NSBundle *bundle) {
    // Bare imageNamed: names default to PNG. This bundled artwork is JPEG.
    return [bundle URLForResource:@"AoE2DEHeader" withExtension:@"jpg"];
}
