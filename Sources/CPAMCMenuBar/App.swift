import AppKit
import SwiftUI
import Combine
import ServiceManagement

@main
@MainActor
struct CPAMCMenuBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuBarDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class MenuBarDelegate: NSObject, NSApplicationDelegate {
    private var store: QuotaStore!
    private var updater: Updater!
    private var statusItem: NSStatusItem!
    private var menu: StatusMenu!
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = QuotaStore(demo: CommandLine.arguments.contains("--demo"))
        updater = Updater(demo: store.demo)
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.imageHugsTitle = true
            button.setAccessibilityLabel("Juice Bar")
        }
        menu = StatusMenu(rootView: SubscriptionPanel(store: store, updater: updater),
                          button: statusItem.button!,
                          staysOpen: CommandLine.arguments.contains("--show-menu"))
        // An update restarts the app only while its menu is closed.
        updater.canRestart = { [weak self] in self?.menu.isVisible == false }
        menu.onClose = { [weak self] in self?.updater.restartIfReady() }
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
        updateIcon()
        store.start()
        if CommandLine.arguments.contains("--enable-login") {
            do { try SMAppService.mainApp.register() }
            catch { fputs("Could not enable launch at login. Use the app Settings.\n", stderr) }
        }
        if CommandLine.arguments.contains("--disable-login") {
            Task { try? await SMAppService.mainApp.unregister(); NSApp.terminate(nil) }
        } else {
            updater.start()
        }
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        updater?.stop()
    }
    private func updateIcon() {
        statusItem.button?.image = MenuIcon.image(store.iconMetrics, preferences: store.iconPreferences)
        statusItem.button?.toolTip = store.iconDescription
        statusItem.button?.setAccessibilityLabel("Juice Bar · " + store.iconAccessibilityDescription)
    }
    @objc private func togglePopover() {
        menu.toggle()
    }
    private func showPopover() {
        menu.show()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "cpamc-menubar" && $0.host == "subscriptions" }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
    }
}
