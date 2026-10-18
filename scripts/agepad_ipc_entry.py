"""Validate the owned Steam helper's entry point before metadata adaptation.

Never execute an input image. Entry offsets are derived from LC_MAIN and pinned
to the supplied original plus its unchanged executable sections.
"""
import hashlib
import struct


def _name(raw):
    return raw.split(b'\0', 1)[0].decode('ascii')


def _image(raw, *, executable):
    if len(raw) < 32:
        raise ValueError('Truncated helper Mach-O header')
    magic, cpu, _, kind, count, command_bytes, _, _ = struct.unpack_from('<8I', raw)
    if magic != 0xfeedfacf or cpu != 0x100000c or kind != (2 if executable else 6):
        raise ValueError('Expected a thin arm64 helper ' + ('executable' if executable else 'dylib'))
    if count > 4096 or command_bytes > (1 << 20) or 32 + command_bytes > len(raw):
        raise ValueError('Invalid helper load-command bounds')
    text, entry, sections = None, None, []
    offset = 32
    for _ in range(count):
        if offset + 8 > 32 + command_bytes:
            raise ValueError('Truncated helper load command')
        command, size = struct.unpack_from('<II', raw, offset)
        if size < 8 or size % 4 or offset + size > 32 + command_bytes:
            raise ValueError('Invalid helper load command')
        if command == 0x80000028:
            if size != 24 or entry is not None:
                raise ValueError('Invalid or duplicate helper LC_MAIN')
            entry = struct.unpack_from('<Q', raw, offset + 8)[0]
        if command == 0x19:
            if size < 72:
                raise ValueError('Truncated helper segment')
            segment = _name(raw[offset + 8:offset + 24])
            vmaddr, vmsize, fileoff, filesize, _, initprot, nsects, _ = struct.unpack_from('<4Q4I', raw, offset + 24)
            if size != 72 + 80 * nsects or fileoff + filesize > len(raw):
                raise ValueError('Invalid helper segment bounds')
            if segment == '__TEXT':
                if text is not None or fileoff != 0 or not initprot & 4 or filesize < 32 + command_bytes:
                    raise ValueError('Helper __TEXT must uniquely contain the header and executable code')
                text = {'vmaddr': vmaddr, 'vmsize': vmsize, 'fileoff': fileoff, 'filesize': filesize}
            for index in range(nsects):
                start = offset + 72 + index * 80
                section = _name(raw[start:start + 16])
                declared_segment = _name(raw[start + 16:start + 32])
                addr, length, position = struct.unpack_from('<QQI', raw, start + 32)
                flags = struct.unpack_from('<I', raw, start + 64)[0]
                if declared_segment != segment:
                    raise ValueError('Helper section segment mismatch')
                if initprot & 4 and flags & 0xff not in (1, 12, 18) and length:
                    if (position < fileoff or position + length > fileoff + filesize or
                            addr < vmaddr or addr + length > vmaddr + vmsize or
                            addr - vmaddr != position - fileoff):
                        raise ValueError('Executable helper section is outside its segment or has inconsistent geometry')
                    sections.append({'segment': segment, 'section': section, 'address': addr,
                                     'file_offset': position, 'size': length})
        offset += size
    if offset != 32 + command_bytes or text is None:
        raise ValueError('Invalid helper command count or missing __TEXT')
    code = [section for section in sections if section['segment'] == '__TEXT' and section['section'] == '__text']
    if len(code) != 1:
        raise ValueError('Helper must contain exactly one executable __TEXT,__text section')
    digest = hashlib.sha256()
    for section in sections:
        digest.update(section['segment'].encode() + b'\0' + section['section'].encode() + b'\0')
        digest.update(struct.pack('<3Q', section['address'], section['file_offset'], section['size']))
        digest.update(raw[section['file_offset']:section['file_offset'] + section['size']])
    return text, code[0], entry, digest.hexdigest()


def derive_helper_entry(raw):
    text, code, entry, digest = _image(raw, executable=True)
    if entry is None or not entry or entry % 4 or not code['file_offset'] <= entry < code['file_offset'] + code['size']:
        raise ValueError('Aligned helper LC_MAIN entry must lie inside executable __TEXT,__text')
    if code['address'] + entry - code['file_offset'] != text['vmaddr'] + entry:
        raise ValueError('Helper entry is not relative to the mapped Mach-O header')
    return {'schema_version': 1, 'header_relative_entry': entry,
            'source_sha256': hashlib.sha256(raw).hexdigest(), 'executable_sections_sha256': digest,
            'entry_section': {'segment': '__TEXT', 'section': '__text',
                              'file_offset': code['file_offset'], 'size': code['size']}}


def validate_helper_entry(metadata, original, translated):
    integers = ('schema_version', 'header_relative_entry')
    bounds = metadata.get('entry_section', {}) if isinstance(metadata, dict) else {}
    if (not isinstance(metadata, dict) or any(type(metadata.get(key)) is not int for key in integers) or
            not isinstance(bounds, dict) or any(type(bounds.get(key)) is not int for key in ('file_offset', 'size')) or
            metadata != derive_helper_entry(original)):
        raise ValueError('Helper entry metadata does not match the exact original input')
    text, code, translated_entry, digest = _image(translated, executable=False)
    if translated_entry is not None:
        raise ValueError('Adapted helper must not retain an executable LC_MAIN')
    if digest != metadata['executable_sections_sha256']:
        raise ValueError('Adapted helper executable sections changed')
    entry = metadata['header_relative_entry']
    if (not code['file_offset'] <= entry < code['file_offset'] + code['size'] or
            code['address'] + entry - code['file_offset'] != text['vmaddr'] + entry):
        raise ValueError('Adapted helper entry geometry changed')
