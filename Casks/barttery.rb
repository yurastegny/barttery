cask "barttery" do
  version "1.2.4"
  sha256 "0a3d0d47d5189138dd3f0215dbd0d086bbc641cb22b3471a3929719c82187e77"

  url "https://github.com/yurastegny/barttery/releases/download/v#{version}/Barttery-#{version}.dmg"
  name "Barttery"
  desc "Battery levels for your devices in the menu bar"
  homepage "https://github.com/yurastegny/barttery"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Barttery.app"
end
