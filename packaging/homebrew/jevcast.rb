# Homebrew cask for the ryanerkal/homebrew-tap repository.
# scripts/release.sh writes the version and checksum below.
cask "jevcast" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/RyanErkal/jevcast/releases/download/v#{version}/Jevcast.dmg"
  name "Jevcast"
  desc "Keyboard launcher and window manager"
  homepage "https://github.com/RyanErkal/jevcast"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Jevcast.app"

  zap trash: [
    "~/Library/Caches/JevLauncher",
    "~/Library/Preferences/com.ryanerkal.jevlauncher.plist",
  ]
end
