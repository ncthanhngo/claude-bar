import AppKit

@main
enum ClaudeWidgetApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // No Dock icon; menu bar only.
        app.run()
    }
}
