# Third-Party Licenses & Attribution

`unipad-zig` is licensed under the GNU General Public License v3.0 ([LICENSE](LICENSE)).
All bundled and linked components are compatible with GPLv3.

## Bundled Components

| Component | License | Location | Use |
| --- | --- | --- | --- |
| [sokol_gfx](https://github.com/floooh/sokol) | zlib | `third_party/sokol_gfx.h` | GPU-accelerated 2D rendering |
| [nativefiledialog-extended](https://github.com/btzy/nativefiledialog-extended) | zlib | `third_party/nfd/` (`third_party/nfd/LICENSE`) | Native OS open file/folder dialogs |
| [dr_wav, dr_flac, dr_mp3](https://github.com/mackron/dr_libs) | Public Domain / MIT-0 | `third_party/dr_*.h` | Audio decoding |
| [stb_vorbis](https://github.com/nothings/stb) | Public Domain / MIT | `third_party/stb_vorbis.c` | Ogg Vorbis decoding |
| [SUITE font](https://github.com/sun-typeface/SUITE) | SIL OFL 1.1 | `assets/fonts/SUITE-*.ttf` (`assets/fonts/LICENSE-SUITE.txt`) | UI typography (embedded) |

## Linked System Libraries

| Library | License | Platform | Use |
| --- | --- | --- | --- |
| SDL3, SDL3_ttf | zlib | All | Windowing, input, threads, text rasterization |
| libarchive | BSD-2-Clause | All | `.zip` / `.uni` UniPack extraction |
| ALSA (`libasound`) | LGPL-2.1-or-later | Linux | 1-period direct audio output & ALSA Sequencer MIDI |
| D-Bus (`dbus-1`) | AFL-2.1 / GPL-2.0-or-later | Linux | XDG Desktop Portal file dialogs (via NFDe) |
| PortAudio | MIT | Windows / macOS | Low-latency audio output |

## Derived & Referenced Projects

| Project | License | Use |
| --- | --- | --- |
| [actuon](https://github.com/square3ang/actuon) | GPLv3 | Sokol/WGSL render backend (`src/render/`), 1-period direct ALSA audio architecture, font bundling |
| [unipad-android](https://github.com/kimjisub/unipad-android) | LGPL-2.1 | UniPack format & playback behavior reference (clean-room Zig implementation) |
| [web-unipad](https://github.com/square3ang/web-unipad) | — | Launchpad hardware MIDI mappings & UniPack playback reference |
