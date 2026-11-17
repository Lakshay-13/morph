# Morph

Morph is a native SwiftUI macOS utility for converting and transforming files with Apple frameworks and optional local engines. It preserves inputs, writes collision-safe outputs, and keeps file processing on your Mac.

![Morph app icon](morph-logo.png)

![Morph overview running on macOS 26](docs/screenshots/morph-overview.png)

## What works today

- Finder Quick Action: right-click a file, choose **Quick Actions → Convert with Morph**, then choose an available format in Morph.
- Drag and drop or select multiple files in the app. Mixed selections can be batch-converted when every input shares the chosen output route.
- Runtime format discovery from Apple ImageIO, FFmpeg codecs and containers, ImageMagick, Pandoc, Poppler and LibreOffice.
- Fallback to another registered engine when a higher-priority adapter fails and a second route exists.
- Native image conversion and image-to-PDF, audio/video conversion, document conversion, PDF text extraction, JSON/CSV/TSV/XML conversion and ZIP/TAR.GZ repackaging.
- Quick actions for 50% image resizing, merging selected PDFs, extracting selected PDF page ranges, splitting a PDF into pages, preset-based PDF compression and extracting ZIP archives.
- Read-only image and PDF metadata inspection, including image dimensions and available camera fields, or PDF page count and document attributes.
- Route-aware conversion presets for Images to JPEG, Images to WebP at 80% quality, Video to MP4 with H.264, audio extraction to MP3 and Documents to PDF. Presets appear only when every selected file has the required locally available output route.
- Output beside the source, in `~/Documents/Morph Output`, or in a chosen folder. Existing files are never replaced.
- Local conversion history, progress, cancellation for conversions, and optional Finder reveal after completion.
- An engine manager that requires an explicit confirmation before installing, updating or uninstalling Homebrew formulas.
- A native Liquid Glass primary action on macOS 26 and later, with a bordered-button fallback on macOS 14–25.

## Finder workflow

The primary Finder entry is a Quick Action installed to `~/Library/Services`. It writes only the selected file paths to a short-lived property list in Morph's Application Support folder, then opens Morph's local `morph://` handoff URL. Morph validates the manifest identifier, reads and removes the manifest, and opens its format picker. The workflow is **right-click → Quick Actions → Convert with Morph → choose format**. The app does not insert a custom top-level `Convert To` submenu into Finder.

