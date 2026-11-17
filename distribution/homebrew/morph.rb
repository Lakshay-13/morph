# Draft only. This is the local ad-hoc v0.1.0 archive hash, not a public release.
# Do not submit until the URL exists and the signed, notarized release passes
# Gatekeeper, Homebrew audit, install and uninstall checks.
cask "morph" do
  version "0.1.0"
  sha256 "89a4a11000984072aeb74ed92f573fd7668087cf71e93392a8e6c766021ee83d"

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
