# Test report

**Run on:** macOS 26.6.2, Apple M3 Max (arm64), Xcode 27.0 / Swift 6.4

**Run date:** 2026-11-18

**Command:** `Scripts/run-checks.sh` with SwiftPM using the selected Xcode 27 toolchain
**Result:** 24 automated groups passed, 0 failed, 1 skipped. The local harness executed 31 distinct input/output format pairs, PDF page-range extraction, PDF compression, video trimming and compression, and batch rename copies with real generated files. The 7-Zip conversion group was skipped locally because `7zz`/`7z` is not installed; the archive listing safety group passed.

The harness checks that each conversion output exists and is non-empty, runs `OutputValidator`, verifies the generated content or media properties where practical, and checks SHA-256 of the original file before and after conversion. Fixtures are generated locally; no network service is used for conversion.

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

### CI-only optional-engine pairs

| Input → output | Engine | Result and validation |
|---|---|---|
| ZIP → 7z | 7-Zip (`sevenzip` Homebrew formula) | Passed on the macOS 26 arm64 runner in [Actions run 44224494535](https://github.com/Lakshay-13/morph/actions/runs/44224494535); generated archive passed `7zz t`, and the source ZIP checksum remained unchanged. |
| 7z → ZIP | 7-Zip (`sevenzip` Homebrew formula) | Passed in the same round trip; the ZIP output passed integrity checking and retained the expected payload text. |

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
| Invalid image input | Passed; conversion failed, original remained unchanged, no partial output remained. |
| Missing FFmpeg route | Passed; reported the missing engine before creating an output directory. |
| Engine fallback | Passed; an injected failing ImageMagick adapter fell back to ImageIO, produced a valid JPEG and left no partial file. |
| Cancellation | Passed; cancelled child process stopped within the 3-second test limit. |
| Large image | Passed; converted a locally generated 2048 × 2048 noisy PNG larger than 12 MB and kept the source unchanged. |
| Conversion staging cleanup | Passed; no `.morph-*.staging` directory or `.partial` file remained after PNG → ICO or after failed/fallback engine attempts. |
| YAML/TOML validation and safety limits | Passed; output validation reparsed generated documents, YAML 1.2 kept `on` and bare dates as strings, a multi-document YAML input was rejected without output, and original JSON/YAML SHA-256 hashes were unchanged. |
| Batch rename copies | Passed; previewed numbered names across inputs from different folders, preserved the full `.tar.gz` suffix, resolved an existing destination collision, copied exact file contents, rejected unsafe prefixes and symbolic-link inputs, preserved originals and existing outputs, and removed staging files. |
| Installed app and Finder integration (earlier Quick Action build) | Passed for an earlier Morph 0.1.0 build at `~/Applications/Morph.app`, which was universal (`arm64 x86_64`). Finder's right-click Quick Actions submenu displayed **Convert with Morph**; invoking it on a selected PDF imported that exact file into Morph. Finder Services and the installed Automator workflow CLI also imported selected files and consumed their temporary manifests. This integration was superseded by the Finder Sync submenu; see the latest live check below. |
| Earlier windowless Quick Action handoff | Partially verified; invoking **Convert with Morph** on a selected PNG launched the accessory helper, and the main Morph app remained closed. The helper stayed running after the handoff. The CUA accessibility surface did not expose the helper popover's format rows, so that earlier popover flow was not fully verified. The selection-aware format catalog and PNG → JPEG route passed in the automated harness. |
| Installed Operations screen | Passed; refreshed and launched the installed universal 0.1.0 app, opened the Operations page, and opened then cancelled its native multi-file picker. Batch-copy execution itself was validated by the automated core harness rather than through the installed UI. |
| Installed app conversion | Passed; the installed 0.1.0 app converted the Finder fixture PNG to JPEG through its UI. `sips` identified a non-empty 1254 × 1254 JPEG; the original PNG SHA-256 remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`. |
| Installed YAML/TOML conversions | Passed live in installed Morph 0.1.0. YAML → JSON was selected through the native file picker from the workspace; TOML → JSON ran after invoking the installed Automator Quick Action; the installed universal build also converted YAML → TOML. Python's JSON parser and TOML parser validated expected values including YAML's `on` string, source SHA-256 checks matched before and after, and the existing destination was preserved with a collision-safe `settings-2.json` name. |
| Installed conversion presets | Passed live in the installed app. With a PNG selected, the Presets menu showed Images to JPEG and Images to WebP · 80%; unavailable video, audio and document presets were absent. Selecting WebP converted the sample to a valid 1254 × 1254 WebP (150,032 bytes); the input SHA-256 remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`. |
| Installed metadata inspection | Passed live in the updated 0.1.0 app. The installed Finder workflow imported `Morph-metadata-smoke.png`; the inspector displayed its PNG format, 1.6 MB size, 1254 × 1254 dimensions and RGB color model. The source file remained unchanged. |
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
- Cancellation was tested at the process-runner layer and the dependency consent Cancel button was exercised live. The earlier Quick Action conversion was tested end to end on a generated PDF; the new Finder Sync submenu is not live-verified. Mixed selections and other Finder application contexts were not exhaustively exercised.
- Malicious ZIP validation covered parent traversal and one escaping symlink fixture. Decompression-bomb resource limits and a broader hostile archive corpus remain untested.
- This local run and the installed app smoke checks were performed on Apple Silicon. The separate GitHub Actions x86_64 runner passed its real-file conversion checks, but the packaged app has not been installed and launched on a physical Intel Mac.
- The hosted Cask audit and style checks passed using a temporary tap. On this Mac, the Homebrew audit cannot complete because Homebrew prefers `/Library/Developer/CommandLineTools` (SDK 14.4) whenever it exists, even though Xcode 27.0 is selected; that SDK does not support macOS 26. Cask install/uninstall checks remain unverified. The local and CI archives are ad-hoc signed and are not eligible for public distribution.
- Official Homebrew Cask submission is also premature under the current notability policy: GitHub reports that the upstream repository was created on 2026-11-17 with 0 stars. The policy normally excludes repositories under 30 days old and sets a 225-star or equivalent threshold for owner self-submissions. A project-maintained tap is the appropriate initial path once the release artifact is signed and notarized.
- The dependency confirmation and Cancel action were exercised live for an uninstall request. All supported optional engines are already installed, so a missing-Ghostscript install confirmation and automatic PDF retry could not be exercised on this Mac without first removing an engine.
- Latest Finder Sync regression check: the arm64 app and extension built and installed, and PlugInKit registered the extension, but Finder did not show the new **Convert To → Convert with Morph** menu on a fresh right-click of the repository's PNG. The extension process was running. The installed extension is ad-hoc signed with no Team ID, and `security find-identity -v -p codesigning` reports zero usable identities. Xcode reports a current or pending Apple Development certificate, but its matching private key is unavailable locally. The Finder menu click, direct PNG → JPEG conversion through that menu and no-window behavior for that exact workflow are therefore unverified; previous tests in this report exercised the older Quick Action workflow.
- CI run [44292850750](https://github.com/Lakshay-13/morph/actions/runs/44292850750) on `0cbcabd` passed both architecture test jobs but initially failed Cask style due to `caveats`/`zap` order. The follow-up run [44296420483](https://github.com/Lakshay-13/morph/actions/runs/44296420483) on `f9c7b94` passed Intel and Apple Silicon real-file checks, Homebrew Cask audit/style, and universal archive verification. 7-Zip and LibreOffice checks were skipped only on the Intel runner.

## Finder dispatch follow-up (2026-11-18)

- Updated Finder dispatch to launch the accessory helper once with the selected file URL(s) and conversion request URL in a single `NSWorkspace.open` operation. The helper already accepts both event types in either order and remains an accessory app without a document window or format picker.
- `Scripts/run-checks.sh` passed after adding an explicit PNG target check: **24 passed, 0 failed, 1 skipped**. 7-Zip was skipped because it is not installed. The test suite also exercises the PNG → JPEG route and selection intersection behavior.
- Installed the arm64 build at `~/Applications/Morph.app`. A live helper handoff converted a copied 1254×1254 PNG into a nonempty JPEG; the source hash matched the repository fixture afterward, and the main Morph app did not launch.
- Finder's live right-click still shows only Apple's built-in **Convert Image** Quick Action; Morph's custom submenu is absent. PlugInKit registers and runs the extension, but the installed app is ad-hoc signed (`TeamIdentifier=not set`), and the machine has no usable signing identity. The Finder submenu click-through and its no-window behavior remain unverified until a valid signed build can be tested.
