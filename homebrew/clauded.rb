cask "clauded" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/mcclowes/clauded/releases/download/v#{version}/Clauded.zip",
      verified: "github.com/mcclowes/clauded/"
  name "Clauded"
  desc "Menu bar app for managing Claude Code instances"
  homepage "https://github.com/mcclowes/clauded"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "Clauded.app"

  zap trash: [
    "~/Library/Application Support/Clauded",
    "~/Library/Preferences/com.mcclowes.clauded.plist",
  ]
end