Finder Sync is intended for sync-state and sync controls, not general-purpose Finder interface changes. AppKit Services also does not provide Finder with a nested format submenu, so Morph uses a Quick Action and keeps format selection in the app. See [Apple's Finder Sync guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html) and [Services menu documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/menu.html).

## Format availability

Morph shows a conversion only when the detected input capability, output capability and required engine are available on the current Mac. FFmpeg output choices are filtered by the installed muxers and required encoders. The list below describes implemented families; it does not claim that every extension in each family converts to every other extension.

| Family | Implemented routes and operations |
|---|---|
| Images | Apple ImageIO formats available on this macOS install; optional ImageMagick routes when detected. Image resizing writes JPEG. |
| Audio and video | FFmpeg routes based on this installed FFmpeg build's input demuxers, output muxers and required encoders. Includes audio extraction where a source has an audio stream. |
| Documents | Pandoc routes for detected reader/writer formats; LibreOffice converts within text-document or presentation families and exports those files to PDF. PDF text extraction uses Poppler. |
| Spreadsheets and data | LibreOffice converts within spreadsheet formats and exports them to PDF; Morph provides local JSON ↔ CSV, JSON ↔ XML and CSV ↔ TSV transformations. |
| Archives | ZIP ↔ TAR.GZ repackaging and ZIP extraction. Archive paths are checked before extraction and extracted links are checked for escapes. |
| PDF operations | Image-to-PDF, merge selected PDFs, extract ordered page ranges or split into pages with PDFKit; Ghostscript PDF compression with Compact, Balanced and Print quality presets. |

The format registry includes other candidate types, but unsupported candidates are not shown as conversion choices. There are no active routes yet for 7z/RAR conversion, RAW processing, font conversion, YAML/TOML conversion, CAD, geospatial or scientific formats. Video trimming, metadata editing and batch renaming are not implemented. Metadata inspection supports image and PDF files; it reads locally and does not write to the source.

## Engines and dependencies

Apple ImageIO and PDFKit, Morph's structured-data converter and macOS archive tools do not need separate engine installs. Optional engines are not bundled. The app can ask Homebrew to install these implemented adapters: FFmpeg, ImageMagick, Pandoc, Poppler, Ghostscript and LibreOffice. It checks for updates only when requested. No formula is installed, upgraded or removed until the user confirms in a system alert. Morph runs one formula action at a time and disables the engine controls while checking bottle size, awaiting confirmation or running Homebrew. If PDF compression is requested without Ghostscript, Morph explains the dependency, asks before installing it, and retries compression after installation succeeds.

When the user chooses Install, Morph requests the current Homebrew formula metadata to estimate the selected formula bottle's download size where a matching bottle is available. Required dependencies add to that size; Homebrew remains responsible for resolving and verifying the actual install plan. Morph does not download conversion engines on launch.

## Install

### Homebrew Cask

Morph is not yet available in Homebrew. The Cask draft is in [`distribution/homebrew/morph.rb`](distribution/homebrew/morph.rb). The first planned route is a Morph-maintained tap after a signed and notarized release is published. An official `homebrew/cask` submission is not currently eligible: Homebrew's policy requires public-interest thresholds for self-submissions, and this repository is new. A tap is not endorsed or supported by Homebrew. Once the release and tap exist, installation will use:

```sh
brew tap Lakshay-13/tap
brew install --cask morph
```

Do not use Gatekeeper-bypass instructions. Homebrew requires macOS executable artifacts to pass Gatekeeper checks; see [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks).

### Build from source

Requirements: macOS 14 or later, Swift 5.9 or later, and Xcode Command Line Tools. Optional conversion routes require the corresponding engine.

```sh
git clone https://github.com/Lakshay-13/morph.git
cd morph
swift build --product Morph
Scripts/build-app.sh
```

The app bundle is created at `dist/Morph.app`. Install it and its Finder Quick Action for the current user with:

```sh
Scripts/install-app.sh
```

The development build is ad-hoc signed and is not the signed/notarized public release. See [`docs/RELEASING.md`](docs/RELEASING.md) before distributing it.

## Use Morph

1. Select files in Finder and invoke **Quick Actions → Convert with Morph**, or open Morph and add/drop files.
2. Choose an output format that is available for all selected files.
3. Choose the output location in Settings. The default is beside each original.
4. Start the conversion. Morph writes to a temporary file, validates it, then saves with a unique name. Originals remain unchanged.

The image quality setting applies to lossy image outputs; the Images to WebP at 80% preset overrides it for that conversion. Resize quick actions scale images to 50% of their current longest edge and save JPEG copies. Choose the PDF compression preset in Settings; compression writes a new PDF and may alter metadata or interactive PDF features. A compressed copy cannot retain the original digital signature.

## Development

```sh
swift build --product Morph
Scripts/run-checks.sh
```

See:

- [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) — project plan and release gates.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — core, app, Finder and safety boundaries.
- [`docs/ENGINE_REGISTRY.md`](docs/ENGINE_REGISTRY.md) — adding a format or conversion engine.
- [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md) — executed real-file conversion report.
- [`docs/THIRD_PARTY.md`](docs/THIRD_PARTY.md) — dependency and license notes.
- [`docs/RELEASING.md`](docs/RELEASING.md) — signing, notarization, packaging and Homebrew steps.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`SECURITY.md`](SECURITY.md).

## Privacy and security

Morph processes input files locally. It does not upload file contents or include telemetry. The optional engine manager contacts Homebrew only after an engine action is selected: it reads public formula metadata for the size estimate and then invokes the local `brew` executable only after confirmation. Conversion inputs are passed as process arguments; Morph does not build shell commands from filenames. Temporary outputs are unique, validated before saving and removed after failures. ZIP extraction rejects absolute and parent-traversal paths and checks extracted symbolic links.

Morph's history stores input names, output paths, engine names and timestamps in `~/Library/Application Support/Morph/history.json`. You can remove that file to clear the local history.

## License

Morph is licensed under the [Apache License 2.0](LICENSE). Optional engines remain separately licensed and are installed by the user; see [`docs/THIRD_PARTY.md`](docs/THIRD_PARTY.md). Morph does not bundle those engines.
