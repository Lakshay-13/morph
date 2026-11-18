# Test report

**Run on:** macOS 26.6.2, Apple M3 Max (arm64), Xcode 27.0 / Swift 6.4

**Run date:** 2026-11-18

**Command:** `Scripts/run-checks.sh` with SwiftPM using the selected Xcode 27 toolchain
**Result:** 27 automated groups passed, 0 failed, 0 skipped. The local harness executed 33 distinct input/output format pairs, including ZIP ↔ 7z, plus PDF page-range extraction, PDF compression, video trimming and compression, batch rename copies, and safe metadata-copy editing with real generated files. The same result was reproduced by running the x86_64 harness under Rosetta.

The harness checks that each conversion output exists and is non-empty, runs `OutputValidator`, verifies the generated content or media properties where practical, and checks SHA-256 of the original file before and after conversion. Fixtures are generated locally; no network service is used for conversion. A separate opt-in live check exercised the bottle-size estimator against Homebrew's formula API and GHCR.

## Format-pair report

| Input → output | Engine | Result and validation |
|---|---|---|
| PNG → JPEG | Apple ImageIO | Passed; decoded and verified 48 × 32 dimensions. |
| JPEG → TIFF | Apple ImageIO | Passed; ImageIO decoded output. |
| PNG → PDF | Apple PDFKit | Passed; PDFKit reported one page. |
| PNG → WebP | ImageMagick 7.1.2 | Passed; ImageIO decoded output. |
| PNG → ICO | ImageMagick 7.1.2 | Passed; ImageIO and ImageMagick identified six icon images at 256, 128, 64, 48, 32 and 16 pixels. |
| WAV → MP3 | FFmpeg 8.1.1 | Passed; FFprobe recognized output container. |
| MP3 → WAV | FFmpeg 8.1.1 | Passed; FFprobe recognized output container. |
| MP4 → WebM | FFmpeg 8.1.1 | Passed; FFprobe recognized output container. |
| MP4 → MP3 | FFmpeg 8.1.1 | Passed; audio extraction output recognized by FFprobe. |
| MP4 → trimmed MP4 clip | FFmpeg 8.1.1 | Passed; generated a real two-second source, trimmed 0.25–0.90 seconds, verified MP4 validity and output duration with FFprobe, checked collision-safe naming and confirmed the source SHA-256 was unchanged. |
| Markdown → DOCX | Pandoc 3.9.0.2 | Passed; DOCX ZIP package integrity checked. |
| DOCX → HTML | Pandoc 3.9.0.2 | Passed; expected document text preserved. |
| PDF → TXT | Poppler 26.04.0 | Passed; expected text preserved. |
| CSV → XLSX | LibreOffice 26.2.3.2 | Passed; XLSX ZIP package integrity checked. |
| XLSX → CSV | LibreOffice 26.2.3.2 | Passed; expected cell text preserved. |
| JSON → CSV | Morph structured-data engine | Passed; quoted/comma-containing values preserved. |
| CSV → JSON | Morph structured-data engine | Passed; expected field values preserved. |
| JSON → XML | Morph structured-data engine | Passed; expected text present. |
| XML → JSON | Morph structured-data engine | Passed; JSON parser accepted output. |
| CSV → TSV | Morph structured-data engine | Passed; conversion round-tripped. |
| TSV → CSV | Morph structured-data engine | Passed; row content preserved. |
| JSON → YAML | Morph structured-data engine | Passed; generated YAML reparsed and expected values were preserved. |
| YAML → JSON | Morph structured-data engine | Passed; YAML 1.2 boolean/string semantics and expected values were preserved. |
| JSON → TOML | Morph structured-data engine | Passed; generated TOML reparsed and expected values were preserved. |
| TOML → JSON | Morph structured-data engine | Passed; parsed output retained string, boolean and nested values. |
| YAML → TOML | Morph structured-data engine | Passed; compatible values converted to TOML. |
| TOML → YML | Morph structured-data engine | Passed; generated YAML reparsed successfully. |
| YML → JSON | Morph structured-data engine | Passed; parsed output retained the expected structured values. |
| ZIP → TAR.GZ | macOS archive tools | Passed; resulting TAR.GZ listed successfully. |
| TAR.GZ → ZIP | macOS archive tools | Passed; ZIP integrity and expected member checked. |
| TIFF → JPEG | Apple ImageIO | Passed as part of a two-file batch; decoded, collision-safe name verified. |

