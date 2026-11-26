cask "barttery" do
  version "1.2.5"
  sha256 "6dc6abd6334f458e051ef1e8f7df63752a72ea827342c464ac543665383041e4"

  url "https://github.com/yurastegny/barttery/releases/download/v#{version}/Barttery-#{version}.dmg"
  name "Barttery"
  desc "Battery levels for your devices in the menu bar"
  homepage "https://github.com/yurastegny/barttery"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Barttery.app"
end
