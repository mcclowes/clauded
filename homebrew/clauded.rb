cask "clauded" do
  version :latest
  sha256 :no_check
  url "https://github.com/mcclowes/clauded/releases/latest/download/Clauded.zip"
  name "Clauded"
  desc "Native macOS menu bar app for managing Claude Code instances"
  homepage "https://github.com/mcclowes/clauded"

  depends_on macos: ">= :sequoia"

  app "Clauded.app"

  zap trash: [
    "~/Library/Application Support/Clauded",
    "~/Library/Preferences/com.mcclowes.clauded.plist",
  ]
end