### Optional-engine pairs

| Input → output | Engine | Result and validation |
|---|---|---|
| ZIP → 7z | 7-Zip (`sevenzip` Homebrew formula) | Passed on the macOS 26 arm64 runner in [Actions run 44224494535](https://github.com/Lakshay-13/morph/actions/runs/44224494535) and locally with `sevenzip 26.06`; generated archives passed `7zz t`, and source checksums stayed unchanged. |
| 7z → ZIP | 7-Zip (`sevenzip` Homebrew formula) | Passed in the same CI and local round trips; ZIP outputs passed integrity checking and retained the expected payload text. |

The user approved installing `sevenzip`; Homebrew installed version **26.06** at `/opt/homebrew/bin/7zz`. The installed app's Engines screen now lists 7-Zip and its ZIP ↔ 7z capabilities. Using the installed Finder helper, ZIP → 7z completed and passed `7zz t`; 7z → ZIP completed, passed `unzip -t`, and preserved the expected `readme.txt` content. Both original archives remained unchanged.

`swift run MorphChecks --estimate-homebrew-bottle sevenzip` exercised the Swift network path against the current arm64/tahoe bottle and returned **1,883,515 bytes**. The estimator uses an authenticated GHCR `HEAD` request after the registry's anonymous pull-only challenge; it does not download the bottle.

The current arm64 **0.1.0** app was rebuilt and installed at `~/Applications/Morph.app`. `codesign --verify --deep --strict` passed, PlugInKit reports `com.lakshaychawla.Morph.FinderSync` enabled, and the app, helper, and Finder extension are running from the installed bundle. The main app was relaunched with `--morph-background`; the persistent helper remains available for Finder conversions.

The current working tree was also packaged as `dist/release-0.1.0-current/Morph-0.1.0-macOS-universal.zip` (**8.6 MB**). `lipo` confirmed both `arm64` and `x86_64` slices in Morph, MorphQuickConvert and MorphFinderSync. Deep strict signature verification, ZIP integrity and the recorded SHA-256 check passed. This artifact is ad-hoc signed and was not submitted to Apple notarization or assessed by Gatekeeper.

Batch checks also converted a PNG and TIFF to JPEG while preserving checksums and preserving an existing destination as `same-2.jpg` and `same-3.jpg`.

## Additional checks

| Check | Result |
|---|---|
| Route-aware conversion presets | Passed; tested output-route filtering, mixed input rejection, supported video/audio/document selections, case-insensitive extensions and the WebP 80% quality override. |
| Image resize to 50% | Passed; a 160 × 80 PNG produced an 80 × 40 JPEG, source checksum unchanged. |
| PDF merge and split | Passed; two one-page PDFs merged to two pages and split back into two one-page PDFs. Input checksums unchanged. |
| PDF page-range extraction | Passed; selecting pages `2, 1` preserved requested order; invalid, duplicate and out-of-bounds selections were rejected; a repeated extraction used a collision-safe filename. Source checksum unchanged. |
| PDF compression | Passed with Ghostscript 10.07.0 and the Balanced preset; PDFKit reopened the output with the same page count and source text, the input checksum stayed unchanged, and no staging file remained. |
| Video trim range validation | Passed; accepted a finite, non-negative start and later end, rejected negative, equal, descending and non-finite ranges, and rejected an end beyond the source duration without leaving output files. |
| Video compression | Passed with FFmpeg using a generated high-bitrate 1080p source; produced H.264/AAC MP4 below the 720p limit, preserved duration and source SHA-256, reduced file size, selected a collision-safe second output, and left no partial file after invalid input. |
| LibreOffice route family constraints | Passed; DOCX, PPTX and XLSX each expose PDF export, while document ↔ spreadsheet and presentation → spreadsheet routes are not advertised. |
| ZIP extraction | Passed; extracted file content matched, ZIP checksum unchanged. |
| ZIP traversal and symlink rejection | Passed; Info-ZIP fixtures containing `../outside.txt` and a symlink to an outside file were rejected. No traversal output directory or symlink-extracted content remained, and the outside target checksum was unchanged. |
| Image/PDF metadata inspection | Passed; ImageIO reported PNG dimensions and file size; PDFKit reported page count, title and author. Source checksums stayed unchanged. Invalid image metadata was rejected without modifying the file. |
| Safe metadata copy editing | Passed for PDF title, author, subject and keywords, plus JPEG/TIFF title, subject and keywords. PDF page count and image dimensions/frame counts were preserved; source checksums stayed unchanged; collisions, unsupported formats, invalid input, empty edits and unsupported image-author edits were rejected without partial outputs. |
| Invalid image input | Passed; conversion failed, original remained unchanged, no partial output remained. |
| Missing FFmpeg route | Passed; reported the missing engine before creating an output directory. |
| Engine fallback | Passed; an injected failing ImageMagick adapter fell back to ImageIO, produced a valid JPEG and left no partial file. |
| Cancellation | Passed; cancelled child process stopped within the 3-second test limit. |
| Large image | Passed; converted a locally generated 2048 × 2048 noisy PNG larger than 12 MB and kept the source unchanged. |
| Conversion staging cleanup | Passed; no `.morph-*.staging` directory or `.partial` file remained after PNG → ICO or after failed/fallback engine attempts. |
| YAML/TOML validation and safety limits | Passed; output validation reparsed generated documents, YAML 1.2 kept `on` and bare dates as strings, a multi-document YAML input was rejected without output, and original JSON/YAML SHA-256 hashes were unchanged. |
| Batch rename copies | Passed; previewed numbered names across inputs from different folders, preserved the full `.tar.gz` suffix, resolved an existing destination collision, copied exact file contents, rejected unsafe prefixes and symbolic-link inputs, preserved originals and existing outputs, and removed staging files. |
| Installed app and Finder integration (earlier Quick Action build) | Passed for an earlier Morph 0.1.0 build at `~/Applications/Morph.app`, which was universal (`arm64 x86_64`). Finder's right-click Quick Actions submenu displayed **Convert with Morph**; invoking it on a selected PDF imported that exact file into Morph. Finder Services and the installed Automator workflow CLI also imported selected files and consumed their temporary manifests. This integration was superseded by the Finder Sync submenu; see the latest live check below. |
| Earlier windowless Quick Action handoff | Partially verified; invoking **Convert with Morph** on a selected PNG launched the accessory helper, and the main Morph app remained closed. The helper stayed running while handling the request but the original implementation terminated it when idle; the persistent background behavior is verified below. The CUA accessibility surface did not expose the helper popover's format rows, so that earlier popover flow was not fully verified. The selection-aware format catalog and PNG → JPEG route passed in the automated harness. |
| Installed Operations screen | Passed; refreshed and launched the installed universal 0.1.0 app, opened the Operations page, and opened then cancelled its native multi-file picker. Batch-copy execution itself was validated by the automated core harness rather than through the installed UI. |
| Installed app conversion | Passed; the installed 0.1.0 app converted the Finder fixture PNG to JPEG through its UI. `sips` identified a non-empty 1254 × 1254 JPEG; the original PNG SHA-256 remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`. |
| Installed YAML/TOML conversions | Passed live in installed Morph 0.1.0. YAML → JSON was selected through the native file picker from the workspace; TOML → JSON ran after invoking the installed Automator Quick Action; the installed universal build also converted YAML → TOML. Python's JSON parser and TOML parser validated expected values including YAML's `on` string, source SHA-256 checks matched before and after, and the existing destination was preserved with a collision-safe `settings-2.json` name. |
| Installed conversion presets | Passed live in the installed app. With a PNG selected, the Presets menu showed Images to JPEG and Images to WebP · 80%; unavailable video, audio and document presets were absent. Selecting WebP converted the sample to a valid 1254 × 1254 WebP (150,032 bytes); the input SHA-256 remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`. |
| Installed metadata inspection | Passed live in the updated 0.1.0 app. The installed Finder workflow imported `Morph-metadata-smoke.png`; the inspector displayed its PNG format, 1.6 MB size, 1254 × 1254 dimensions and RGB color model. The source file remained unchanged. |
| Installed metadata editing | Passed live in the refreshed 0.1.0 app. **Edit metadata…** created two separate one-page PDF copies; `pdfinfo` confirmed the requested title, author, subject and keywords. The source SHA-256 remained `8726054329c381568f1d895cdc8bf1edfb98d11bc04dcd1d2973b5cc9051a392` across the second save. |
| Installed PDF compression | Passed end to end from Finder's right-click Quick Actions menu: Morph imported the selected PDF, and **Compress PDF** produced a separate valid one-page PDF (276,382 bytes from a 1,452,001-byte source). `pdfinfo` validated the output; the original remained present at its original size. |
| Sidebar and engine manager UI | Passed; all five sidebar buttons navigate, and the Engines page showed the detected engine versions and routes. |
| Liquid Glass primary action and file picker | Passed on macOS 26.6.2; the installed universal app launched with its prominent system button style. Clicking **Choose Files** opened the native multi-file picker; Escape cancelled and returned to the overview. The macOS 14–25 bordered-button fallback compiled but was not runtime-tested on an older macOS version. Screenshot: [`morph-overview.png`](screenshots/morph-overview.png). |
| Installed PDF page-range extraction | Passed live through the installed Finder Quick Action. Extracting page 1 from a one-page PDF produced a valid one-page output; the original SHA-256 stayed `8164fc731e39b6a8cd42133347fef2d900e49f019e100c9ff653bd2becd293ec`. |
| Installed video trim | Passed in installed Morph 0.1.0 from the v15 package after importing the selected MP4 through the installed Finder Quick Action workflow. The Trim dialog generated a valid 0.6667-second H.264 MP4 from the requested 0.25–0.90-second interval; the original SHA-256 remained unchanged. |
| Installed video compression | Passed in the refreshed universal 0.1.0 app after importing two MP4s through the installed Quick Action handoff. The default Balanced/1080p settings created two valid 2.507-second H.264/AAC outputs totaling 2,434,720 bytes from 19,297,232-byte inputs (87% smaller); FFprobe confirmed codecs, dimensions and duration, and both input SHA-256 values remained unchanged. |
| Universal release package | Passed; `.build/release-d32f369/Morph-0.1.0-macOS-universal.zip` contains universal app and Finder helper binaries, the Quick Action, all four third-party license texts and Apache-2.0 license. `unzip -t`, `codesign --verify --deep --strict` and `shasum -a 256 -c` passed; SHA-256 is `b3fe4dcf51cccfec0315bb120ff421b3b08b286ce11a2e582c1e07f8ba3d4d30`. `spctl --assess` rejected its ad-hoc signature, so this local artifact is not eligible for public distribution. |
| Dependency consent cancellation | Passed; the live **Uninstall FFmpeg?** confirmation was opened and cancelled. Morph continued to show FFmpeg installed, and no Homebrew install, uninstall or upgrade process ran. No package was installed or removed. |

## GitHub Actions architecture coverage

[macOS CI run 44260749826](https://github.com/Lakshay-13/morph/actions/runs/44260749826) on commit `7b8b600` completed successfully.

| Runner | Validation | Result |
|---|---|---|
| macOS 26, x86_64 | Confirmed the runner architecture, installed the engines available for that architecture, built Morph, and ran the real-file conversion checks. LibreOffice and 7-Zip installs are skipped on Intel; their routes are capability-gated. | Passed. |
| macOS 26, arm64 | Confirmed the runner architecture, installed conversion engines including LibreOffice and 7-Zip, built Morph, and ran the real-file conversion checks, including ZIP ↔ 7z. | Passed. |
| macOS 26, arm64 universal-package job | Passed `brew audit --cask` and `brew style --cask`, built the release ZIP, verified arm64 and x86_64 slices in both the main app and Finder helper, confirmed the helper is an accessory app, verified the app signature and bundled license files, checked the ZIP and AppleDouble metadata, and matched the SHA-256 file. | Passed. |

The hosted Intel runner provides actual x86_64 conversion-runtime coverage. The final packaged app has not been installed and launched on a physical Intel Mac. The CI package is ad-hoc signed and is not a Gatekeeper-ready release.

## Limitations of this run

- The harness is a self-contained SwiftPM executable rather than XCTest.
- CoreGraphics emits a PDF diagnostic during fixture/PDF processing. PDFKit and Poppler checks still pass, and generated PDFs reopened with the expected page count/content.
- Cancellation was tested at the process-runner layer and the dependency consent Cancel button was exercised live. The earlier Quick Action conversion was tested end to end on a generated PDF. Mixed Finder testing now covers PNG + TIFF and a cross-category PNG + DOCX batch; larger selections and other Finder application contexts remain untested.
- Malicious ZIP validation covered parent traversal and one escaping symlink fixture. Decompression-bomb resource limits and a broader hostile archive corpus remain untested.
- This local run and the installed app smoke checks were performed on Apple Silicon. The separate GitHub Actions x86_64 runner passed its real-file conversion checks, but the packaged app has not been installed and launched on a physical Intel Mac.
- The hosted Cask audit and style checks passed using a temporary tap. On this Mac, the Homebrew audit cannot complete because Homebrew prefers `/Library/Developer/CommandLineTools` (SDK 14.4) whenever it exists, even though Xcode 27.0 is selected; that SDK does not support macOS 26. Cask install/uninstall checks remain unverified. The local and CI archives are ad-hoc signed and are not eligible for public distribution.
- Official Homebrew Cask submission is also premature under the current notability policy: GitHub reports that the upstream repository was created on 2026-11-17 with 0 stars. The policy normally excludes repositories under 30 days old and sets a 225-star or equivalent threshold for owner self-submissions. A project-maintained tap is the appropriate initial path once the release artifact is signed and notarized.
- The dependency confirmation and Cancel action were exercised live for an uninstall request. All supported optional engines are already installed, so a missing-Ghostscript install confirmation and automatic PDF retry could not be exercised on this Mac without first removing an engine.
- Earlier Finder Sync regression check: PlugInKit registered the extension, but Finder did not show its menu because the extension monitored its sandbox container rather than the user's real home directory. That path issue and the menu request handoff were fixed and retested below. The ad-hoc signature still prevents public release validation.
- CI run [44292850750](https://github.com/Lakshay-13/morph/actions/runs/44292850750) on `0cbcabd` passed both architecture test jobs but initially failed Cask style due to `caveats`/`zap` order. The follow-up run [44296420483](https://github.com/Lakshay-13/morph/actions/runs/44296420483) on `f9c7b94` passed Intel and Apple Silicon real-file checks, Homebrew Cask audit/style, and universal archive verification. 7-Zip and LibreOffice checks were skipped only on the Intel runner.

## Finder dispatch follow-up (2026-11-18)

- The earlier Finder dispatcher launched the accessory helper once with selected file URL(s) and the conversion request URL in one `NSWorkspace.open` operation. The final helper consumes the encoded request directly and acknowledges file-only events without waiting for a matching event; it remains a windowless accessory app.
- `Scripts/run-checks.sh` passed after adding an explicit PNG target check: **24 passed, 0 failed, 1 skipped**. 7-Zip was skipped because it is not installed. The test suite also exercises the PNG → JPEG route and selection intersection behavior.
- Installed the arm64 build at `~/Applications/Morph.app`. A live helper handoff converted a copied 1254×1254 PNG into a nonempty JPEG; the source hash matched the repository fixture afterward, and the main Morph app did not launch.
- At the time of this earlier check, Finder's right-click showed only Apple's built-in **Convert Image** Quick Action. PlugInKit registered and ran the extension, but it monitored the wrong home path and the submenu was absent. The later live submenu and no-window conversion results are recorded below. The installed app remains ad-hoc signed (`TeamIdentifier=not set`), which blocks public release validation.

## Apple signing portal follow-up (2026-11-18)

- The user completed browser sign-in. Opening **Certificates, IDs, & Profiles** still redirects to Apple's **Need assistance with accessing your developer account?** support form rather than certificate management.
- Xcode Manage Certificates lists an Apple Development certificate dated 2026-11-18, but its matching private key is missing. Xcode disables both **Create Apple Development** and **Delete Certificate** while this certificate remains active; `security find-identity -v -p codesigning` reports zero valid identities.
- No certificate was revoked or created. The approved replacement workflow cannot proceed until Apple restores certificate-portal access, an eligible team becomes available, or the matching `.p12` is recovered from a backup/original keychain. Developer ID signing and notarization remain unavailable.

## Editable Finder submenu verification (2026-11-18)

- `Scripts/run-checks.sh`: **24 passed, 0 failed, 1 skipped**. The skipped 7-Zip conversion needs 7-Zip, which is not installed. `git diff --check` passed.
- Built and installed arm64 Morph **0.1.0** at `~/Applications/Morph.app`. The release build, Finder Sync extension and accessory helper compiled; the helper and app bundles passed code-signature integrity checks using the local ad-hoc identity.
- Finder's right-click menu now shows **Convert To → Convert with Morph → [source → available output]**. On the PNG smoke fixture it offered PDF, AVIF, BMP, GIF, HEIC, HEIF, ICO, JPEG, SVG, TIFF and WebP. The app's **Settings → Finder conversion formats** checkboxes control which output formats Finder displays; hiding JPEG in Settings removed it, and **Show All** restored it. The saved hidden-output set is empty in the final installed state.
- From Finder, the installed helper converted the PNG to JPEG using Apple ImageIO and to WebP using ImageMagick. `sips` validated JPEG format and 1254 × 1254 dimensions; `magick identify` validated WEBP and 1254 × 1254 dimensions. The JPEG was 168,950 bytes and WebP 158,394 bytes. The source PNG SHA-256 remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`.
- Morph remained running minimized in the background while conversions completed; no Morph main window or format-picker window appeared. The helper provides progress and cancellation through its menu-bar status item.
- The Finder Sync item appears as its own contextual-menu entry beside macOS **Quick Actions**; Finder Sync does not let Morph insert a submenu inside Apple's built-in Quick Actions group. Morph's menu is source-aware and only includes routes available for every selected file. See the [Finder Sync API](https://developer.apple.com/documentation/FinderSync).
- The request is carried through the Finder menu item's integer tag into an encoded path/format URL. The helper queues that request directly instead of trying to correlate separate file-open and URL events; this fixed the earlier missing-selection handoff.

## Mixed Finder batch verification (2026-11-18)

- A two-file PNG + TIFF selection displayed the shared conversion menu with the source label **PNG + TIFF**. Selecting JPEG produced valid 1254 × 1254 outputs for both files. Because both inputs share the same base name, Morph preserved both results as `sample.jpg` and collision-safe `sample-2.jpg`; History recorded Apple ImageIO for each route.
- A cross-category PNG + DOCX selection displayed only the shared PDF route, labeled **DOCX + PNG → PDF**. The batch produced `sample.pdf` via Apple PDFKit and `mixed-note.pdf` via LibreOffice. `pdfinfo` validated each output as a one-page PDF. SHA-256 checks confirmed the PNG, TIFF and DOCX inputs were unchanged.
- Morph remained running in the background during both Finder batches; no main-app or format-picker window appeared.

## Persistent Finder helper verification (2026-11-18)

- The old helper called `terminateIfIdle()` after a request and removed its menu-bar item after showing the result. That left no helper ready for a later request, so persistent background behavior was added.
- An earlier Downloads test stalled while the helper read a selected path, and logs attributed that access request to the parent app ID `com.lakshaychawla.Morph` while the app was closed. This led to an initial TCC attribution hypothesis. The screenshot later supplied by the user showed a separate, confirmed failure: the sandboxed Finder Sync extension itself tried to open the selected file and Finder denied it.
- The helper stays running as a windowless accessory app after its first launch and starts the main app in hidden accessory mode when needed. File reads happen in the helper, whose bundle includes protected-folder usage descriptions. The helper menu offers **Open Morph** and **Quit Morph**, shows progress/cancellation while converting, and remains available while idle; Finder starts it on demand rather than at login.
- `Scripts/run-checks.sh`: **24 passed, 0 failed, 1 skipped**. 7-Zip conversion was skipped because 7-Zip is not installed. `git diff --check` passed.
- Built and installed arm64 Morph **0.1.0** at `~/Applications/Morph.app`. `codesign --verify --deep --strict` passed for the installed app, and PlugInKit lists the Finder Sync extension as enabled.
- Sent conversion requests to the installed helper via its `morphquick` request URL. Apple ImageIO converted a temporary PNG to JPEG and TIFF; `file` identified valid 1254 × 1254 JPEG and TIFF outputs. The input SHA-256 stayed unchanged.
- In the final installed build, helper PID **58032** handled both conversions, including a six-second idle interval. Finder showed the test folder with both outputs and no Morph window or “isn't open anymore” popup. This exercised the installed helper handoff directly; the context-menu click itself was verified in the preceding Finder submenu checks.

## Finder permission error follow-up (2026-11-18)

- The user-provided screenshot showed the sandboxed `MorphFinderSync` extension attempting to open `source.png`; this was a different failure from the earlier TCC attribution hypothesis. Finder Sync's `selectedItemURLs()` supplies menu-selection URLs, but the extension does not have read scope for those files.
- Removed the extension's `NSWorkspace.open(selection, withApplicationAt:)` call and its unnecessary user-selected-file entitlement. The extension now sends only the encoded path/format request to the helper and no longer registers as a generic file viewer. The helper validates bounded absolute paths and regular-file access before queueing a conversion; it has folder-usage descriptions for macOS Files & Folders authorization.
- Rebuilt and installed arm64 Morph **0.1.0** at `~/Applications/Morph.app`. `codesign --verify --deep --strict` passed, the Finder Sync extension is enabled, and its installed entitlements no longer include user-selected file access.
- The installed helper handled its Finder request URL for test PNGs in both `/Users/Shared` and `~/Downloads`, producing valid 1254 × 1254 JPEGs of 168,950 bytes. Both original input hashes remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`. The main Morph process stayed in hidden background mode; the helper remained running.
- A direct cold-start test then showed that Launch Services can start the helper without delivering its first custom URL event. The original fix included the encoded request in helper launch arguments and followed it with the same URL as a wake-up; this was later replaced by a sender-checked URL handoff with bounded retries, so request data is no longer placed in process arguments.
- Verified that first-use behavior through a fresh Finder right-click on `source.png` in Downloads while the helper was stopped. The installed menu showed **Convert To → Convert with Morph → PNG → JPEG** among 11 available PNG targets. The action produced `source-2.jpg` (168,950 bytes, valid 1254 × 1254 JPEG) beside the source, preserving the existing `source.jpg`; the input and existing output SHA-256 values stayed unchanged. Exactly one new output appeared.
- Finder remained frontmost through the conversion, with no permission-error alert or Morph conversion window interrupting the click. The helper stayed running in the background and the main app was launched with `--morph-background`.

## Finder archive conversion smoke test (2026-11-18)

- Added `EngineID.archive` to the Finder extension's lightweight fallback registry so ZIP → TAR.GZ and TAR.GZ → ZIP remain available before an app-published engine snapshot exists. The route-catalog regression check covers the ZIP → TAR.GZ fallback.
- Rebuilt and reinstalled arm64 Morph **0.1.0** at `~/Applications/Morph.app`. `Scripts/run-checks.sh` reported **24 passed, 0 failed, 1 skipped** (7-Zip is not installed); `codesign --verify --deep --strict` passed and PlugInKit lists Finder Sync as enabled.
- In Finder, selected a generated `source.zip` and chose **Convert To → Convert with Morph → ZIP → GZIP TAR archive (.tar.gz)**. The resulting TAR.GZ was non-empty, `file` identified gzip data, and `tar` listed `readme.txt` whose extracted contents matched the input fixture. The source ZIP hash remained `82cb10a7a0bfbc9a0fb0df0d08f60ad5a1555f5a0ca0e9ea5b3c38ecb06cdd63`.
- Finder stayed in front during conversion; Morph's hidden app process and persistent helper remained running. The temporary fixture was removed after validation.

## Finder request sender validation (2026-11-18)

- Replaced the helper's default custom-URL handling with an `NSAppleEventManager` handler. Before decoding or accessing any paths, it checks `keySenderPIDAttr` against the running process's Finder Sync bundle identifier and exact embedded extension URL. Removed conversion payloads from helper launch arguments.
- The extension now declines selections over 100 files, paths over 4,096 bytes, or serialized requests over 512 KB; the helper rejects encoded URL payloads over 700 KB before Base64 decoding.
- Cold start now opens the helper without arguments, then sends the same request URL three times over 1.2 seconds. The existing request UUID makes those retries idempotent.
- A test harness launched a `morphquick://convert` URL from outside Finder with a valid synthetic PNG path; no output was created. With the helper then stopped, the Finder menu accepted the same kind of conversion request on cold start and produced one valid 1 × 1 JPEG. Both PNG fixture hashes remained `074f6eab0286b8e2e73ade738dbc0b925207bf0e84b5f6e1f041003e4a8cb791`.
- The installed helper and hidden main process remained available afterward; no Morph conversion window opened. `MorphQuickConvert` release compilation and the full arm64 app build passed. The full `Scripts/run-checks.sh` suite reported **24 passed, 0 failed, 1 skipped** (7-Zip is not installed).
- Rebuilt and reinstalled the final arm64 **0.1.0** bundle with the request-size limits. The fresh Finder right-click produced a valid 1 × 1 JPEG (776 bytes); the PNG hash stayed `074f6eab0286b8e2e73ade738dbc0b925207bf0e84b5f6e1f041003e4a8cb791`. `codesign --verify --deep --strict` passed, PlugInKit lists Finder Sync as enabled, and the helper plus hidden app remained running with Finder in front. This final temporary fixture was removed after validation.

## Fresh Finder process verification (2026-11-18)

- The installed extension binary had been rebuilt after the running Finder Sync process started, so that process still held the older implementation in memory. Re-registering the updated extension and restarting Morph's idle hidden host/helper caused Finder to launch the new processes on the next contextual-menu action.
- In Finder, selected a generated 1 × 1 `source.png` and chose **Convert To → Convert with Morph → PNG → JPEG**. Finder created a valid 1 × 1 `source.jpg`; the original PNG SHA-256 remained `4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5`.
- The menu closed without a permission alert, Finder stayed frontmost, and no Morph conversion window opened. The updated Finder Sync extension, hidden Morph host, and helper remained running afterward. The temporary source and output were removed after validation.
- `Scripts/run-checks.sh`: **24 passed, 0 failed, 1 skipped** (7-Zip is not installed). The arm64 app rebuilt and installed at `~/Applications/Morph.app`; `codesign --verify --deep --strict` passed and PlugInKit lists the extension as enabled.

## Installed metadata editing verification (2026-11-18)

- The installed Morph process had started before the latest build was copied into place, so its in-memory UI did not show the new metadata editor. Restarted the idle main Morph process and reopened the installed 0.1.0 app; no conversion helper or Finder setting was changed.
- Loaded a generated one-page PDF, opened **Edit metadata…**, and saved a copy with title, author, subject and keywords. `pdfinfo` confirmed all four fields and one page in the output; the app reported that the original was unchanged.
- Repeated the edit after recording the original SHA-256. The second copy was a valid one-page PDF with the expected metadata, and the source SHA-256 remained `8726054329c381568f1d895cdc8bf1edfb98d11bc04dcd1d2973b5cc9051a392`.
- `Scripts/run-checks.sh`: **25 passed, 0 failed, 1 skipped**. 7-Zip conversion was skipped because 7-Zip is not installed. The CoreGraphics PDF diagnostic appeared during fixture processing; PDFKit and `pdfinfo` validated the generated PDFs.

## Current universal build and Intel-slice validation (2026-11-18)

- Packaged the current working tree with `Scripts/package-release.sh` into an isolated temporary directory. `lipo` confirmed both `arm64` and `x86_64` slices in the Morph app, conversion helper and Finder Sync extension. The app passed `codesign --verify --deep --strict`, the archive passed `unzip -t`, and the generated SHA-256 matched its checksum file.
- Built the current `MorphChecks` harness for `x86_64` in the project's debug configuration and ran it through Rosetta on this Apple Silicon Mac: **25 passed, 0 failed, 1 skipped** (7-Zip unavailable).
- This verifies that the x86_64 code builds and executes under Rosetta on this Mac; it does not replace testing installation and Finder behavior on a physical Intel Mac. The local archive is ad-hoc signed and remains unsuitable for public distribution.
