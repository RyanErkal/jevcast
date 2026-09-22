# Homebrew cask for the ryanerkal/homebrew-tap repository.
# scripts/release.sh writes the version and checksum below.
cask "jev-launcher" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/RyanErkal/jev-launcher/releases/download/v#{version}/Jev-Launcher.dmg"
  name "Jev Launcher"
  desc "Keyboard launcher and window manager"
  homepage "https://jev-launcher.vercel.app"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Jev Launcher.app"

  zap trash: [
    "~/Library/Caches/JevLauncher",
    "~/Library/Preferences/com.ryanerkal.jevlauncher.plist",
  ]
end
