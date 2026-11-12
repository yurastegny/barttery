cask "barttery" do
  version "1.2.3"
  sha256 "e11afa2017d925048d6024751b44b01e92c7c223e374b54ff6cc7f2a442064a0"

  url "https://github.com/yurastegny/barttery/releases/download/v#{version}/Barttery-#{version}.dmg"
  name "Barttery"
  desc "Battery levels for your devices in the menu bar"
  homepage "https://github.com/yurastegny/barttery"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Barttery.app"
end
