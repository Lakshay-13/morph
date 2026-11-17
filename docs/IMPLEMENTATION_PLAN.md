# Morph implementation plan

## Repository baseline

- The repository is currently an Apache-2.0-licensed shell: `LICENSE` and `morph-logo.png` are the only tracked project files.
- `main` is clean and tracks `origin/main`.
- The development machine is an Apple Silicon Mac running macOS 26.6.2. FFmpeg, ImageMagick, libvips, Pandoc, Ghostscript, Poppler and LibreOffice executables are present. There is no Developer ID signing identity or prior Morph installation.
- `xcodebuild` and Homebrew currently refuse to run because the installed Xcode license is not accepted. SwiftPM builds and the custom real-file check harness run with `/Library/Developer/CommandLineTools` selected through `DEVELOPER_DIR`; use that path for local validation without changing system developer settings. Homebrew-based install/update actions may still be blocked by the license check.

## Product architecture

1. **MorphCore Swift package:** format definitions, conversion graph, engine discovery, conversion job model, safe output naming, process runner, history/settings storage and native conversion adapters. Keep engine selection independent of UI.
2. **Native app:** SwiftUI macOS app with a navigation sidebar for Overview, Convert, History, Engines and Settings. Use standard system controls and materials so macOS supplies its current Liquid Glass behavior and accessibility adaptations.
3. **Finder entry point:** install a native Automator Quick Action for file selections. Finder passes selected file URLs to Morph; Morph opens a focused target-format picker and runs the selected conversion. Keep originals untouched. Finder Sync is not appropriate for a general converter because Apple positions it for synchronization UI in monitored folders. The deliberate tradeoff is one Quick Actions selection followed by choosing a format in Morph, rather than injecting a custom top-level Finder submenu.
4. **Engine adapters:** native ImageIO/Quartz for system-supported image and PDF work; fixed-argument process adapters for installed FFmpeg, ImageMagick, libvips, Pandoc, Poppler and other explicitly catalogued tools. Resolve executables from known locations/PATH, never through a shell. Store exact capability edges and only show them when their engine and codecs are available.
5. **Dependency manager:** read-only discovery at launch; no downloads or updates in the background. The engine screen shows installed versions and route examples; installation estimates the selected formula bottle size when available, then requires a separate affirmative user action, runs a fixed Homebrew formula invocation, and refreshes detected capabilities after success. Do not bundle engines in the first release.
6. **Safe conversion pipeline:** stage output beside the destination in a unique temporary path, validate it, then move it to a collision-safe final name. Preserve sources, avoid overwrites, support cancellation and clean up only Morph-owned temporary files.

## Work phases

1. **Foundation:** package manifest, app entry point, app metadata, assets, ignore rules, development scripts and this plan.
2. **Core:** format/engine registry, capability probes, safe conversion job/output pipeline, native data/image/PDF operations and external process adapters.
3. **Application:** native dashboard, file picker/drop intake, Finder Service, format choice, batch queue, progress/cancel, history, output location and engine consent flow.
4. **Operations:** image resize, PDF merge/split, ZIP extraction and ZIP/TAR.GZ repackaging are implemented and checked. Keep the catalogue honest about unsupported font, CAD, geospatial and specialist conversions.
5. **Quality:** unit tests, fixture-based end-to-end tests, 12+ real format-pair conversions, security/failure/collision/cancellation checks, and a Finder smoke test.
6. **Documentation:** README, architecture and engine registration guide, tested capability matrix, known limitations, security/privacy notes, contribution guidance and third-party license attribution.
7. **Release:** reproducible arm64/x86_64 build where toolchain support permits, app archive/DMG, checksums, signing/notarization workflow, GitHub release and Cask audit. Do not ask users to bypass Gatekeeper.
8. **Install/distribute:** install to the current user’s Applications folder, register and verify Finder integration, exercise installed conversions, push all intended commits, and submit an upstream Cask PR only if the published artifact meets current Homebrew policy and GitHub access is available.

## Validation and release gates

- The self-contained SwiftPM harness currently runs 13 groups, covering 23 distinct format pairs, real engine conversions, safe outputs, source checksums, collision handling, invalid input, missing engines, fallback, cancellation, office-route family constraints and a large image. See `TEST_REPORT.md`.
- Cover mixed and batch inputs, unsupported/missing engines, failed and invalid inputs, collisions, cancellation, cleanup and large inputs where practical.
- A universal binary is not considered validated on Intel without an Intel runtime check. Record architecture coverage honestly.
- The Finder right-click Quick Actions submenu displays the Morph action. Finder Services and the installed Automator workflow both imported a selected file; the installed app completed a PNG → JPEG conversion. The Quick Actions submenu item itself was not successfully clicked. The live dependency confirmation was opened and cancelled; an install was not approved or run.
- Homebrew Cask requires a stable upstream artifact, checksum, local audit/install/uninstall checks and Gatekeeper-compliant distribution. The current machine has no Developer ID identity, so signing/notarization and public Cask eligibility remain blocked.
- No engine or system dependency may be installed by the agent without a distinct explicit user approval.
