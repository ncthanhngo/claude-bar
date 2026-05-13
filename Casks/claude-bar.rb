cask "claude-bar" do
  version "0.7.3"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/ncthanhngo/claude-bar/releases/download/v#{version}/ClaudeWidget-#{version}.dmg"
  name "claude-bar"
  desc "Menu bar widget for Claude usage tracking and multi-account switching"
  homepage "https://github.com/ncthanhngo/claude-bar"

  app "Claude Widget.app"

  zap trash: [
    "~/Library/Application Support/ClaudeWidget",
    "~/Library/Preferences/dev.soi.claudewidget.plist",
    "~/Library/Caches/dev.soi.claudewidget",
  ]
end
