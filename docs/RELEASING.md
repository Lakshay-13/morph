# Release, signing and Homebrew

## Local release package

The packaging script attempts an arm64 + x86_64 universal app, a versioned ZIP archive and a SHA-256 checksum:

```sh
MORPH_DIST_DIR="$PWD/release-output" Scripts/package-release.sh
```

The ZIP contains `Morph.app`, its windowless Finder conversion helper, the universal Finder Sync extension, Morph's Apache license and third-party license notices. The app bundle also carries those notices in `Contents/Resources/Legal`. The ZIP is ignored by Git. Keep the exact tested archive and its checksum together. Do not publish the current ad-hoc build.

An earlier working tree was packaged on 2026-11-18 as `dist/release-0.1.0-current/Morph-0.1.0-macOS-universal.zip`. `Morph`, `MorphQuickConvert` and `MorphFinderSync` each contained `arm64` and `x86_64` slices. Strict signature verification, ZIP integrity and SHA-256 verification passed. That artifact is ad-hoc signed and is only a local validation package; it is not notarized, Gatekeeper-ready or suitable for public distribution. Its SHA-256 was `a6f44465c95fc7ec7e492d57f6678f57be5572432dfddd629d8a6ac0493449b`.

The 2026-11-19 security-review candidate is `dist/security-review-0.1.2/Morph-0.1.2-macOS-universal.zip` (version 0.1.2, build 6). All three executable bundles contain `arm64` and `x86_64` slices, use hardened-runtime signatures without `get-task-allow`, and pass strict signature verification. The archive passes ZIP integrity and its SHA-256 is `12b10f5032c9c69721fb67ce59417e966bf9d8d019bc572a598bf3bd43401f84`; `distribution/homebrew/morph.rb` tracks this local candidate. The bundle remains ad-hoc signed: `spctl --assess` rejects it, there is no notarization ticket, and it must not be published. The Cask URL is not live until a public release is created; no release or tap is being submitted as part of this review.

## Developer ID signing and notarization

Signed builds that persist executable approvals and custom output-directory identities also require a shared Data Protection Keychain group. `Scripts/build-app.sh` requires `MORPH_KEYCHAIN_ACCESS_GROUP` plus separate `MORPH_APP_PROVISIONING_PROFILE` and `MORPH_HELPER_PROVISIONING_PROFILE` paths. It checks each profile's team, exact bundle application identifier, expiry, `get-task-allow`, device scope and Keychain group, then embeds it in the matching bundle. The app and Finder helper receive distinct application/team identifier entitlements with the same exact shared Keychain group. The build runs disposable Keychain read/write/delete checks from both signed executables. A profile is not a signing identity; Developer ID signing and notarization are separate requirements. Wildcard application identifiers are rejected, and the signed Keychain access group is exact even when a profile authorizes a team wildcard.

Current machine status (rechecked 2026-11-19): Xcode 27.0 is selected and its license is accepted. The Apple Account is signed in, but Xcode shows only a **Personal Team**. Manage Certificates lists one Apple Development certificate dated 2026-11-18, but the login keychain has no matching private key: `security find-identity -v -p codesigning` reports zero valid identities. Xcode disables both **Create Apple Development** and **Delete Certificate** while that certificate remains active. After browser sign-in, the Apple Developer Certificates, Identifiers & Profiles link redirects to “Need assistance with accessing your developer account?” instead of the certificate list, so the approved revoke-and-recreate action cannot be completed from the current account access. `xcrun notarytool history --keychain-profile morph-notary` reports that the profile is missing. Xcode exposes no paid Developer Program team, so a Developer ID certificate and notarization profile are unavailable ([Apple certificate requirements](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)). Next steps are to obtain certificate-portal access through an eligible team or recover the matching `.p12` from a backup/original keychain. Do not revoke or create certificates until one of those paths is available.

