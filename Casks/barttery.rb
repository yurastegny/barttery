cask "barttery" do
  version "1.2.1"
  sha256 "1af9e06382caa11a79dd888899f95ffd5c6a30e06da7159373587db8ead5ab77"

  url "https://github.com/yurastegny/barttery/releases/download/v#{version}/Barttery-#{version}.dmg"
  name "Barttery"
  desc "Battery levels for your devices in the menu bar"
  homepage "https://github.com/yurastegny/barttery"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Barttery.app"
end
