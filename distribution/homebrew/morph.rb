# Draft only. This is the latest local ad-hoc v0.1.0 archive hash, not a public release.
# Do not submit until the URL exists and the signed, notarized release passes
# Gatekeeper, Homebrew audit, install and uninstall checks.
cask "morph" do
  version "0.1.0"
  sha256 "b3fe4dcf51cccfec0315bb120ff421b3b08b286ce11a2e582c1e07f8ba3d4d30"

  url "https://github.com/Lakshay-13/morph/releases/download/v#{version}/Morph-#{version}-macOS-universal.zip"
  name "Morph"
  desc "Native file conversion and transformation utility"
  homepage "https://github.com/Lakshay-13/morph"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Morph-#{version}/Morph.app"

  uninstall quit: "com.lakshaychawla.Morph"

  zap trash: [
    "~/Library/Application Support/Morph",
    "~/Library/Preferences/com.lakshaychawla.Morph.plist",
  ]

  caveats <<~EOS
    To enable the Finder conversion submenu, open System Settings → General → Login Items & Extensions → Finder Extensions and enable Morph.
    The submenu appears in Finder's contextual menu for files in your home folder and mounted volumes.
  EOS
end
