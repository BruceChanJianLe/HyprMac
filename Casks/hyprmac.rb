cask "hyprmac" do
  version "0.14.0"
  sha256 "85b427d14f1bfdb105d062f09b793716d61cc34b0ec5948cc14d50030ecd701b"

  url "https://github.com/zacharytgray/HyprMac/releases/download/v#{version}/HyprMac-#{version}.dmg"
  name "HyprMac"
  desc "Tiling window manager for macOS inspired by Hyprland"
  homepage "https://github.com/zacharytgray/HyprMac"

  depends_on macos: ">= :ventura"

  app "HyprMac.app"

  postflight do
    # remind user about accessibility permission
    ohai "HyprMac requires Accessibility permission."
    ohai "Grant it in System Settings → Privacy & Security → Accessibility"
  end

  zap trash: [
    "~/Library/Application Support/HyprMac",
  ]
end
