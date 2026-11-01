cask "barttery" do
  version "1.2.0"
  sha256 "a77bd455ad09ddb952221a45d0bbf31b3124e478de21cc2e24cc8ca0495f0e4b"

  url "https://github.com/yurastegny/barttery/releases/download/v#{version}/Barttery-#{version}.dmg"
  name "Barttery"
  desc "Battery levels for your devices in the menu bar"
  homepage "https://github.com/yurastegny/barttery"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Barttery.app"
end
