#include "IPCHelperEntryPoint.h"
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    struct mach_header_64 header;
    struct segment_command_64 segment;
    struct section_64 section;
} Image;

static Image image(void) {
    Image i = {0};
    i.header.magic = MH_MAGIC_64; i.header.cputype = CPU_TYPE_ARM64;
    i.header.filetype = MH_DYLIB; i.header.ncmds = 1;
    i.header.sizeofcmds = sizeof(i.segment) + sizeof(i.section);
    i.segment.cmd = LC_SEGMENT_64; i.segment.cmdsize = i.header.sizeofcmds;
    strcpy(i.segment.segname, "__TEXT"); i.segment.vmaddr = 0x100000000;
    i.segment.vmsize = i.segment.filesize = 0x4000;
    i.segment.initprot = VM_PROT_READ | VM_PROT_EXECUTE; i.segment.nsects = 1;
    strcpy(i.section.segname, "__TEXT"); strcpy(i.section.sectname, "__text");
    i.section.offset = 0x1000; i.section.addr = i.segment.vmaddr + i.section.offset;
    i.section.size = 0x2000; i.section.flags = S_ATTR_PURE_INSTRUCTIONS;
    return i;
}

static unsigned checks;
static void check(int passed) { ++checks; if (!passed) { fprintf(stderr, "check %u failed\n", checks); exit(1); } }
static void *entry(Image *i, uint64_t offset) {
    return DEIPCEntryAddress((const void *)&i->header, offset, 0x1000, 0x2000);
}
int main(void) {
    Image i = image();
    check(entry(&i, 0x1fd8) == (void *)((uintptr_t)&i + 0x1fd8));
    check(entry(&i, 0x1000) != NULL); check(entry(&i, 0x2ffc) != NULL);
    check(!entry(&i, 0)); check(!entry(&i, 0x1fd9)); check(!entry(&i, 0xffc)); check(!entry(&i, 0x3000));
    check(!DEIPCEntryAddress(NULL, 0x1fd8, 0x1000, 0x2000));
    check(!DEIPCEntryAddress((const void *)&i, 0x1fd8, 0x1004, 0x2000));
    check(!DEIPCEntryAddress((const void *)&i, 0x1fd8, 0x1000, 0x2004));
    i.header.magic = MH_CIGAM_64; check(!entry(&i, 0x1fd8)); i = image();
    i.header.cputype = CPU_TYPE_X86_64; check(!entry(&i, 0x1fd8)); i = image();
    i.header.sizeofcmds -= 8; check(!entry(&i, 0x1fd8)); i = image();
    i.segment.cmdsize = 0; check(!entry(&i, 0x1fd8)); i = image();
    i.segment.cmdsize -= 1; check(!entry(&i, 0x1fd8)); i = image();
    i.segment.nsects = 2; check(!entry(&i, 0x1fd8)); i = image();
    i.segment.initprot = VM_PROT_READ; check(!entry(&i, 0x1fd8)); i = image();
    i.segment.fileoff = 0x1000; check(!entry(&i, 0x1fd8)); i = image();
    i.section.addr += 4; check(!entry(&i, 0x1fd8)); i = image();
    i.section.flags = 0; check(!entry(&i, 0x1fd8)); i = image();
    i.segment.filesize = 0x2000; check(!entry(&i, 0x1fd8)); i = image();
    i.segment.vmsize = 0x2000; check(!entry(&i, 0x1fd8)); i = image();
    i.header.ncmds = 4097; check(!entry(&i, 0x1fd8)); i = image();
    i.header.sizeofcmds = (1u << 20) + 1; check(!entry(&i, 0x1fd8));
    printf("%u loaded-helper entry checks passed\n", checks);
    return 0;
}
