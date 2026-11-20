import AppKit
import Darwin
import MorphCore
import os
import SwiftUI

@main
private enum MorphAppMain {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--morph-keychain-self-test") {
            Darwin.exit(EngineExecutableTrust.verifyPersistentKeychainAccess() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        MorphSwiftUIApplication.main()
    }
}

private struct MorphSwiftUIApplication: App {
    @NSApplicationDelegateAdaptor(MorphAppDelegate.self) private var appDelegate
    @StateObject private var model = MorphModel.shared

    var body: some Scene {
        Window("Morph", id: "main") {
            AppRootView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1020, height: 700)
        .windowToolbarStyle(.unified)
    }
}

final class MorphAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.lakshaychawla.Morph", category: "AppDelegate")
    private let menuBarHelperBundleIdentifier = "com.lakshaychawla.Morph.QuickConvert"
    private var terminationRequestPending = false
    private var terminationRequestStartedAt: Date?

    private var launchedInBackgroundMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--morph-background")
    }

    private var menuBarHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MorphQuickConvert.app", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUpdateDynamicServices()
        startMenuBarHelperIfNeeded()
        guard launchedInBackgroundMode else { return }
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            NSApp.hide(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        sender.setActivationPolicy(.accessory)
        return false
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
        for url in urls where url.scheme == "morph" && url.host == "show" {
            showMainWindow()
        }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        MorphModel.shared.importFiles(files)
        showMainWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = MorphModel.shared
        guard model.hasActiveWork else { return .terminateNow }
        guard !terminationRequestPending else { return .terminateCancel }
        terminationRequestPending = true
        terminationRequestStartedAt = Date()
        model.cancelCancellableWorkForTermination()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForSafeTermination(sender)
        }
        return .terminateLater
    }

    @MainActor
    private func waitForSafeTermination(_ application: NSApplication) {
        guard terminationRequestPending else { return }
        if !MorphModel.shared.hasActiveWork {
            terminationRequestPending = false
            terminationRequestStartedAt = nil
            application.reply(toApplicationShouldTerminate: true)
            return
        }
        if let startedAt = terminationRequestStartedAt, Date().timeIntervalSince(startedAt) >= 60 {
            logger.error("An operation did not stop within the quit grace period; Morph is exiting after cancellation was requested.")
            terminationRequestPending = false
            terminationRequestStartedAt = nil
            application.reply(toApplicationShouldTerminate: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForSafeTermination(application)
        }
    }

    private func startMenuBarHelperIfNeeded() {
        guard FileManager.default.fileExists(atPath: menuBarHelperURL.path),
              !NSWorkspace.shared.runningApplications.contains(where: {
                  $0.bundleIdentifier == menuBarHelperBundleIdentifier && !$0.isTerminated
              }) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: menuBarHelperURL, configuration: configuration) { _, error in
            if let error {
                self.logger.error("Couldn't start Morph's menu-bar helper (\(error.localizedDescription, privacy: .private)).")
            }
        }
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
