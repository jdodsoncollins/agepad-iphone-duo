#pragma once
#include <objc/runtime.h>
#include <stdlib.h>

// Optional inspection must not ask a diagnostic class to resolve a missing
// selector. class_getInstanceMethod can run +resolveInstanceMethod:.
static inline Method DEExistingInstanceMethod(Class cls,SEL selector) {
    for(Class current=cls;current;current=class_getSuperclass(current)) {
        unsigned count=0;Method found=NULL;
        Method *methods=class_copyMethodList(current,&count);
        for(unsigned i=0;i<count;i++)if(sel_isEqual(method_getName(methods[i]),selector)) {
            found=methods[i];break;
        }
        free(methods);if(found)return found;
    }
    return NULL;
}
