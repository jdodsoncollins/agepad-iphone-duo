// Resolve packaged code through a signed, bundle-local image map. Development
// bundles without the map retain their original paths. This never maps assets,
// downloads or user-selected files into the native loader.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include <stdbool.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool DEImageRelativePathValid(const char *path) {
    if (!path || !*path || strlen(path) >= PATH_MAX || *path == '/') return false;
    const char *component = path;
    for (const char *p = path;; ++p) {
        unsigned char c = (unsigned char)*p;
        if (c == '/' || !c) {
            size_t length = (size_t)(p - component);
            if (!length || (length == 1 && component[0] == '.') ||
                (length == 2 && component[0] == '.' && component[1] == '.')) return false;
            if (!c) return true;
            component = p + 1;
        } else if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                     (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return false;
    }
}

static bool DEFrameworkImagePathValid(const char *path) {
    if (!DEImageRelativePathValid(path) || strncmp(path, "Frameworks/", 11)) return false;
    const char *name = path + 11, *slash = strchr(name, '/');
    if (!slash || strchr(slash + 1, '/')) return false;
    size_t length = (size_t)(slash - name);
    static const char suffix[] = ".framework";
    size_t suffixLength = sizeof(suffix) - 1;
    return length > suffixLength && !memcmp(slash - suffixLength, suffix, suffixLength) &&
        strlen(slash + 1) == length - suffixLength &&
        !memcmp(name, slash + 1, length - suffixLength);
}

// Exposed as a static helper so the real resolver is tested against synthetic
// bundles. Callers cannot supply this root through user configuration.
static bool DECopyBundleImagePathAtRoot(const char *root, const char *relative,
                                        char *output, size_t capacity) {
    if (!output || !capacity) return false;
    output[0] = 0;
    if (!root || !DEImageRelativePathValid(relative)) return false;
    char manifest[PATH_MAX];
    int n = snprintf(manifest, sizeof(manifest), "%s/AgePadLibraryMap.plist", root);
    if (n < 0 || (size_t)n >= sizeof(manifest)) return false;
    FILE *file = fopen(manifest, "rb");
    if (!file) {
        // Only absent maps use the development layout. Unreadable maps fail.
        if (errno != ENOENT) return false;
        n = snprintf(output, capacity, "%s/%s", root, relative);
        return n > 0 && (size_t)n < capacity;
    }
    unsigned char *bytes = malloc((1 << 20) + 1);
    if (!bytes) { fclose(file); return false; }
    size_t size = fread(bytes, 1, (1 << 20) + 1, file);
    bool readOK = !ferror(file) && size && size <= (1 << 20);
    fclose(file);
    CFDataRef data = readOK ? CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)size) : NULL;
    free(bytes);
    CFPropertyListRef map = data ? CFPropertyListCreateWithData(kCFAllocatorDefault, data,
        kCFPropertyListImmutable, NULL, NULL) : NULL;
    if (data) CFRelease(data);
    bool valid = map && CFGetTypeID(map) == CFDictionaryGetTypeID();
    CFIndex count = valid ? CFDictionaryGetCount((CFDictionaryRef)map) : 0;
    valid = valid && count > 0 && count <= 256;
    const void *keys[256], *values[256];
    if (valid) {
        CFDictionaryGetKeysAndValues((CFDictionaryRef)map, keys, values);
        for (CFIndex i = 0; i < count && valid; ++i) {
            char key[PATH_MAX], value[PATH_MAX];
            valid = CFGetTypeID(keys[i]) == CFStringGetTypeID() &&
                CFGetTypeID(values[i]) == CFStringGetTypeID() &&
                CFStringGetCString(keys[i], key, sizeof(key), kCFStringEncodingUTF8) &&
                CFStringGetCString(values[i], value, sizeof(value), kCFStringEncodingUTF8) &&
                CFStringGetLength(keys[i]) == (CFIndex)strlen(key) &&
                CFStringGetLength(values[i]) == (CFIndex)strlen(value) &&
                DEImageRelativePathValid(key) && DEFrameworkImagePathValid(value);
        }
    }
    CFStringRef key = valid ? CFStringCreateWithCString(kCFAllocatorDefault, relative,
                                                       kCFStringEncodingUTF8) : NULL;
    CFStringRef mapped = key ? CFDictionaryGetValue((CFDictionaryRef)map, key) : NULL;
    char destination[PATH_MAX];
    valid = mapped && CFStringGetCString(mapped, destination, sizeof(destination), kCFStringEncodingUTF8) &&
        CFStringGetLength(mapped) == (CFIndex)strlen(destination);
    if (key) CFRelease(key);
    if (map) CFRelease(map);
    if (!valid) return false;
    n = snprintf(output, capacity, "%s/%s", root, destination);
    if (n <= 0 || (size_t)n >= capacity) { output[0] = 0; return false; }
    // Framework layouts are flat; refuse a mapping escaping through symlinks.
    char actualRoot[PATH_MAX], actualImage[PATH_MAX];
    if (!realpath(root, actualRoot) || !realpath(output, actualImage)) { output[0] = 0; return false; }
    size_t rootLength = strlen(actualRoot);
    if (strncmp(actualImage, actualRoot, rootLength) || actualImage[rootLength] != '/') {
        output[0] = 0; return false;
    }
    return true;
}

static bool DECopyBundleImagePath(const char *relative, char *output, size_t capacity) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFURLRef url = bundle ? CFBundleCopyBundleURL(bundle) : NULL;
    char root[PATH_MAX];
    bool valid = url && CFURLGetFileSystemRepresentation(url, true, (UInt8 *)root, sizeof(root));
    if (url) CFRelease(url);
    return valid && DECopyBundleImagePathAtRoot(root, relative, output, capacity);
}

#ifdef __OBJC__
static NSString *DEBundleImagePath(NSString *relative) {
    char path[PATH_MAX];
    return DECopyBundleImagePath(relative.UTF8String, path, sizeof(path)) ? @(path) : nil;
}
#endif
