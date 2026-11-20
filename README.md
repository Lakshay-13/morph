# Morph

Morph is a native SwiftUI macOS utility for converting and transforming files with Apple frameworks and optional local engines. It preserves inputs, writes collision-safe outputs, and keeps file processing on your Mac.

![Morph app icon](morph-logo.png)

![Morph overview running on macOS 26](docs/screenshots/morph-overview.png)

## What works today

- Source-aware Finder conversion: **Convert To → [available output]** skips the extra Morph submenu. Choices identify the source format and appear only when the installed engines can perform them. The list is editable in **Settings → Finder conversion formats**. Launching Morph starts its windowless menu-bar helper. Closing Morph's single main window removes its Dock entry and leaves Morph available from the menu-bar icon.
- Drag and drop or select multiple files in the app. Mixed selections can be batch-converted when every input shares the chosen output route.
- Runtime format discovery from Apple ImageIO, FFmpeg codecs and containers, ImageMagick, Pandoc and LibreOffice.
- Fallback to another registered engine when a higher-priority adapter fails and a second route exists.
- Native image conversion and image-to-PDF, PDF page export as PNG images, audio/video conversion, document conversion, PDF text extraction, JSON/YAML/TOML/CSV/TSV/XML data transformations, ZIP/TAR/TAR.GZ/TAR.BZ2/TAR.XZ repackaging and optional ZIP ↔ 7z conversion.
- Additional operations include 50% image resizing, merging selected PDFs, extracting selected PDF page ranges, splitting a PDF into pages, preset-based PDF compression, extracting ZIP archives, trimming video and compressing one or more selected videos to H.264 MP4.
- The Operations page is a tools hub with selection-aware image, PDF, archive, metadata and video actions plus batch rename.
- Video compression offers smaller-file, balanced and higher-quality settings, plus maximum resolution choices of 1080p, 720p or the source size. Morph reports actual size changes because already-compressed inputs may produce larger files.
- A dedicated Operations page previews numbered batch-renamed copies, preserves each full filename and extension, and leaves the original files unchanged.
- Read-only image/PDF metadata inspection and safe metadata-copy editing. PDFs support title, author, subject and keywords; JPEG/TIFF copies support title, subject and keywords.
- Route-aware conversion presets for Images to JPEG, Images to WebP at 80% quality, Video to MP4 with H.264, audio extraction to MP3 and Documents to PDF. Presets appear only when every selected file has the required locally available output route.
- Output beside the source, in `~/Documents/Morph Output`, or in a chosen folder. Existing files are never replaced; Morph publishes generated files with private `0600` permissions.
- Local conversion history, progress, cancellation for conversions, and optional Finder reveal after completion.
- An engine manager that requires explicit confirmation before installing, updating or uninstalling Homebrew formulas or casks.
- A native Liquid Glass primary action on macOS 26 and later, with a bordered-button fallback on macOS 14–25.

## Finder workflow

Morph embeds a sandboxed Finder Sync extension. In Finder's contextual menu, **Convert To** opens the available source-aware format choices directly. A selection of multiple files shows only output types supported by every selected file. Choosing a row sends the selection paths and output format to Morph's accessory helper; the extension does not try to open the files itself. The helper checks the route again and converts in the background. It checks file access away from its UI thread, shows a wait state for macOS Files & Folders permission, and reports a retry after 60 seconds. No Morph window opens for a Finder conversion. Finder starts the helper directly; the helper starts the hidden main app only when it is not already running. This keeps a closed Morph app out of the Dock during later Finder conversions. macOS may ask the helper for Files & Folders permission the first time a conversion accesses a protected folder such as Downloads. The helper starts when Morph opens and stays available after the main window closes. The main app uses one window; **Open Morph** from the menu-bar item shows it again, and **Quit Morph** cancels active conversions and allows up to 60 seconds for them to stop before the app exits. A framework call that does not return may leave a private temporary stage for later cleanup. The helper's menu-bar item shows progress and cancellation while converting.

To customize the menu, open **Morph → Settings → Finder conversion formats** and check or uncheck output formats. This controls which output types Finder can show; the source-to-output routes still depend on each selection and installed engines. **Show All** restores every available output type.

