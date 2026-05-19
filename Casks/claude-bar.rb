cask "claude-bar" do
  version "0.8.1"
  sha256 "f18c3bd78a40209e1e403feac2158bd0d42f6db2d56935a472d7ff6d95e0d45d"

  url "https://github.com/ncthanhngo/claude-bar/releases/download/v#{version}/ClaudeWidget-#{version}.dmg"
  name "claude-bar"
  desc "Menu bar widget for Claude usage tracking and multi-account switching"
  homepage "https://github.com/ncthanhngo/claude-bar"

  depends_on macos: ">= :ventura"

  app "Claude Widget.app"

  zap trash: [
    "~/Library/Application Support/ClaudeWidget",
    "~/Library/Preferences/dev.soi.claudewidget.plist",
    "~/Library/Caches/dev.soi.claudewidget",
  ]
end
