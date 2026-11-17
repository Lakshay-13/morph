# Release, signing and Homebrew

## Local release package

The packaging script attempts an arm64 + x86_64 universal app, a versioned ZIP archive and a SHA-256 checksum:

```sh
MORPH_VERSION=0.1.0 MORPH_DIST_DIR="$PWD/release-output" Scripts/package-release.sh
```

The ZIP contains `Morph.app` and the Finder Quick Action workflow at its root. The ZIP is ignored by Git. Keep the exact tested archive and its checksum together. Do not publish the current ad-hoc build.

The latest local package is `.build/release-artifacts-v8/Morph-0.1.0-macOS-universal.zip` (arm64 + x86_64), SHA-256 `4dfeecef90548c76f0829287c071ca5655cfddf3b301e7c2ac5545b1b29a9b40`. It is a local validation artifact, not a GitHub release; it is ad-hoc signed and must not be used for the public Cask.

## Developer ID signing and notarization

The current machine has no valid code-signing identity. Before public distribution:

1. Enroll the publisher in the Apple Developer Program and create a **Developer ID Application** certificate.
2. Install the certificate in Keychain. Do not put its private key or credentials in the repository.
3. Store an App Store Connect API key or Apple ID credentials with `xcrun notarytool store-credentials` under a local keychain profile.
4. Verify the identity with `security find-identity -v -p codesigning`.
5. Build and sign by supplying the identity selector and keychain profile:

   ```sh
   MORPH_CODESIGN_IDENTITY="Developer ID Application: ..." \
   MORPH_NOTARY_PROFILE="morph-notary" \
   MORPH_VERSION=0.1.0 \
   MORPH_DIST_DIR="$PWD/release-output" \
   Scripts/package-release.sh
   ```

6. Confirm notarization status, staple the ticket, verify the signature and Gatekeeper assessment, and test the archive on clean arm64 and Intel Macs.
7. Run the Homebrew Cask audit, install, launch and uninstall checks using the final signed archive and checksum.

The script uses `notarytool submit --wait` and staples the application when a Developer ID identity and stored notary profile are provided. Without them, it intentionally produces a local ad-hoc package and prints that the artifact is not eligible for public distribution. Do not disable Gatekeeper or advise users to bypass it.

## Homebrew path

Morph is a GUI app, so the planned upstream destination is `homebrew/cask`, not `homebrew/core`. The Cask draft is `distribution/homebrew/morph.rb`; it installs the app and its Finder workflow using Homebrew's app and service artifacts. A custom tap would also require a separate maintained tap repository; this project has not created one.

The current draft points at the future GitHub `v0.1.0` release URL and carries the checksum of the locally built ad-hoc archive as a placeholder reference. Replace it with the checksum of the final signed/notarized public archive. It cannot be installed or audited yet because no signed, notarized public release exists. The official process requires a fork and PR to the Homebrew Cask repository, plus `brew install --cask`, `brew uninstall --cask` and `brew lgtm --online` validation. See [Homebrew's PR instructions](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request) and [Cask acceptance requirements](https://docs.brew.sh/Acceptable-Casks).

Do not open a Homebrew PR until the archive is available at the URL in the Cask, its checksum is updated, Gatekeeper passes, supported architectures have been tested, and local install/uninstall/audit checks pass.

## Versioning

Update `CFBundleShortVersionString`, `CFBundleVersion`, release notes, the Cask's `version` and `sha256`, and the release archive name together. Keep one versioned release commit per public release. Tag the commit only after the final signed artifact and checksum have been verified.
