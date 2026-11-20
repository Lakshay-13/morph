# typed: strict
# frozen_string_literal: true

# Draft only. This hash matches the local ad-hoc v0.1.2 (build 9) validation archive, not a public release.
# Do not submit until the URL exists and a Developer ID signed, notarized release passes
# Gatekeeper, Homebrew audit, install and uninstall checks.
cask "morph" do
  version "0.1.2"
  sha256 "285bb29883325ec83ae308038efc569c9820d1150ee005b6c17d80072134885b"

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

  uninstall quit: [
    "com.lakshaychawla.Morph",
    "com.lakshaychawla.Morph.QuickConvert",
  ]

  zap trash: [
    "~/Library/Application Support/Morph",
    "~/Library/Caches/com.lakshaychawla.Morph",
    "~/Library/Containers/com.lakshaychawla.Morph.FinderSync",
    "~/Library/Preferences/com.lakshaychawla.Morph.plist",
    "~/Library/Saved Application State/com.lakshaychawla.Morph.QuickConvert.savedState",
    "~/Library/Saved Application State/com.lakshaychawla.Morph.savedState",
  ]

  caveats <<~EOS
    To enable the Finder conversion submenu, open System Settings → General → Login Items & Extensions → Finder Extensions and enable Morph.
    The submenu appears in Finder's contextual menu for files in your home folder and mounted volumes.
  EOS
end
