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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        MorphModel.shared.importFiles(urls)
        application.activate(ignoringOtherApps: true)
        application.windows.first?.makeKeyAndOrderFront(nil)
        application.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        MorphModel.shared.importFiles(files)
        application.activate(ignoringOtherApps: true)
        application.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc func convertFiles(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let filePaths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]
        let urls = fileURLs ?? filePaths?.map { URL(fileURLWithPath: $0) } ?? []
        guard !urls.isEmpty else {
            error.pointee = "Morph did not receive a file from Finder." as NSString
            return
        }
        DispatchQueue.main.async {
            MorphModel.shared.importFiles(urls)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
