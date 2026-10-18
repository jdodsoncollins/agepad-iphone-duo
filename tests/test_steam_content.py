"""Real native depot decoding and recovery validation; no account/network."""
from pathlib import Path
import ctypes
import lzma
import struct
import subprocess
import tempfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='agepad-content-') as directory:
    folder = Path(directory)
    plain = b'AgePad integrity test\0' * 1024
    (folder / 'plain').write_bytes(plain)
    with zipfile.ZipFile(folder / 'zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('chunk', plain)
    alone = lzma.compress(plain, format=lzma.FORMAT_ALONE)
    crc = struct.pack('<I', zlib.crc32(plain))
    (folder / 'vzip').write_bytes(b'VZa' + crc + alone[:5] + alone[13:] + crc + struct.pack('<I', len(plain)) + b'zv')
    # Test fixture generation uses the host compressor. Production bundles only
    # the pinned BSD decoder; no host library is copied into the app.
    library = ctypes.CDLL('/opt/homebrew/lib/libzstd.dylib')
    library.ZSTD_compress.restype = ctypes.c_size_t
    library.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    output = ctypes.create_string_buffer(len(plain) * 2)
    n = library.ZSTD_compress(output, len(output), plain, len(plain), 1)
    (folder / 'zstd').write_bytes(b'VSZa' + crc + output.raw[:n] + crc + struct.pack('<I', len(plain)) + b'\0' * 4 + b'zsv')
    binary = folder / 'content-test'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wno-deprecated-declarations',
                    '-I', str(ROOT / 'port/de'), '-I', str(ROOT / 'port/steam-engine'),
                    '-I', str(ROOT / 'port/third_party/xz/include'),
                    str(ROOT / 'tests/steam_content_test.m'),
                    str(ROOT / 'port/third_party/zstd/zstddeclib.c'), '-llzma', '-lz',
                    '-framework', 'Foundation', '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder)], check=True, timeout=30)
