# Third-party notices

The macOS app bundles open-source libraries. They remain under their own licences;
the project’s MIT licence does not replace them. Versions below are those in the
0.3.0 release and may change in later releases.

| Component | Version in 0.3.0 | Licence | Upstream |
| --- | --- | --- | --- |
| SwARc (the `librecomp_*` runtime libraries) | development build, with changes for this port | MIT (copyright 2026 JT) | https://github.com/JTM-rootstorm/SwARc |
| Berkeley SoftFloat (built into SwARc's x87 library) | Release 3e (upstream commit `5c06db33`) | BSD-3-Clause (copyright The Regents of the University of California) | https://github.com/ucb-bar/berkeley-softfloat-3 |
| SDL | 3.4.14 | Zlib | https://libsdl.org/ |
| FFmpeg (`libavcodec`, `libavformat`, `libavutil`, `libswresample`, `libswscale`) | 8.1.2 | LGPL-2.1-or-later (a build without GPL or non-free parts) | https://ffmpeg.org/ |
| OpenSSL | 4.0.3 (`libcrypto`) | Apache-2.0 | https://openssl-library.org/ |
| glslang | 16.6.0 | Upstream licence set (including BSD, MIT, Apache-2.0 and GPL components where applicable) | https://github.com/KhronosGroup/glslang |
| SPIRV-Tools | Vulkan SDK 1.4.363.0 series | Apache-2.0 | https://github.com/KhronosGroup/SPIRV-Tools |
| unshield | 1.6.2 | MIT | https://github.com/twogood/unshield |

SwARc is the recompiler and runtime this port is built on, and it is released under the
MIT licence. The translated game programs (`bw_native` and `bw_native_142`) and the
game's program files in the app are not covered by that licence or by this project's
licence; see `NOTICE.md`.

The binary release carries the full licence texts for the libraries inside it, in a
`Licenses` folder next to the apps. FFmpeg is the one library in the download under the
LGPL: `Licenses/SOURCE-OFFER.txt` is a written offer of its source code, with the exact
build options and how to run the game with a build of your own. Do not treat this
summary as a substitute for those texts.
