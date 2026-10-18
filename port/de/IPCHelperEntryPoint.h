#pragma once
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <mach/vm_prot.h>
#include <stdint.h>
#include <string.h>

// The helper's signed metadata is derived from its original LC_MAIN. Check
// that it still describes the loaded, unchanged executable section. A helper
// update must never reuse an entry address from a different Steam build.
static void *DEIPCEntryAddress(const struct mach_header *generic, uint64_t entry,
                               uint64_t textOffset, uint64_t textSize) {
    if (!generic || generic->magic != MH_MAGIC_64 || generic->cputype != CPU_TYPE_ARM64 ||
        !entry || (entry & 3) || !textSize) return NULL;
    const struct mach_header_64 *header = (const void *)generic;
    if (header->ncmds > 4096 || header->sizeofcmds > (1u << 20)) return NULL;
    const unsigned char *cursor = (const void *)(header + 1);
    size_t remaining = header->sizeofcmds;
    void *address = NULL;
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (remaining < sizeof(struct load_command)) return NULL;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > remaining ||
            (command->cmdsize & 7)) return NULL;
        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(struct segment_command_64)) return NULL;
            const struct segment_command_64 *segment = (const void *)command;
            if (segment->nsects > (command->cmdsize - sizeof(*segment)) / sizeof(struct section_64)) return NULL;
            if (!strncmp(segment->segname, "__TEXT", sizeof(segment->segname))) {
                if (segment->fileoff || !(segment->initprot & VM_PROT_EXECUTE)) return NULL;
                const struct section_64 *sections = (const void *)(segment + 1);
                for (uint32_t j = 0; j < segment->nsects; ++j) {
                    const struct section_64 *section = &sections[j];
                    if (strncmp(section->sectname, "__text", sizeof(section->sectname)) ||
                        strncmp(section->segname, "__TEXT", sizeof(section->segname))) continue;
                    if (address || section->offset != textOffset || section->size != textSize ||
                        section->addr < segment->vmaddr || section->addr - segment->vmaddr != textOffset ||
                        !(section->flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)) ||
                        textOffset > segment->filesize || textSize > segment->filesize - textOffset ||
                        textOffset > segment->vmsize || textSize > segment->vmsize - textOffset ||
                        entry < textOffset || entry - textOffset > textSize ||
                        textSize - (entry - textOffset) < 4 || UINTPTR_MAX - (uintptr_t)header < entry) return NULL;
                    address = (void *)((uintptr_t)header + entry);
                }
            }
        }
        cursor += command->cmdsize;
        remaining -= command->cmdsize;
    }
    return remaining ? NULL : address;
}
