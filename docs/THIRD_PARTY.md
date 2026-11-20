# Third-party components and licenses

Morph itself is licensed under Apache-2.0. Morph statically links two Swift packages for local structured-data conversion; their license texts and the notices for their bundled C libraries ship inside `Morph.app/Contents/Resources/Legal` and the release archive. Optional command-line engines are separate programs installed by the user through Homebrew and are not bundled in Morph.

| Component | Version / use in Morph | License and distribution note |
|---|---|---|
| [Yams](https://github.com/jpsim/Yams) | 6.2.2; YAML parsing and serialization | MIT. Its package includes and builds LibYAML source. The Yams and LibYAML notices are in `THIRD_PARTY_LICENSES/`. |
| [LibYAML](https://github.com/yaml/libyaml) | Bundled by Yams 6.2.2 | MIT. Its notice is included because Yams compiles the C library as part of Morph. |
| [swift-toml](https://github.com/mattt/swift-toml) | 2.1.1; TOML parsing and serialization | MIT. The package bundles toml++ and the C++ header used by its implementation. |
| [toml++](https://github.com/marzer/tomlplusplus) | 3.4.0; bundled by swift-toml 2.1.1 | MIT. Its notice is included separately in `THIRD_PARTY_LICENSES/`. |
| Apple ImageIO, PDFKit, AppKit and SwiftUI | Native conversion, PDF operations and UI | Apple system frameworks; not redistributed. |
| macOS `libarchive` | Archive extraction through the C system-library module map | Loaded from macOS at runtime; not bundled or redistributed by Morph. |
| FFmpeg | Audio/video adapters | FFmpeg's codebase is primarily LGPL-2.1-or-later with optional GPL components. Build configuration matters: the tested local FFmpeg build enables GPL components (including H.264 support). Morph does not bundle this build. See [FFmpeg's licensing guidance](https://www.ffmpeg.org/legal.html). |
| ImageMagick | Optional image conversion | Apache-2.0 upstream license. Not bundled. |
| Pandoc | Optional document conversion | GPL-2.0-or-later upstream distribution. Not bundled. |
| Ghostscript | PDF compression presets | [Homebrew identifies the formula as AGPL-3.0-or-later](https://formulae.brew.sh/formula/ghostscript); [Artifex describes its AGPL and commercial license choices](https://www.ghostscript.com/faq/index.html). It is an independently installed process and is not bundled or linked into Morph; users must review the terms for their use. |
| [7-Zip](https://www.7-zip.org/) | Optional ZIP ↔ 7z archive conversion through the `7zz` executable | Homebrew's [`sevenzip` formula](https://formulae.brew.sh/formula/sevenzip) identifies LGPL-2.1-or-later AND BSD-3-Clause. It is installed separately by the user, invoked as a process, and not bundled or linked into Morph. RAR is not advertised as a supported input. |
| LibreOffice | Office file conversion | MPL-2.0 with additional component licenses in the upstream distribution. Not bundled. |
| macOS `libarchive` | ZIP/TAR/7z archive reading, extraction and ZIP/TAR repackaging | Apple/macOS system library; not redistributed. Morph calls its reader and writer APIs directly and does not extract archive members by invoking a shell command. |

libvips was evaluated as a possible future tool. It has no current Morph conversion adapter. 7-Zip supports only the ZIP ↔ 7z routes described above; additional 7-Zip formats are not advertised until their safety and conversion behavior are tested.

## Dependency pinning

`Package.swift` pins Yams 6.2.2 and swift-toml 2.1.1 exactly. `Package.resolved` records their source revisions. swift-toml 2.1.1 bundles toml++ 3.4.0; Yams 6.2.2 bundles LibYAML source. These are build-time SwiftPM dependencies, not independently installed conversion engines.

## Distribution rule

Morph does not copy Homebrew bottles or optional executables into its app bundle. The app bundle and release archive include Morph's Apache license, this attribution document and all license texts for the statically linked parser components. The app may invoke an external engine already installed by the user. Before bundling engines, repeat the license, source-offer, build-configuration, attribution, patent and notarization review for every exact artifact. FFmpeg's license depends on enabled components; do not infer its license from the project name alone.

This file records upstream license families and the current separation strategy. It is not a legal opinion. The Homebrew formula's license metadata and an engine's own license files are authoritative for a particular installed version.
