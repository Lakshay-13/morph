# frozen_string_literal: true

# This CI-only cask keeps the LibreOffice security-resolver fixture fixed.
cask "libreoffice" do
  version "26.8.3"
  sha256 "de943203795e5057785f65515063e2db5eb60b0bb6d8e2534fec59e5cc5fb988"

  url "https://download.documentfoundation.org/libreoffice/stable/#{version}/mac/aarch64/LibreOffice_#{version}_MacOS_aarch64.dmg"
  name "LibreOffice"
  desc "Office productivity suite"
  homepage "https://www.libreoffice.org/"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "LibreOffice.app"
end
