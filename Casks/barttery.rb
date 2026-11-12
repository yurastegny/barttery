cask "barttery" do
  version "1.2.2"
  sha256 "b10c4b99c9647e582720c46882cce8da7aa4a0b5074c1c8d0806b7621711f125"

  url "https://github.com/yurastegny/barttery/releases/download/v#{version}/Barttery-#{version}.dmg"
  name "Barttery"
  desc "Battery levels for your devices in the menu bar"
  homepage "https://github.com/yurastegny/barttery"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Barttery.app"
end
