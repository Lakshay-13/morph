# Release, signing and Homebrew

## Local release package

The packaging script attempts an arm64 + x86_64 universal app, a versioned ZIP archive and a SHA-256 checksum:

```sh
MORPH_VERSION=0.1.0 MORPH_DIST_DIR="$PWD/release-output" Scripts/package-release.sh
```

The ZIP contains `Morph.app` and the Finder Quick Action workflow at its root. The ZIP is ignored by Git. Keep the exact tested archive and its checksum together. Do not publish the current ad-hoc build.

The latest local package is `.build/release-artifacts-v11/Morph-0.1.0-macOS-universal.zip` (arm64 + x86_64), SHA-256 `ad86ae0abb71e2b5c25a5ca4a9179ec7daf066fb730fac69ebf070e16826cc33`. Its ZIP integrity and checksum were verified. It is a local validation artifact, not a GitHub release; it is ad-hoc signed and must not be used for the public Cask. The draft Cask's SHA is only a local placeholder and must be replaced with the final signed/notarized archive's checksum.

## Developer ID signing and notarization

Current machine status (2026-11-18): Xcode 27.0 is selected and its license is accepted, but Xcode has no developer account signed in. There are zero valid code-signing identities and no `morph-notary` Keychain profile. Homebrew's audit also reports the standalone Command Line Tools package as 15.4 and requires 26.3 or newer. Software Update did not offer a Command Line Tools update; install a current package from Apple Developer Downloads to unblock the audit.

Before public distribution:

1. In Xcode, open **Settings → Accounts** and add the publisher's Apple Account. The team must be enrolled in the Apple Developer Program, and the account must have permission to create Developer ID certificates (Apple requires the Account Holder role).
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
7. Update the standalone Command Line Tools package to version 26.3 or newer, then run the Homebrew Cask audit, install, launch and uninstall checks using the final signed archive and checksum.

With a Developer ID identity and stored notary profile, the script submits the archive using `notarytool`, staples and validates the ticket, verifies the code signature, and runs `spctl` Gatekeeper assessment before rebuilding the final archive and checksum. Without both values, it intentionally produces a local ad-hoc package and prints that the artifact is not eligible for public distribution. Do not disable Gatekeeper or advise users to bypass it.

## Homebrew path

Morph is a GUI app, so the planned upstream destination is `homebrew/cask`, not `homebrew/core`. The Cask draft is `distribution/homebrew/morph.rb`; it installs the app and its Finder workflow using Homebrew's app and service artifacts. A custom tap would also require a separate maintained tap repository; this project has not created one.

The current draft points at the future GitHub `v0.1.0` release URL and carries the checksum of the locally built ad-hoc archive as a placeholder reference. Replace it with the checksum of the final signed/notarized public archive. It cannot be installed or audited yet because no signed, notarized public release exists. The official process requires a fork and PR to the Homebrew Cask repository, plus `brew install --cask`, `brew uninstall --cask` and `brew lgtm --online` validation. See [Homebrew's PR instructions](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request) and [Cask acceptance requirements](https://docs.brew.sh/Acceptable-Casks).

Do not open a Homebrew PR until the archive is available at the URL in the Cask, its checksum is updated, Gatekeeper passes, supported architectures have been tested, and local install/uninstall/audit checks pass.

## Versioning

Update `CFBundleShortVersionString`, `CFBundleVersion`, release notes, the Cask's `version` and `sha256`, and the release archive name together. Keep one versioned release commit per public release. Tag the commit only after the final signed artifact and checksum have been verified.
