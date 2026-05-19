cask "claude-bar" do
  version "0.8.2"
  sha256 "fb109ba24816fc2330ca14280be40dfef055831752081a16754e2be04d8df7ea"

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
