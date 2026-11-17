# Draft only. The hash below is for a local ad-hoc archive, not a public release.
# Do not submit until the URL exists and the signed, notarized release passes
# Gatekeeper, Homebrew audit, install and uninstall checks.
cask "morph" do
  version "0.1.0"
  sha256 "4dfeecef90548c76f0829287c071ca5655cfddf3b301e7c2ac5545b1b29a9b40"

  url "https://github.com/Lakshay-13/morph/releases/download/v#{version}/Morph-#{version}-macOS-universal.zip"
  name "Morph"
  desc "Native macOS file conversion and transformation utility"
  homepage "https://github.com/Lakshay-13/morph"

  depends_on macos: ">= :sonoma"

  # Install the Finder Quick Action alongside the application.
  app "Morph-#{version}/Morph.app"
  service "Morph-#{version}/Convert with Morph.workflow"

  uninstall quit: "com.lakshaychawla.Morph"

  zap trash: [
    "~/Library/Application Support/Morph",
    "~/Library/Preferences/com.lakshaychawla.Morph.plist",
  ]
end
