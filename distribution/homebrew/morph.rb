# Draft only. This is the latest local ad-hoc v0.1.0 archive hash, not a public release.
# Do not submit until the URL exists and the signed, notarized release passes
# Gatekeeper, Homebrew audit, install and uninstall checks.
cask "morph" do
  version "0.1.0"
  sha256 "eebbb45c3b4ce32198ef857a100adcf698041628cfd276ac988f5fb38412b5c1"

  url "https://github.com/Lakshay-13/morph/releases/download/v#{version}/Morph-#{version}-macOS-universal.zip"
  name "Morph"
  desc "Native file conversion and transformation utility"
  homepage "https://github.com/Lakshay-13/morph"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  # Install the Finder Quick Action alongside the application.
  app "Morph-#{version}/Morph.app"
  service "Morph-#{version}/Convert with Morph.workflow"

  uninstall quit: "com.lakshaychawla.Morph"

  zap trash: [
    "~/Library/Application Support/Morph",
    "~/Library/Preferences/com.lakshaychawla.Morph.plist",
  ]
end
