# Morph architecture

## Layers

- **MorphCore** owns format/category models, engine identity, capability discovery, routes, conversion requests, staged writes, validation, and engine adapters. The SwiftUI layer receives routes and does not invoke individual engines directly.
- **EngineRegistry** discovers local binaries and probes their available formats. A route is created only when the corresponding engine is installed and advertises the required input/output capability. FFmpeg output routes also require the encoder used by Morph's adapter.
- **ConversionService** resolves an input extension, tries candidate routes in deterministic priority order, runs each registered `ConversionEngine`, validates the staged output and moves the first valid result to a unique destination. A failed adapter's staged output is removed before the next route is attempted. The `ConversionEngine` protocol supports adding independent adapters.
- **MorphApp** provides file selection/drop, format selection, batch execution, history, settings and explicit Homebrew actions. When launched by the Finder helper with `--morph-background`, it changes to accessory policy and hides its window. `morph://show` reveals the window; `morph://quit` exits the hidden host.
- **MorphFinderSync** supplies a selection-aware Finder contextual submenu. It uses `EngineRegistry` and `QuickConversionCatalog` to list only installed routes shared by the selected files, then sends their paths and chosen output format to the helper. The sandboxed extension does not open the selected files itself.
- **MorphQuickConvert** is a persistent, windowless accessory helper for Finder conversion. It accepts a conversion URL only when the Apple Event sender PID resolves to Morph's embedded Finder Sync extension bundle. On a cold launch, the extension starts the helper without request data in process arguments, then retries the same authenticated URL; a request ID prevents duplicate conversions. The helper validates each request and uses the same `EngineRegistry` and `ConversionService` as the main app. Its menu-bar item shows progress and cancellation while converting, offers **Open Morph** and **Quit Morph**, and stays available until the user quits it. If the user quits during a conversion, the helper cancels that work and exits after cleanup.
- **MorphFileOperations** holds additional operations that are not simple format edges: read-only image/PDF metadata inspection, validated metadata-edit copies for PDFs and JPEG/TIFF images, image resize, previewed batch rename copies, PDF merge/page-range extraction/split/compression, ZIP extraction and FFmpeg video trimming. Metadata edits use PDFKit or ImageIO, stage beside the destination, validate the saved fields and dimensions/page count, then move to a collision-safe name. The original is never opened for writing.
- **StructuredDataEngine** handles local JSON, YAML/YML, TOML, CSV/TSV and XML routes. Yams (with its bundled LibYAML) and swift-toml (with bundled toml++) are pinned SwiftPM dependencies; they are statically linked and their license texts ship in the app bundle. Parsing is size/depth/collection limited, and conversions reject values the target representation cannot express.

## Data flow

```text
Finder contextual menu ── selected URLs + available targets
              │ Convert To → Convert with Morph → [source → target]
              │ open helper with encoded request URL
              ▼
      MorphFinderSync extension ── builds contextual submenu
              │ launches the embedded helper
              ▼
      MorphQuickConvert accessory ── rechecks EngineRegistry routes
              │ ConversionRequest
              ▼
        ConversionService ── chooses ConversionEngine
              │ fixed executable + argument array, no shell
              ▼
     unique staged output → validator → collision-safe final path

The main SwiftUI application is opened normally only when the user launches Morph directly or chooses **Open Morph** from the helper menu. For Finder conversions, the helper starts the main app in hidden accessory mode when needed and leaves it running. The Finder path does not activate or display a Morph window. The helper stays in the menu bar until the user chooses **Quit Morph**, which also exits the hidden main-app process.
```

The source file is not used as an output path. Each engine attempt writes inside a unique hidden staging folder under the selected output directory, so its temporary files stay on the destination volume and are removed after success, failure or cancellation. Successful conversions validate before the final move. Collisions receive a numeric suffix rather than replacing a file.

Batch rename is available from the app's Operations page. Morph previews a numbered prefix plus each complete original filename, so compound suffixes such as `.tar.gz` remain intact. It copies through a hidden staging file in the configured destination, verifies the copied size, then moves to a collision-safe path without replacing existing files. The source is never renamed or deleted. Cancellation stops before the next file and removes the active staging copy when possible.

## Finder integration

