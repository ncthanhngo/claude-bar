cask "claude-bar" do
  version "0.8.0"
  sha256 "0ca68d00c95496f91e65de29b8c291dff981c994960db02963d78991777b78e2"

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
