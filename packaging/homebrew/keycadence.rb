cask "keycadence" do
  version "1.0.0"
  sha256 "1900df4a6e8c766c5a43a453333c5580b840e59b3757ba9255f08953e670d7b5"

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
