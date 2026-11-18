# Release, signing and Homebrew

## Local release package

The packaging script attempts an arm64 + x86_64 universal app, a versioned ZIP archive and a SHA-256 checksum:

```sh
MORPH_VERSION=0.1.0 MORPH_DIST_DIR="$PWD/release-output" Scripts/package-release.sh
```

The ZIP contains `Morph.app`, the Finder Quick Action workflow, Morph's Apache license and third-party license notices. The app bundle also carries those notices in `Contents/Resources/Legal`. The ZIP is ignored by Git. Keep the exact tested archive and its checksum together. Do not publish the current ad-hoc build.

The latest local package is `.build/release-final-2/Morph-0.1.0-macOS-universal.zip` (arm64 + x86_64), SHA-256 `eebbb45c3b4ce32198ef857a100adcf698041628cfd276ac988f5fb38412b5c1`. Its ZIP integrity, code signature, license files and checksum were verified. It is a local validation artifact, not a GitHub release; it is ad-hoc signed, fails Gatekeeper assessment and must not be used for the public Cask. The draft Cask carries this local checksum as a placeholder; replace it with the final signed/notarized archive's checksum.

## Developer ID signing and notarization

Current machine status (2026-11-18): Xcode 27.0 is selected and its license is accepted. The Apple Account is signed in, but Xcode shows only a **Personal Team**. Manage Certificates has no certificate entries; its creation menu offers only a disabled Apple Development option and no Developer ID Application option. `security find-identity -v -p codesigning` reports zero valid identities, and `xcrun notarytool history --keychain-profile morph-notary` reports that the profile is missing. Apple lists the Account Holder role as required to create Developer ID certificates; the current Xcode account has no eligible Developer ID team available ([Apple certificate requirements](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)).

Homebrew 7.0.14 reports that the SDK in `/Library/Developer/CommandLineTools` (14.4) does not support macOS 26. Homebrew prefers that SDK whenever its `clang` is present, even though Xcode 27 is selected. Hosted CI passes the Cask audit and style checks; the local audit still needs Command Line Tools compatible with Xcode 27. Software Update offers no CLT package, and `xcode-select --install` says tools are already installed. Download Command Line Tools for Xcode 27.0 from [Apple Developer Downloads](https://developer.apple.com/download/all/) before retrying the local audit.

Before public distribution:

1. In Xcode, open **Settings → Accounts** and use an Apple Developer Program team for which the account has the Account Holder role. A Personal Team alone does not expose the required Developer ID certificate option. Apple requires the Account Holder role to create Developer ID certificates.
2. In the account's certificate manager, create a **Developer ID Application** certificate and install it in the login Keychain. Keep the private key local; do not put it in the repository.
3. Create a notarytool Keychain profile. For Apple Account authentication, run the command below with your account and team values; because `--password` is omitted, notarytool prompts securely for the app-specific password. Do not put that password on the command line. An App Store Connect API key is another supported option.

   ```sh
   xcrun notarytool store-credentials morph-notary --apple-id '<Apple Account>' --team-id '<Team ID>'
   ```

4. Verify the identity with `security find-identity -v -p codesigning`, and verify the profile with `xcrun notarytool history --keychain-profile morph-notary`.
5. Build and sign by supplying the identity selector and keychain profile:

   ```sh
   MORPH_CODESIGN_IDENTITY="Developer ID Application: ..." \
   MORPH_NOTARY_PROFILE="morph-notary" \
   MORPH_VERSION=0.1.0 \
   MORPH_DIST_DIR="$PWD/release-output" \
   Scripts/package-release.sh
   ```

6. Confirm notarization status, staple the ticket, verify the signature and Gatekeeper assessment, and test the archive on clean arm64 and Intel Macs.
7. Install Command Line Tools for Xcode 27.0, then run the Homebrew Cask audit, install, launch and uninstall checks using the final signed archive and checksum.

With a Developer ID identity and stored notary profile, the script submits the archive using `notarytool`, staples and validates the ticket, verifies the code signature, and runs `spctl` Gatekeeper assessment before rebuilding the final archive and checksum. Without both values, it intentionally produces a local ad-hoc package and prints that the artifact is not eligible for public distribution. Do not disable Gatekeeper or advise users to bypass it.

## Homebrew path

Morph is a GUI app, so it belongs in a cask rather than `homebrew/core`. The draft is `distribution/homebrew/morph.rb`; it installs the app and Finder workflow. As of 2026-11-18, GitHub reports the upstream repository was created on 2026-11-17 and has 0 stars. Homebrew's [shared acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy) normally excludes repositories less than 30 days old. Its public-interest threshold is 30 forks, 30 watchers or 75 stars for a typical submission, and 90 forks, 90 watchers or 225 stars for an owner self-submission. An official `homebrew/cask` PR is therefore premature. Use a project-maintained tap for the initial release; Homebrew states that third-party taps are not endorsed or supported by Homebrew.

The current draft points at the future GitHub `v0.1.0` release URL and carries the checksum of the local ad-hoc archive as a placeholder. Replace it with the final signed/notarized archive's checksum and copy the reviewed Cask into a `Casks/morph.rb` file in the new `Lakshay-13/homebrew-tap` repository. No release or tap exists yet, and the local artifact cannot be installed through Homebrew because it is ad-hoc signed. After the release and tap are published, validate `brew tap Lakshay-13/tap`, `brew install --cask morph`, and `brew uninstall --cask morph`. Revisit the official route if the repository meets Homebrew's notability and age requirements. Official PR submissions also require current `brew lgtm --online` validation and human review. Homebrew's [AI usage policy](https://docs.brew.sh/Responsible-AI-Usage) requires disclosing AI assistance and requires the human contributor to answer maintainer comments without AI. See [Homebrew's PR instructions](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request) and [Cask acceptance requirements](https://docs.brew.sh/Acceptable-Casks).

Do not open a Homebrew PR until the archive is available at the URL in the Cask, its checksum is updated, Gatekeeper passes, supported architectures have been tested, and local install/uninstall/audit checks pass.

## Versioning

Update `CFBundleShortVersionString`, `CFBundleVersion`, release notes, the Cask's `version` and `sha256`, and the release archive name together. Keep one versioned release commit per public release. Tag the commit only after the final signed artifact and checksum have been verified.
