import AppKit
import SwiftUI

@main
struct MorphApp: App {
    @NSApplicationDelegateAdaptor(MorphAppDelegate.self) private var appDelegate
    @StateObject private var model = MorphModel.shared

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1020, height: 700)
        .windowToolbarStyle(.unified)
    }
}

final class MorphAppDelegate: NSObject, NSApplicationDelegate {
    private var launchedInBackgroundMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--morph-background")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUpdateDynamicServices()
        guard launchedInBackgroundMode else { return }
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            NSApp.hide(nil)
        }
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if launchedInBackgroundMode {
            application.reply(toOpenOrPrint: .success)
            return
        }
        MorphModel.shared.importFiles(urls)
        showMainWindow()
        application.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "morph" {
            switch url.host {
            case "show":
                showMainWindow()
            case "quit":
                application.terminate(nil)
            default:
                break
            }
        }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        MorphModel.shared.importFiles(files)
        showMainWindow()
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
