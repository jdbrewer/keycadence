cask "keycadence" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/jdbrewer/keycadence/releases/download/v#{version}/Keycadence-#{version}.zip"
  name "Keycadence"
  desc "Low-latency mechanical keyboard sounds"
  homepage "https://github.com/jdbrewer/keycadence"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Keycadence.app"

  uninstall quit: "com.notebrewer.keycadence"

  zap trash: "~/Library/Containers/com.notebrewer.keycadence"
end
