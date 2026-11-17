# Morph architecture

## Layers

- **MorphCore** owns format/category models, engine identity, capability discovery, routes, conversion requests, staged writes, validation, and engine adapters. The SwiftUI layer receives routes and does not invoke individual engines directly.
- **EngineRegistry** discovers local binaries and probes their available formats. A route is created only when the corresponding engine is installed and advertises the required input/output capability. FFmpeg output routes also require the encoder used by Morph's adapter.
- **ConversionService** resolves an input extension, tries candidate routes in deterministic priority order, runs each registered `ConversionEngine`, validates the staged output and moves the first valid result to a unique destination. A failed adapter's staged output is removed before the next route is attempted. The `ConversionEngine` protocol supports adding independent adapters.
- **MorphApp** provides file selection/drop, Finder file-open intake, format selection, batch execution, history, settings and explicit Homebrew actions.
- **MorphFileOperations** holds additional operations that are not simple format edges: read-only image/PDF metadata inspection, image resize, PDF merge/split/compression and ZIP extraction. PDF compression is a fixed-argument Ghostscript process adapter and writes to a validated staging file.

## Data flow

```text
Finder Quick Action or file picker
              │ validated file URLs
              ▼
        SwiftUI MorphApp ── reads EngineRegistry routes
              │ ConversionRequest
              ▼
        ConversionService ── chooses ConversionEngine
              │ fixed executable + argument array, no shell
              ▼
     unique staged output → validator → collision-safe final path
```

The source file is not used as an output path. Each engine attempt writes inside a unique hidden staging folder under the selected output directory, so its temporary files stay on the destination volume and are removed after success, failure or cancellation. Successful conversions validate before the final move. Collisions receive a numeric suffix rather than replacing a file.

## Finder integration

The primary Finder entry is the Automator Quick Action at `Resources/QuickActions/Convert with Morph.workflow`. It receives selected paths as arguments, writes them to a short-lived property list under `~/Library/Application Support/Morph/QuickActions`, then opens a `morph://convert?manifest=<UUID>` URL. The SwiftUI scene validates the URL and UUID, reads and removes the manifest, then shows the format picker. No file data is copied into the manifest. `Scripts/install-app.sh` installs the workflow to `~/Library/Services`; its ownership marker lets Morph update its own workflow while refusing to replace a different action. The Cask draft uses Homebrew's `service` artifact so installation and removal are managed by Homebrew.

The action appears under Finder's **Quick Actions** context menu. Finder Sync is intended for sync-related Finder UI, so Morph uses a Quick Action for the file operation. It does not insert a custom top-level `Convert To` submenu into Finder; the format choice happens in Morph.

## Engine discovery and selection

`EngineID` records each engine's identifier, display name, executable candidates and Homebrew formula. `EngineRegistry.discover()`:

1. Queries ImageIO for native readable/writable type identifiers.
2. Finds external tools in PATH and standard Homebrew/MacPorts directories.
3. Runs fixed version/capability queries such as `ffmpeg -demuxers`, `-muxers`, `-encoders`, ImageMagick's format listing, Pandoc's reader/writer listings, and LibreOffice's headless version probe.
4. Produces conversion routes for the installed and implemented adapters.

Routes are deterministic: built-in adapters are preferred, followed by FFmpeg/Pandoc/Poppler, then other optional adapters. LibreOffice is listed only after a real executable is found. Ghostscript provides a PDF-compression operation outside the route graph. `libvips` and 7-Zip are probed as future candidates without current Morph conversion adapters.

## Dependency actions

The engine screen is the place to manage packages. If PDF compression is requested without Ghostscript, Morph explains why it is needed, checks Homebrew formula metadata for a bottle size estimate, then asks for confirmation. After an approved install succeeds, Morph refreshes engine discovery and retries that compression request. Other installs, updates and uninstalls use the same confirmation flow. All package actions use fixed `brew` invocations. A single-operation gate disables engine controls while the estimate, confirmation or Homebrew process is active, preventing duplicate or concurrent package-manager operations. Homebrew checks package checksums. Network availability and the Xcode license state can prevent Homebrew from running.

## Local storage

- User settings use `UserDefaults` under the `com.lakshaychawla.Morph` key.
- Conversion history is stored at `~/Library/Application Support/Morph/history.json`.
- No input content is stored in history. No telemetry is implemented.

## Product limits

The current package has no conversion-plugin loader, sandbox or update service. Engines are fixed adapters in the application. The Quick Action passes file paths to the installed application and cannot add an arbitrary custom top-level Finder submenu. The package and release scripts retain this boundary rather than claiming unsupported Finder UI.