Finder does not let an Automator Quick Action add a dynamic submenu to its built-in **Quick Actions** section. Morph's submenu therefore appears as a separate native Finder contextual-menu item, not inside **Quick Actions**. Finder Sync supports dynamic menus based on `selectedItemURLs()`, but Apple describes it as a sync-oriented extension point and cautions against using it as a general Finder UI customization mechanism. Morph monitors the current user's home folder, mounted volumes, network shares and `/Users/Shared`; temporary files outside those locations do not receive the menu. Ad-hoc development builds may not be surfaced by Finder; public distribution requires a valid Developer ID signature and notarization. Users can enable or disable a signed Morph extension under **System Settings → General → Login Items & Extensions → Finder Extensions**. See [Apple's Finder Sync guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html) and [`menu(for:)`](https://developer.apple.com/documentation/findersync/1501586-fifindersync/1501585-menuformenukind).

## Format availability

Morph shows a conversion only when the detected input capability, output capability and required engine are available on the current Mac. FFmpeg output choices are filtered by the installed muxers and required encoders. The list below describes implemented families; it does not claim that every extension in each family converts to every other extension.

| Family | Implemented routes and operations |
|---|---|
| Images | Apple ImageIO formats available on this macOS install; optional ImageMagick routes when detected. Image resizing writes JPEG. |
| Audio and video | FFmpeg routes based on this installed FFmpeg build's input demuxers, output muxers and required encoders. Includes M4A ↔ MP3 when the required codecs are available, audio extraction (GIF is excluded), video trimming and batch compression to H.264/AAC MP4 with configurable quality and maximum resolution. |
| Documents | Pandoc routes for detected reader/writer formats; LibreOffice converts within text-document or presentation families and exports those files to PDF when its private sandbox probe succeeds. PDF text extraction uses Apple PDFKit. |
| Spreadsheets and data | LibreOffice converts within spreadsheet formats and exports them to PDF when its private sandbox probe succeeds; Morph converts JSON, YAML/YML and TOML between one another and to/from CSV/TSV. XML bridges to JSON, YAML/YML and TOML. CSV/TSV and TOML record conversions use arrays of objects; a top-level array becomes a TOML `records` table. |
| Archives | Repackage ZIP, TAR, TAR.GZ, TAR.BZ2 and TAR.XZ archives; extract ZIP; and convert ZIP ↔ 7z when 7-Zip is installed. System `libarchive` streams validated entries directly into a new archive, preserving case-distinct member names even when temporary storage is case-insensitive. Direct ZIP extraction uses a private, descriptor-anchored stage and requires an owner-private output parent or a sticky parent owned by the current account or root, without ACLs that allow child renames or inherit permissions. |
| PDF operations | Export PDF pages as PNG images (a one-page PDF becomes one PNG; multiple pages are grouped together), image-to-PDF, merge selected PDFs, extract ordered page ranges or split into pages with PDFKit; Ghostscript PDF compression with Compact, Balanced and Print quality presets. Merges accept at most 1,000 files and 1 GB of combined input; merged output is capped at 1 GB. |

The format registry includes other candidate types, but unsupported candidates are not shown as conversion choices. Standalone `.gz`, `.bz2` and `.xz` streams, RAR conversion, RAW processing, font conversion, CAD, geospatial and scientific formats have no active routes. Native ImageIO conversion is limited to PNG, JPEG, WebP, HEIC/HEIF, TIFF, BMP, GIF and AVIF types available on the installed macOS; Morph checks file contents against the extension. PDF pages render to PNG at a 144-DPI target, capped for unusually large pages; one-page PDFs produce a single PNG, while multipage exports are grouped together. Structured-data conversions accept UTF-8 and JSON-compatible values; YAML input must contain one document. YAML aliases are supported within bounded expansion limits; non-scalar mapping keys and oversized alias expansions are rejected. Parser limits protect input size, nesting, collection lengths and table sizes, and target-aware serialized output estimates cap output at 20 MB. Archive extraction snapshots a non-blocking open of a regular input file and streams the same snapshot through system `libarchive`; only the expected archive format and compression filter are enabled. It rejects links, special files, unsafe/colliding paths and limits archive entries and all created files/directories (including implicit directories) to 10,000, per-file size to 512 MB and total expanded bytes to 2 GB. Archive repackaging streams validated members directly into the target archive, applies the same link, path and size checks, and preserves case-distinct names without extracting onto temporary storage. Direct ZIP extraction requires an owner-private output parent or a sticky parent owned by the current account or root, without ACL entries that allow child renames or inherit permissions. It keeps extracted files private and non-executable, while archive repackaging preserves safe executable bits. ZIP64 and encrypted ZIPs are not supported. CSV/TSV conversion requires records with matching string fields, rejects extra columns, and caps records, columns, padded cells and estimated output size before expanding repeated headers. An explicitly empty one-column field is written as `""` so it is not confused with a blank line. Metadata editing writes new PDF, JPEG or TIFF copies; PDF supports title, author, subject and keywords, while images support IPTC title, subject and keywords. Image author editing and clearing individual fields are not available. Blank fields preserve existing values. Batch rename creates numbered copies in the configured output location; it never renames or replaces the selected originals. Video trimming and compression re-encode to H.264/AAC; quality can change and subtitles may be dropped. By default, Morph removes GPS/location tags from image and media copies while preserving other supported ImageIO/FFmpeg metadata. ImageMagick removes EXIF, XMP and IPTC profiles to remove location metadata, so those descriptive metadata fields are also absent from its outputs. Settings can opt into preserving location tags. Compression reports whether the generated file is smaller or larger than its source. The original is preserved. Metadata inspection supports image and PDF files and does not write to the source.

## Engines and dependencies

LibreOffice resolves only to the expected LibreOffice app location and passes strict nested code-signature validation for The Document Foundation's Developer ID team and bundle identifier. Morph approves the native `soffice` executable by its SHA-256 and never runs Homebrew's shell launcher. Routes appear only after Morph completes a private CSV-to-XLSX conversion probe. If the installed build cannot complete that probe within the restricted sandbox, Morph keeps the engine installed but disables its routes.

Apple ImageIO and PDFKit, Morph's structured-data converter and macOS archive tools do not need separate engine installs. Optional engines are not bundled. The app can ask Homebrew to install these implemented adapters: FFmpeg, ImageMagick, Pandoc, Ghostscript, 7-Zip and LibreOffice. Poppler is not used; PDF text extraction uses PDFKit. Individual update checks are available, and **Update All** checks installed engines in the manager and lists the outdated packages before asking once for approval. It upgrades only the listed Morph engines, grouped into formula and cask actions. Homebrew may also upgrade dependencies and outdated dependents, close an updated application, and clean up older package versions; Morph explains this before confirmation. No formula or cask is installed, upgraded or removed until the user confirms. LibreOffice is installed as a Homebrew cask; the other optional engines use formulas. Morph runs one package action at a time while checking installed package state, awaiting confirmation or running Homebrew. Morph currently does not estimate download size; Homebrew resolves the package plan after you approve an action. If PDF compression is requested without Ghostscript, Morph explains the dependency, asks before installing it, and retries compression after installation succeeds.

Morph does not fetch Homebrew bottle metadata. After you approve an engine action, Homebrew resolves and verifies the actual package plan. Morph requests that Homebrew skip analytics and automatic self-updates and passes configured HTTP/HTTPS proxy variables. Homebrew also loads `brew.env` from system, prefix and user configuration locations; those files can override Morph's settings or supply Cask options, so check your Homebrew configuration before confirming an engine action.

## Install

### Homebrew Cask

Morph is not yet available in Homebrew. The Cask draft is in [`distribution/homebrew/morph.rb`](distribution/homebrew/morph.rb). The first planned route is a Morph-maintained tap after a signed and notarized release is published. An official `homebrew/cask` submission is not currently supportable: Homebrew's owner-submission policy normally requires 90 forks, 90 watchers or 225 stars, and this repository has no independent-interest evidence yet. A tap is not endorsed or supported by Homebrew. Once the release and tap exist, installation will use:

```sh
brew tap Lakshay-13/tap
brew install --cask morph
```

Do not use Gatekeeper-bypass instructions. Homebrew requires macOS executable artifacts to pass Gatekeeper checks; see [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks).

### Build from source

Requirements: macOS 14 or later to run Morph, and full Xcode with the macOS 26 SDK to build the current Liquid Glass interface and Finder Sync extension. The build also requires Swift 6. Optional conversion routes require the corresponding engine.

```sh
git clone https://github.com/Lakshay-13/morph.git
cd morph
swift build --product Morph
Scripts/build-app.sh
```

`Scripts/build-app.sh` creates a host-architecture app bundle at `dist/Morph.app`. To build a universal app with arm64 and x86_64 slices, use `MORPH_BUILD_ARCH=universal Scripts/build-app.sh`; `Scripts/package-release.sh` selects this universal build automatically. Install the bundle and register Finder integration for the current user with:

```sh
Scripts/install-app.sh
```

The development build is ad-hoc signed and is not the signed/notarized public release. See [`docs/RELEASING.md`](docs/RELEASING.md) before distributing it.

## Use Morph

1. Select files in Finder and choose **Convert To → [source → output format]**, or open Morph and add/drop files.
2. The Finder submenu shows only formats available for the entire selection. Set the output location in Settings; the default is beside each original.
3. Morph converts in the background, validates the output and saves it with a unique name. Originals remain unchanged.

The image quality setting applies to lossy image outputs; the Images to WebP at 80% preset overrides it for that conversion. Resize quick actions scale images to 50% of their current longest edge and save JPEG copies. Settings also lets you preserve location tags when needed; removal is enabled by default. Choose the PDF compression preset in Settings; compression writes a new PDF and may alter metadata or interactive PDF features. A compressed copy cannot retain the original digital signature. History can be cleared without deleting converted files.

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

Morph processes files locally and does not upload file contents or include telemetry. It resolves optional tools from fixed locations. Before Morph runs an external engine or Homebrew, you review the resolved executable path and SHA-256; signed builds store approval in a shared, team-prefixed Data Protection Keychain group and check it again before use. Unapproved or changed binaries are not probed and add no conversion routes. Engine installs, updates and removals require their own confirmations. Morph does not request Homebrew bottle metadata before you approve an install; Homebrew resolves package and dependency downloads after confirmation. Ad-hoc local builds cannot safely store these approvals, so external-engine and Homebrew actions are disabled while built-in conversions continue to work.

Conversions use argument arrays without shell interpolation, bounded process output, timeouts, cancellation and private staging before atomic publication. Originals are preserved. PDF/image work has input, page/frame, pixel, disk-space and output-size limits. Image-to-PDF decodes each page to a fresh pixel-only bitmap before PDFKit writes it, so source image metadata is not embedded in the PDF. FFmpeg is restricted to local-file protocols and an extension-based demuxer allowlist; ImageMagick receives a restrictive per-conversion policy; Pandoc runs with `--sandbox`. Approved external engines also run under a macOS process sandbox that denies network access, reads and writes under the user's home and common temporary locations, hard links and clones, and writes outside private stages. It blocks Apple Events, LaunchServices opens, launchd job creation, process execution except for the reviewed engine, process forks, signals to other processes, preference access, and selected sensitive Mach services. Other default reads and unlisted Mach lookups remain available, so this is not a complete OS sandbox. Morph enforces reviewed minimum versions for optional engines. These controls reduce specific risks; parsers running inside Morph itself are not OS-sandboxed.

Custom output-folder settings are accepted only when their path and directory identity match a protected Keychain record. If secure storage is unavailable or the saved folder no longer matches, Morph saves to `~/Documents/Morph Output` and explains the fallback. Output staging requires a writable local volume with file ownership enabled; unsupported volumes use the same fallback. If the source folder cannot securely host private staging, Morph also uses that output folder. The Finder helper authenticates the Apple Event sender with its audit token and embedded Finder Sync code identity, then validates files and conversion routes. macOS may request folder-level Files & Folders access for protected locations such as Downloads. Finder conversions process selected paths and do not scan folders.

Morph itself is not OS-sandboxed. Approved external engines run as the current user under Morph's process sandbox, which denies filesystem writes by default except for `/dev/null` and Morph's private stages. It blocks selected launch and IPC paths, while otherwise preserving macOS's default file reads and Mach service lookups. Engine output from LibreOffice is snapshotted into a separate Morph-owned stage before validation. Executable digest approval pins the main executable, not its dynamically loaded libraries or related engine files, and cannot eliminate every time-of-check/time-of-use race. Morph does not claim that it or its dependencies are vulnerability-free. Diagnostics are recorded in macOS Unified Logging; the UI omits raw engine output. See [SECURITY.md](SECURITY.md) for the complete boundaries, limits and reporting instructions.

## License

Morph is licensed under the [Apache License 2.0](LICENSE). The [NOTICE](NOTICE) identifies the copyright holder, and [`docs/THIRD_PARTY.md`](docs/THIRD_PARTY.md) records third-party components and their licenses. Optional engines remain separately licensed and are installed by the user; Morph does not bundle those engines.
