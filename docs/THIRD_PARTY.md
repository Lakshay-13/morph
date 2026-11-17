# Third-party components and licenses

Morph itself is Apache-2.0. The Swift package has no third-party Swift package dependencies. Optional command-line engines are not bundled in `Morph.app`; they remain separate programs installed by the user through Homebrew. Their licenses do not change Morph's license.

| Component | Use in Morph | License / distribution note |
|---|---|---|
| Apple ImageIO, PDFKit, AppKit and SwiftUI | Native conversion, PDF operations and UI | Apple system frameworks; not redistributed in Morph. |
| FFmpeg | Audio/video adapters | FFmpeg's codebase is primarily LGPL-2.1-or-later with optional GPL components. Build configuration matters: the tested local FFmpeg build enables GPL components (including H.264 support). Morph does not bundle this build. See [FFmpeg's licensing guidance](https://www.ffmpeg.org/legal.html). |
| ImageMagick | Optional image conversion | Apache-2.0 upstream license. Not bundled. |
| Pandoc | Optional document conversion | GPL-2.0-or-later upstream distribution. Not bundled. |
| Poppler | PDF text extraction | GPL-2.0-or-later family; verify the exact package license for the installed build. Not bundled. |
| LibreOffice | Office file conversion | MPL-2.0 with additional component licenses in the upstream distribution. Not bundled. |
| macOS `ditto`, `zip`, `unzip` and `tar` | Archive conversion/extraction | Apple/macOS system tools; not redistributed. |

Ghostscript, libvips and 7-Zip were evaluated as possible future tools. They have no current Morph conversion adapter and are not offered in the dependency UI. This avoids installing tools that do not currently enable a Morph operation. If an adapter is added, its version-specific formula and license details must be recorded here before release.

## Distribution rule

Morph does not copy Homebrew bottles or optional executables into its app bundle. A release archive contains only Morph's app bundle and its icon. The app may invoke an external engine already installed by the user. Before changing to bundled engines, repeat the license, source-offer, build-configuration, attribution, patent and notarization review for every exact artifact. FFmpeg's license depends on enabled components; do not infer its license from the project name alone.

This file records the upstream license families and current separation strategy. It is not a legal opinion. The Homebrew formula's license metadata and the engine's own license files are authoritative for a particular installed version.
