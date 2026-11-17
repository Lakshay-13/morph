# Test report

**Run on:** macOS 26.6.2, Apple M3 Max (arm64), Xcode 27.0 / Swift 6.4

**Run date:** 2026-11-18

**Command:** `Scripts/run-checks.sh` with SwiftPM using the selected Xcode 27 toolchain
**Result:** 15 automated groups passed, 0 failed, 0 skipped. Twenty-three distinct input/output format pairs and one PDF compression operation were executed with real generated files.

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
| ZIP → TAR.GZ | macOS archive tools | Passed; resulting TAR.GZ listed successfully. |
| TAR.GZ → ZIP | macOS archive tools | Passed; ZIP integrity and expected member checked. |
| TIFF → JPEG | Apple ImageIO | Passed as part of a two-file batch; decoded, collision-safe name verified. |

Batch checks also converted a PNG and TIFF to JPEG while preserving checksums and preserving an existing destination as `same-2.jpg` and `same-3.jpg`.

## Additional checks

| Check | Result |
|---|---|
| Route-aware conversion presets | Passed; tested output-route filtering, mixed input rejection, supported video/audio/document selections, case-insensitive extensions and the WebP 80% quality override. |
| Image resize to 50% | Passed; a 160 × 80 PNG produced an 80 × 40 JPEG, source checksum unchanged. |
| PDF merge and split | Passed; two one-page PDFs merged to two pages and split back into two one-page PDFs. Input checksums unchanged. |
| PDF compression | Passed with Ghostscript 10.07.0 and the Balanced preset; PDFKit reopened the output with the same page count and source text, the input checksum stayed unchanged, and no staging file remained. |
| LibreOffice route family constraints | Passed; DOCX, PPTX and XLSX each expose PDF export, while document ↔ spreadsheet and presentation → spreadsheet routes are not advertised. |
| ZIP extraction | Passed; extracted file content matched, ZIP checksum unchanged. |
| Invalid image input | Passed; conversion failed, original remained unchanged, no partial output remained. |
| Missing FFmpeg route | Passed; reported the missing engine before creating an output directory. |
| Engine fallback | Passed; an injected failing ImageMagick adapter fell back to ImageIO, produced a valid JPEG and left no partial file. |
| Cancellation | Passed; cancelled child process stopped within the 3-second test limit. |
| Large image | Passed; converted a locally generated 2048 × 2048 noisy PNG larger than 12 MB and kept the source unchanged. |
| Conversion staging cleanup | Passed; no `.morph-*.staging` directory or `.partial` file remained after PNG → ICO or after failed/fallback engine attempts. |
| Installed app and Finder integration | Passed; installed Morph 0.1.0 at `~/Applications/Morph.app` is universal (`arm64 x86_64`). Finder's right-click Quick Actions submenu displayed **Convert with Morph**; invoking it on a selected PDF imported that exact file into Morph. Finder Services and the installed Automator workflow CLI also imported selected files and consumed their temporary manifests. |
| Installed app conversion | Passed; the installed 0.1.0 app converted the Finder fixture PNG to JPEG through its UI. `sips` identified a non-empty 1254 × 1254 JPEG; the original PNG SHA-256 remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`. |
| Installed conversion presets | Passed live in the installed app. With a PNG selected, the Presets menu showed Images to JPEG and Images to WebP · 80%; unavailable video, audio and document presets were absent. Selecting WebP converted the sample to a valid 1254 × 1254 WebP (150,032 bytes); the input SHA-256 remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`. |
| Installed PDF compression | Passed end to end from Finder's right-click Quick Actions menu: Morph imported the selected PDF, and **Compress PDF** produced a separate valid one-page PDF (276,382 bytes from a 1,452,001-byte source). `pdfinfo` validated the output; the original remained present at its original size. |
| Sidebar and engine manager UI | Passed; all five sidebar buttons navigate, and the Engines page showed the detected engine versions and routes. |
| Liquid Glass primary action and file picker | Passed on macOS 26.6.2; the installed universal app launched with its prominent system button style. Clicking **Choose Files** opened the native multi-file picker; Escape cancelled and returned to the overview. The macOS 14–25 bordered-button fallback compiled but was not runtime-tested on an older macOS version. Screenshot: [`morph-overview.png`](screenshots/morph-overview.png). |
| Universal release package | Passed; built arm64 + x86_64 app, `unzip -t` reported no archive errors, and `shasum -a 256 -c` verified the package hash. The package is ad-hoc signed and not eligible for public distribution. |
| Dependency consent cancellation | Passed; the live **Uninstall FFmpeg?** confirmation was opened and cancelled. Morph continued to show FFmpeg installed, and no Homebrew install, uninstall or upgrade process ran. No package was installed or removed. |

## Limitations of this run

- The harness is a self-contained SwiftPM executable rather than XCTest.
- CoreGraphics emits a PDF diagnostic during fixture/PDF processing. PDFKit and Poppler checks still pass, and generated PDFs reopened with the expected page count/content.
- Cancellation was tested at the process-runner layer and the dependency consent Cancel button was exercised live. Finder context-menu conversion was tested end to end on a generated PDF; mixed selections and other Finder application contexts were not exhaustively exercised.
- Archive traversal rejection is implemented, but this run exercised safe ZIP extraction rather than a malicious traversal ZIP fixture.
- The app and all real conversions were executed on Apple Silicon. An Intel runtime was not available for validation.
- The Homebrew Cask draft passes Ruby syntax validation. After updating Homebrew to 7.0.14, `brew audit --cask distribution/homebrew/morph.rb` failed because the installed standalone Command Line Tools 15.4 do not support macOS 26; Homebrew requests Command Line Tools for Xcode 27.0. `softwareupdate --list` offered no CLT package, and `xcode-select --install` reported that tools are already installed. Cask audit/install checks are therefore unverified. The local release archive is ad-hoc signed and is not eligible for public Cask submission.
- The dependency confirmation and Cancel action were exercised live for an uninstall request. All supported optional engines are already installed, so a missing-Ghostscript install confirmation and automatic PDF retry could not be exercised on this Mac without first removing an engine. Homebrew package actions remain unverified while its Command Line Tools requirement is unmet.
