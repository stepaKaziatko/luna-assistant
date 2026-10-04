import AppKit

@main
enum LunaApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Агент: без иконки в Dock и без главного меню.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