Homebrew 7.0.14 reports that the installed Command Line Tools SDK (14.4) does not support macOS 26. Homebrew prefers that SDK whenever its `clang` is present, even though Xcode 27 is selected. An earlier hosted run passed the Cask audit and style checks; these current local workflow changes have not run on GitHub Actions. The local audit still needs Command Line Tools compatible with Xcode 27. Software Update offers no CLT package, and `xcode-select --install` says tools are already installed. Download Command Line Tools for Xcode 27.0 from [Apple Developer Downloads](https://developer.apple.com/download/all/) before retrying the local audit.

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
   MORPH_KEYCHAIN_ACCESS_GROUP="YOURTEAMID.com.lakshaychawla.Morph" \
   MORPH_APP_PROVISIONING_PROFILE="/secure/path/Morph.provisionprofile" \
   MORPH_HELPER_PROVISIONING_PROFILE="/secure/path/MorphQuickConvert.provisionprofile" \
   MORPH_CODESIGN_IDENTITY="Developer ID Application: ..." \
   MORPH_NOTARY_PROFILE="morph-notary" \
   MORPH_DIST_DIR="$PWD/release-output" \
   Scripts/package-release.sh
   ```

6. Confirm notarization status, staple the ticket, verify the signature and Gatekeeper assessment, and test the archive on clean arm64 and Intel Macs.
7. Install Command Line Tools for Xcode 27.0, then run the Homebrew Cask audit, install, launch and uninstall checks using the final signed archive and checksum.

With a Developer ID identity and stored notary profile, the script submits the archive using `notarytool`, staples and validates the ticket, verifies the code signature, and runs `spctl` Gatekeeper assessment before rebuilding the final archive and checksum. Without both values, it intentionally produces a local ad-hoc package and prints that the artifact is not eligible for public distribution. Do not disable Gatekeeper or advise users to bypass it.

## Homebrew path

Morph is a GUI app, so it belongs in a cask rather than `homebrew/core`. The draft is `distribution/homebrew/morph.rb`; it installs the app bundle with Finder Sync extension. Users may need to enable the extension in System Settings. Homebrew's [shared acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy) requires public interest beyond the author. An owner self-submission normally needs at least 90 forks, 90 watchers or 225 stars. As of 2026-11-18, this repository has 0 stars and no independent-interest evidence; the policy says a recently released app may receive further consideration only with substantial, independently verifiable interest and multiple requests. An official `homebrew/cask` PR is not supportable yet. Use a project-maintained tap for an initial signed release; Homebrew states that third-party taps are not endorsed or supported by Homebrew.

The current draft points at the future GitHub `v0.1.2` release URL and carries the checksum of the latest local ad-hoc archive as a placeholder. Replace it with the final signed/notarized archive's checksum and copy the reviewed Cask into a `Casks/morph.rb` file in the new `Lakshay-13/homebrew-tap` repository. No release or tap exists yet, and the local artifact cannot be installed through Homebrew because it is ad-hoc signed. After the release and tap are published, validate `brew tap Lakshay-13/tap`, `brew install --cask morph`, Finder extension enablement, and `brew uninstall --cask morph`. Revisit the official route if the repository meets Homebrew's notability requirements. Official PR submissions also require current `brew lgtm --online` validation and human review. Homebrew's [AI usage policy](https://docs.brew.sh/Responsible-AI-Usage) requires disclosing AI assistance and requires the human contributor to answer maintainer comments without AI. See [Homebrew's PR instructions](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request) and [Cask acceptance requirements](https://docs.brew.sh/Acceptable-Casks).

Do not open a Homebrew PR until the archive is available at the URL in the Cask, its checksum is updated, Gatekeeper passes, supported architectures have been tested, and local install/uninstall/audit checks pass.

## Versioning

Update `CFBundleShortVersionString`, `CFBundleVersion`, release notes, the Cask's `version` and `sha256`, and the release archive name together. Keep one versioned release commit per public release. Tag the commit only after the final signed artifact and checksum have been verified.
