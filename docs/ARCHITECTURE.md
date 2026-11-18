# Morph architecture

## Layers

- **MorphCore** owns format/category models, engine identity, capability discovery, routes, conversion requests, staged writes, validation, and engine adapters. The SwiftUI layer receives routes and does not invoke individual engines directly.
- **EngineRegistry** discovers local binaries and probes their available formats. A route is created only when the corresponding engine is installed and advertises the required input/output capability. FFmpeg output routes also require the encoder used by Morph's adapter.
- **ConversionService** resolves an input extension, tries candidate routes in deterministic priority order, runs each registered `ConversionEngine`, validates the staged output and moves the first valid result to a unique destination. A failed adapter's staged output is removed before the next route is attempted. The `ConversionEngine` protocol supports adding independent adapters.
- **MorphApp** provides file selection/drop, Finder file-open intake, format selection, batch execution, history, settings and explicit Homebrew actions.
- **MorphFinderSync** supplies a selection-aware Finder contextual submenu. It uses `EngineRegistry` and `QuickConversionCatalog` to list only installed routes shared by the selected files, then opens the selected files in the helper with the chosen output format attached.
- **MorphQuickConvert** is a windowless accessory helper for Finder conversion. It validates the request again and uses the same `EngineRegistry` and `ConversionService` as the main app. It shows progress and cancellation in a menu-bar status item without opening an app window.
- **MorphFileOperations** holds additional operations that are not simple format edges: read-only image/PDF metadata inspection, image resize, previewed batch rename copies, PDF merge/page-range extraction/split/compression, ZIP extraction and FFmpeg video trimming. Process-backed operations use fixed executable arguments and write to validated staging files.
- **StructuredDataEngine** handles local JSON, YAML/YML, TOML, CSV/TSV and XML routes. Yams (with its bundled LibYAML) and swift-toml (with bundled toml++) are pinned SwiftPM dependencies; they are statically linked and their license texts ship in the app bundle. Parsing is size/depth/collection limited, and conversions reject values the target representation cannot express.

## Data flow

```text
Finder contextual menu ── selected URLs + available targets
              │ Convert To → Convert with Morph → [source → target]
              │ open selected file URLs in helper
              ▼
      MorphFinderSync extension ── builds contextual submenu
              │ opens selected files
              ▼
      MorphQuickConvert accessory ── rechecks EngineRegistry routes
              │ ConversionRequest
              ▼
        ConversionService ── chooses ConversionEngine
              │ fixed executable + argument array, no shell
              ▼
     unique staged output → validator → collision-safe final path

The main SwiftUI application is opened only when the user launches Morph directly. The Finder conversion path does not create or activate a Morph window.
```

The source file is not used as an output path. Each engine attempt writes inside a unique hidden staging folder under the selected output directory, so its temporary files stay on the destination volume and are removed after success, failure or cancellation. Successful conversions validate before the final move. Collisions receive a numeric suffix rather than replacing a file.

Batch rename is available from the app's Operations page. Morph previews a numbered prefix plus each complete original filename, so compound suffixes such as `.tar.gz` remain intact. It copies through a hidden staging file in the configured destination, verifies the copied size, then moves to a collision-safe path without replacing existing files. The source is never renamed or deleted. Cancellation stops before the next file and removes the active staging copy when possible.

## Finder integration

The primary Finder entry is the embedded `MorphFinderSync.appex`. It monitors the current user's home folder, `/Volumes`, `/Network` and `/Users/Shared`. For an item selection, `menu(for:)` reads `selectedItemURLs()`, discovers supported native capabilities and intersects routes across all selected files. The contextual menu is **Convert To → Convert with Morph → [source → output]**; for example, a PNG can offer **PNG → JPEG (.jpg)** when that route is available. Choosing a row opens the selected file URLs in the accessory helper with the requested output extension. The helper validates the paths and requested route again, performs the conversion with `ConversionService`, and shows progress/cancellation from its menu-bar status item. It does not open the main Morph window or a format picker. The helper preserves sources and writes to collision-safe destinations. Finder Sync currently lists native ImageIO, PDF and structured-data routes; optional-engine media and document routes are not yet exposed by this extension.

The contextual submenu appears directly in Finder's right-click menu; macOS does not provide an API for inserting a dynamic submenu inside its built-in **Quick Actions** section. Apple's Finder Sync guidance describes that extension point as sync-oriented and recommends it for synchronization status/control. The extension performs no conversion itself; conversion stays in the accessory helper. Ad-hoc builds may be hidden by Finder, and the Finder menu was not visible in the latest local smoke test because the extension has no usable signing identity. See [Apple's Finder Sync programming guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html).

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