The primary Finder entry is the embedded `MorphFinderSync.appex`. It monitors the current user's home folder, `/Volumes`, `/Network` and `/Users/Shared`. For an item selection, `menu(for:)` reads `selectedItemURLs()` and intersects routes across all selected files. When Morph has published its engine snapshot, Finder uses the same installed-engine routes as the main app, including available ImageMagick, FFmpeg, Pandoc, Poppler and LibreOffice adapters. If no snapshot exists yet, Finder uses a lightweight native fallback for ImageIO, PDF, structured data and macOS archive tools; optional-engine media and document routes require Morph to complete its first engine discovery. The contextual menu is **Convert To → Convert with Morph → [source → output]**; for example, a PNG can offer **PNG → JPEG (.jpg)** when that route is available. Choosing a row sends one encoded request containing the selected paths and requested output format to the accessory helper; the extension does not attempt to open the source files because Finder Sync's selected URLs provide menu context, not file-read access. macOS may request Files & Folders permission from the helper for protected locations such as Downloads. The helper validates the paths and route again, performs the conversion with `ConversionService`, and shows progress/cancellation from its persistent menu-bar item. It does not open the main Morph window or a format picker. Its menu also offers explicit **Open Morph** and **Quit Morph** actions. The helper preserves sources and writes to collision-safe destinations.

The contextual submenu appears directly in Finder's right-click menu; macOS does not provide an API for inserting a dynamic submenu inside its built-in **Quick Actions** section. Apple's Finder Sync guidance describes that extension point as sync-oriented and recommends it for synchronization status/control. The extension performs no conversion itself; conversion stays in the accessory helper. For a cold helper launch, the extension launches the helper without request data in arguments, then sends the same sender-checked URL up to three times while the helper starts. A request ID makes retries idempotent. This locally installed ad-hoc build displayed the menu and completed a cold-start conversion, but ad-hoc signing is not suitable for public distribution and may be treated differently on other Macs. See [Apple's Finder Sync programming guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html).

## Engine discovery and selection

`EngineID` records each engine's identifier, display name, executable candidates and Homebrew formula. `EngineRegistry.discover()`:

1. Queries ImageIO for native readable/writable type identifiers.
2. Finds external tools in PATH and standard Homebrew/MacPorts directories.
3. Runs fixed version/capability queries such as `ffmpeg -demuxers`, `-muxers`, `-encoders`, ImageMagick's format listing, Pandoc's reader/writer listings, and LibreOffice's headless version probe.
4. Produces conversion routes for the installed and implemented adapters.

Routes are deterministic: built-in adapters are preferred, followed by FFmpeg/Pandoc/Poppler, then other optional adapters. LibreOffice is listed only after a real executable is found. Ghostscript provides a PDF-compression operation outside the route graph. 7-Zip provides ZIP ↔ 7z archive routes only when `7zz` is installed. Its adapter validates 7z member paths and rejects link entries before extraction. `libvips` remains a probed candidate without a conversion adapter.

Video trimming and compression are FFmpeg operations outside the general route graph. Trimming checks the source duration, re-encodes the requested interval as H.264/AAC MP4 and validates the output duration. Compression accepts batches, exposes quality and maximum-resolution choices, re-encodes to H.264/AAC MP4 and validates duration and dimensions. Both use unique staged destinations, preserve originals and support process cancellation. Compression reports actual aggregate input and output sizes because re-encoding can enlarge already-compressed media. The confirmation explains quality changes and possible subtitle/metadata loss. If FFmpeg is absent, Morph asks before offering installation and retries after approval.

## Dependency actions

The engine screen is the place to manage packages. If PDF compression is requested without Ghostscript, Morph explains why it is needed, checks Homebrew formula metadata for a bottle size estimate, then asks for confirmation. After an approved install succeeds, Morph refreshes engine discovery and retries that compression request. Other installs, updates and uninstalls use the same confirmation flow. All package actions use fixed `brew` invocations. A single-operation gate disables engine controls while the estimate, confirmation or Homebrew process is active, preventing duplicate or concurrent package-manager operations. Homebrew checks package checksums. Network availability and the Xcode license state can prevent Homebrew from running.

## Local storage

- User settings use `UserDefaults` under the `com.lakshaychawla.Morph` key.
- Conversion history is stored at `~/Library/Application Support/Morph/history.json`.
- No input content is stored in history. No telemetry is implemented.

## Product limits

The current package has no conversion-plugin loader or update service. Engines are fixed adapters in the application. The Finder extension is sandboxed and handles selection/menu work only; the accessory helper performs conversion. The Finder submenu is not part of the built-in **Quick Actions** section, and Finder Sync is documented primarily for sync-related UI. The extension monitors the home folder, mounted volumes, network shares and `/Users/Shared`; ad-hoc local builds may not surface the extension in Finder.
