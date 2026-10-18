# Steam asset decoding dependencies

`zstd/zstddeclib.c` is the standalone decoder generated from the official
[Zstandard v1.5.7 release](https://github.com/facebook/zstd/tree/v1.5.7)
using its `build/single_file_libs/combine.py` recipe (legacy formats excluded).
It is distributed under the BSD license in `zstd/LICENSE`. Only decoding is
compiled into AgePad; the compressor is not bundled.

`xz/include` contains the public liblzma 5.8.4 headers from the local Homebrew
installation. Each header carries its 0BSD notice. `xz/COPYING` describes the
upstream licensing. AgePad links Apple's system `liblzma`; it does not bundle
a copy of the XZ executable or library. The used streaming ABI also exists in
Apple's older liblzma.

Steam's wire field numbers and content framing were checked against
[SteamDatabase's protobuf definitions](https://github.com/SteamDatabase/Protobufs) and the
[SteamKit content format implementation](https://github.com/SteamRE/SteamKit).
The native AgePad protocol implementation is independently written; Madeira's
GPL implementation was not copied.

Game artwork is not included in this source repository. The device packager's
optional `--game-artwork` argument accepts a private JPEG for a personal build.
Publisher artwork retains its original ownership and is outside AgePad's license.
