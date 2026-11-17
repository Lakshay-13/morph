# Test report

**Run on:** macOS 26.6.2, Apple M3 Max (arm64)

**Run date:** 2026-11-17

**Command:** `Scripts/run-checks.sh` with SwiftPM using the installed Command Line Tools
**Result:** 12 automated groups passed, 0 failed, 0 skipped. Twenty-three distinct input/output format pairs were executed with real generated files.

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
| Image resize to 50% | Passed; a 160 × 80 PNG produced an 80 × 40 JPEG, source checksum unchanged. |
| PDF merge and split | Passed; two one-page PDFs merged to two pages and split back into two one-page PDFs. Input checksums unchanged. |
| ZIP extraction | Passed; extracted file content matched, ZIP checksum unchanged. |
| Invalid image input | Passed; conversion failed, original remained unchanged, no partial output remained. |
| Missing FFmpeg route | Passed; reported the missing engine before creating an output directory. |
| Engine fallback | Passed; an injected failing ImageMagick adapter fell back to ImageIO, produced a valid JPEG and left no partial file. |
| Cancellation | Passed; cancelled child process stopped within the 3-second test limit. |
| Large image | Passed; converted a locally generated 2048 × 2048 noisy PNG larger than 12 MB and kept the source unchanged. |
| Conversion staging cleanup | Passed; no `.morph-*.staging` directory or `.partial` file remained after PNG → ICO or after failed/fallback engine attempts. |
| Installed app and Finder integration | Passed; installed Morph 0.1.0 at `~/Applications/Morph.app` is universal (`arm64 x86_64`). Finder's right-click Quick Actions submenu displayed **Convert with Morph**. The Finder Services menu also listed the enabled action; invoking it imported a selected PNG into Morph. The installed Automator workflow CLI independently imported the same fixture and consumed its temporary manifest. A direct click on the Quick Actions submenu item was not confirmed. |
| Installed app conversion | Passed; the installed 0.1.0 app converted the Finder fixture PNG to JPEG through its UI. `sips` identified a non-empty 1254 × 1254 JPEG; the original PNG SHA-256 remained `dec0374ba45276a3c08ac50fb11f3569ecca20198741eff419d5eaa3dd6c31a0`. |
| Sidebar and engine manager UI | Passed; all five sidebar buttons navigate, and the Engines page showed the detected engine versions and routes. |
| Dependency consent cancellation | Passed; the live **Uninstall FFmpeg?** confirmation was opened and cancelled. Morph continued to show FFmpeg installed, and no Homebrew install, uninstall or upgrade process ran. No package was installed or removed. |

## Limitations of this run

- The harness is a self-contained SwiftPM executable rather than XCTest. SwiftPM emits a non-fatal XCTest path warning because the selected Command Line Tools SDK cannot answer `xcrun --show-sdk-platform-path`; the executable and all 12 groups still build and run.
- CoreGraphics emits a PDF diagnostic during fixture/PDF processing. PDFKit and Poppler checks still pass, and generated PDFs reopened with the expected page count/content.
- Cancellation was tested at the process-runner layer and the dependency consent Cancel button was exercised live. The installed Finder context menu showed the Quick Action, but only Finder Services and Automator CLI execution were used to invoke it; the Quick Actions submenu item itself was not clicked successfully.
- Archive traversal rejection is implemented, but this run exercised safe ZIP extraction rather than a malicious traversal ZIP fixture.
- The app and all real conversions were executed on Apple Silicon. An Intel runtime was not available for validation.
- The Homebrew Cask draft passes Ruby syntax validation, but Homebrew audit/install checks remain unverified because Homebrew refuses to run until the Xcode license is accepted. The local release archive is ad hoc signed, so it is not eligible for public Cask submission.
