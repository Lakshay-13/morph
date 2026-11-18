import AppKit
import MorphCore
import SwiftUI
import UniformTypeIdentifiers

struct AppRootView: View {
    @EnvironmentObject private var model: MorphModel
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 14) {
                HStack(spacing: 11) {
                    Image(nsImage: NSImage(contentsOfFile: Bundle.main.path(forResource: "morph-logo", ofType: "png") ?? "") ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)!)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Morph").font(.headline)
                        Text("File converter").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(AppSection.allCases) { section in
                            Button {
                                model.selectedSection = section
                            } label: {
                                Label(section.rawValue, systemImage: section.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        model.selectedSection == section ? Color.accentColor.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sidebar.\(section.rawValue.lowercased())")
                            .accessibilityValue(model.selectedSection == section ? "Selected" : "")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Label(model.isDiscovering ? "Checking engines…" : "Local processing", systemImage: "lock.shield")
                        .font(.caption.weight(.medium))
                    Text("Your files stay on this Mac.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            Group {
                switch model.selectedSection {
                case .overview: OverviewView()
                case .convert: ConvertView()
                case .operations: OperationsView()
                case .history: HistoryView()
                case .engines: EnginesView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: acceptDrop)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9]))
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
                        .padding(20)
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: openFiles) {
                        Label("Add Files", systemImage: "plus")
                    }
                    .help("Choose files to convert")
                }
            }
        }
        .onOpenURL(perform: model.handleExternalURL)
    }

    private func openFiles() {
        chooseFiles(for: model)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in matching {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collected.values
            if !urls.isEmpty { model.importFiles(urls) }
        }
        return true
    }
}

@MainActor
private func chooseFiles(for model: MorphModel) {
    let panel = NSOpenPanel()
    panel.title = "Choose files for Morph"
    panel.prompt = "Add Files"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK { model.importFiles(panel.urls) }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var values: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
}

struct OverviewView: View {
    @EnvironmentObject private var model: MorphModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files, transformed.")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Convert and prepare files with tools that run locally on your Mac.")
                        .font(.title3).foregroundStyle(.secondary)
                    Label("Finder: right-click → Convert To → choose a format", systemImage: "cursorarrow.click")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 4)
                }

                HStack(spacing: 14) {
                    MetricCard(title: "Available conversions", value: model.isDiscovering ? "…" : "\(model.availableRouteCount)", symbol: "arrow.triangle.2.circlepath")
                    MetricCard(title: "Active engines", value: "\(model.activeEngineCount)", symbol: "shippingbox")
                    MetricCard(title: "Categories", value: "\(FormatCategory.allCases.count)", symbol: "square.grid.2x2")
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start with a file").font(.title2.weight(.semibold))
                            Text("Choose files or drop them anywhere in this window.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        AdaptiveProminentButton(title: "Choose Files", systemImage: "plus") {
                            chooseFiles(for: model)
                        }
                    }
                    HStack(spacing: 12) {
                        CapabilityPill("Images", symbol: "photo")
                        CapabilityPill("Audio & video", symbol: "waveform")
                        CapabilityPill("Documents", symbol: "doc.text")
                        CapabilityPill("Data & archives", symbol: "archivebox")
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

                if let first = model.history.first {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent conversion").font(.title3.weight(.semibold))
                        HistoryRow(item: first)
                    }
                }

                if let message = model.conversionMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }
}

private struct AdaptiveProminentButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("overview.choose-files")
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("overview.choose-files")
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor)
            Text(value).font(.system(size: 27, weight: .bold, design: .rounded))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct CapabilityPill: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
    }
}

struct ConvertView: View {
    @EnvironmentObject private var model: MorphModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Convert files").font(.largeTitle.bold())
                    Text("Choose an output format supported by the engines currently installed.")
                        .foregroundStyle(.secondary)
                }

                if model.selectedFiles.isEmpty {
                    ContentUnavailableView("No files selected", systemImage: "doc.badge.plus", description: Text("Add files here or choose a format from Finder’s Convert To menu."))
                        .frame(minHeight: 250)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Selected files (\(model.selectedFiles.count))").font(.headline)
                            Spacer()
                            Button("Clear") { model.clearSelection() }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        ForEach(model.selectedFiles, id: \.path) { url in
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: url)).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Text(url.deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button { model.removeFile(url) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove file")
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    if !model.quickActions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Quick actions").font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], alignment: .leading, spacing: 10) {
                                ForEach(model.quickActions) { action in
                                    Button { model.perform(action) } label: {
                                        Label(action.rawValue, systemImage: action.symbol)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("quick-action.\(action.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
                                    .disabled(model.isRunningUtility || model.isConverting || model.activeEngineAction != nil)
                                }
                            }
                            if model.isRunningUtility {
                                HStack {
                                    ProgressView("Working locally…")
                                    if model.isRunningUtilityCancellable {
                                        Button("Cancel") { model.cancelUtility() }
                                            .accessibilityIdentifier("utility.cancel")
                                    }
                                }
                            }
                        }
                        .padding(15)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Convert to").font(.headline)
                            Spacer()
                            if !model.availableConversionPresets.isEmpty {
                                Menu {
                                    ForEach(model.availableConversionPresets) { preset in
                                        Button {
                                            model.apply(preset)
                                        } label: {
                                            Label(preset.displayName, systemImage: preset.symbol)
                                        }
                                    }
                                } label: {
                                    Label("Presets", systemImage: "slider.horizontal.3")
                                }
                                .accessibilityIdentifier("convert.presets")
                            }
                        }
                        if model.isDiscovering {
                            ProgressView("Checking local conversion engines…")
                        } else if model.outputFormats.isEmpty {
                            ContentUnavailableView("No shared output formats", systemImage: "questionmark.folder", description: Text("These files do not have a conversion route in the engines currently available."))
                                .frame(minHeight: 150)
                        } else {
                            ForEach(FormatCategory.allCases, id: \.self) { category in
                                let formats = model.outputFormats.filter { $0.category == category }
                                if !formats.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(category.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                                            ForEach(formats) { format in
                                                FormatButton(format: format, selected: model.selectedOutputExtension == format.fileExtension) {
                                                    model.selectOutputFormat(format)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if model.isConverting {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(model.conversionMessage ?? "Converting…").font(.subheadline.weight(.medium))
                                Spacer()
                                Button("Cancel") { model.cancelConversion() }.buttonStyle(.bordered)
                            }
                            ProgressView(value: model.progress)
                            if let current = model.currentFileName { Text(current).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let message = model.conversionMessage, !model.isConverting {
                        Label(message, systemImage: model.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.lastError == nil ? Color.green : Color.orange)
                    }
                    if let error = model.lastError {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            .padding(13).background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }

                    HStack {
                        Label("Originals are preserved", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            if let format = model.outputFormats.first(where: { $0.fileExtension == model.selectedOutputExtension }) {
                                model.startConversion(to: format, preset: model.selectedConversionPreset)
                            }
                        } label: {
                            Label("Convert \(model.selectedFiles.count) file\(model.selectedFiles.count == 1 ? "" : "s")", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedOutputExtension == nil || model.isConverting || model.isDiscovering)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .sheet(item: $model.metadataSheet) { sheet in
            switch sheet {
            case .inspector:
                MetadataInspectorSheet(reports: model.metadataReports)
            case .editor:
                MetadataEditorSheet(
                    fileCount: model.selectedFiles.count,
                    supportsAuthor: model.selectedFiles.allSatisfy { $0.pathExtension.lowercased() == "pdf" },
                    onSave: model.applyMetadataEdits
                )
            }
        }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "webp", "tiff", "gif": "photo"
        case "mp4", "mov", "mkv", "avi", "webm": "video"
        case "mp3", "wav", "flac", "m4a", "ogg": "waveform"
        case "zip", "7z", "gz", "xz", "bz2": "archivebox"
        default: "doc"
        }
    }
}

struct OperationsView: View {
    @EnvironmentObject private var model: MorphModel
    @State private var files: [URL] = []
    @State private var prefix = "Renamed"

    private var previewTargets: [BatchRenameTarget] {
        (try? model.batchRenamePlan(inputs: files, prefix: prefix)) ?? []
    }

    private var planError: String? {
        guard !files.isEmpty else { return nil }
        do {
            _ = try model.batchRenamePlan(inputs: files, prefix: prefix)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("File operations").font(.largeTitle.bold())
                    Text("Create renamed copies without changing the originals.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Batch rename copies").font(.title2.weight(.semibold))
                            Text("Morph adds a numbered prefix and keeps each full filename, including compound extensions.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            chooseFiles()
                        } label: {
                            Label("Choose Files", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("operations.choose-files")
                    }

                    TextField("Name prefix", text: $prefix)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("operations.rename-prefix")

                    if files.isEmpty {
                        ContentUnavailableView(
                            "No files selected",
                            systemImage: "text.line.first.and.arrowtriangle.forward",
                            description: Text("Choose one or more files to preview numbered renamed copies.")
                        )
                        .frame(minHeight: 160)
                    } else {
                        HStack {
                            Text("Files (\(files.count))").font(.headline)
                            Spacer()
                            Button("Clear") { files = [] }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(previewTargets.prefix(8))) { target in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(target.outputURL.lastPathComponent)
                                        .font(.callout.weight(.medium)).lineLimit(1)
                                    Text(target.outputURL.deletingLastPathComponent().path)
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                            if files.count > 8 {
                                Text("And \(files.count - 8) more…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let planError {
                        Label(planError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }

                    Text(outputLocationDescription)
                        .font(.caption).foregroundStyle(.secondary)

                    if model.isRunningUtility {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(model.conversionMessage ?? "Creating renamed copies…")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                if model.isRunningUtilityCancellable {
                                    Button("Cancel") { model.cancelUtility() }.buttonStyle(.bordered)
                                }
                            }
                            ProgressView(value: model.progress)
                            if let current = model.currentFileName {
                                Text(current).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    } else if let message = model.conversionMessage {
                        Label(message, systemImage: model.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(model.lastError == nil ? Color.green : Color.orange)
                    }

                    if let error = model.lastError {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }

                    HStack {
                        Label("Originals are preserved", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.createRenamedCopies(inputs: files, prefix: prefix)
                        } label: {
                            Label("Create renamed copies", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("operations.create-renamed-copies")
                        .disabled(previewTargets.isEmpty || model.isRunningUtility || model.isConverting || model.activeEngineAction != nil)
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(30)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }

    private var outputLocationDescription: String {
        switch model.settings.outputMode {
        case .alongsideOriginal:
            "Copies are saved beside each original file."
        case .morphFolder:
            "Copies are saved in Documents/Morph Output."
        case .custom:
            if let path = model.settings.customOutputPath {
                "Copies are saved in \(path)."
            } else {
                "No custom folder is selected; copies are saved beside each original."
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose files to rename"
        panel.prompt = "Add Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { files = panel.urls }
    }
}

private struct MetadataInspectorSheet: View {
    let reports: [MetadataReport]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File metadata").font(.title2.bold())
                    Text("Read locally from the selected files. No file contents were changed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(reports) { report in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(report.fileName).font(.headline).textSelection(.enabled)
                            if let error = report.error {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                            } else {
                                ForEach(report.entries) { entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                                        Text(entry.label)
                                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                            .frame(width: 130, alignment: .leading)
                                        Text(entry.value)
                                            .font(.callout).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 380)
    }
}

private struct MetadataEditorSheet: View {
    let fileCount: Int
    let supportsAuthor: Bool
    let onSave: (FileMetadataEdits) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var subject = ""
    @State private var keywords = ""

    private var edits: FileMetadataEdits {
        FileMetadataEdits(
            title: optionalValue(title),
            author: supportsAuthor ? optionalValue(author) : nil,
            subject: optionalValue(subject),
            keywords: parsedKeywords
        )
    }

    private var parsedKeywords: [String]? {
        let values = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private var hasEdits: Bool { edits.hasChanges }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Edit metadata").font(.title2.bold())
                Text("Create a new copy for \(fileCount) selected file\(fileCount == 1 ? "" : "s"). Originals stay unchanged.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Form {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("metadata-edit.title")
                if supportsAuthor {
                    TextField("Author", text: $author)
                        .accessibilityIdentifier("metadata-edit.author")
                }
                TextField("Subject", text: $subject)
                    .accessibilityIdentifier("metadata-edit.subject")
                TextField("Keywords (comma separated)", text: $keywords)
                    .accessibilityIdentifier("metadata-edit.keywords")
            }
            .formStyle(.grouped)

            Text(supportsAuthor
                 ? "Blank fields preserve existing values. Keywords replace the current keyword list."
                 : "Blank fields preserve existing values. Keywords replace the current keyword list. Image author editing is unavailable.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Copies") {
                    onSave(edits)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!hasEdits)
                .accessibilityIdentifier("metadata-edit.create-copies")
            }
        }
        .padding(22)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 390)
    }

    private func optionalValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct FormatButton: View {
    let format: MorphFormat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(format.displayName).font(.subheadline.weight(.semibold))
                    Text(".\(format.fileExtension)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }
            .padding(11)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(selected ? Color.accentColor.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: MorphModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("History").font(.largeTitle.bold())
                Text("Conversions run on this Mac. History stores file names and output paths locally.")
                    .foregroundStyle(.secondary)
                if model.history.isEmpty {
                    ContentUnavailableView("No conversions yet", systemImage: "clock.arrow.circlepath", description: Text("Completed conversions will appear here."))
                        .frame(minHeight: 300)
                } else {
                    VStack(spacing: 9) {
                        ForEach(model.history) { item in HistoryRow(item: item) }
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject private var model: MorphModel
    let item: HistoryItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.inputName).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(URL(fileURLWithPath: item.outputPath).lastPathComponent + " · " + item.engineName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
            Button { model.showOutput(item.outputPath) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain).help("Reveal in Finder")
        }
        .padding(13).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EnginesView: View {
    @EnvironmentObject private var model: MorphModel
    private let externalEngines: [EngineID] = [.ffmpeg, .imageMagick, .pandoc, .poppler, .ghostscript, .sevenZip, .libreOffice]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Engines").font(.largeTitle.bold())
                    Text("Morph detects local tools and only installs an engine after you confirm.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], alignment: .leading, spacing: 10) {
                    EngineCard(id: .nativeImage, status: model.registry?.status(for: .nativeImage), routeCount: routeCount(.nativeImage))
                    EngineCard(id: .nativePDF, status: model.registry?.status(for: .nativePDF), routeCount: routeCount(.nativePDF))
                    EngineCard(id: .structuredData, status: model.registry?.status(for: .structuredData), routeCount: routeCount(.structuredData))
                    EngineCard(id: .archive, status: model.registry?.status(for: .archive), routeCount: routeCount(.archive))
                }
                VStack(spacing: 10) {
                    ForEach(externalEngines, id: \.self) { id in
                        EngineRow(id: id, status: model.registry?.status(for: id), routeCount: routeCount(id))
                    }
                }
                if model.isDiscovering { ProgressView("Checking installed tools…") }
                if let message = model.conversionMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                if let error = model.lastError { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Text("Available routes are based on engine support detected on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { model.refreshEngines() }
                }
            }
            .padding(30)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }

    private func routeCount(_ id: EngineID) -> Int { model.registry?.routes.filter { $0.engine == id }.count ?? 0 }
}

private struct EngineCard: View {
    let id: EngineID
    let status: EngineStatus?
    let routeCount: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "apple.terminal").font(.title2).foregroundStyle(Color.accentColor)
            Text(id.displayName).font(.headline)
            Text("Built into macOS").font(.caption).foregroundStyle(.secondary)
            Text("\(routeCount) conversion routes").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct EngineRow: View {
    @EnvironmentObject private var model: MorphModel
    let id: EngineID
    let status: EngineStatus?
    let routeCount: Int

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: status?.isInstalled == true ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2).foregroundStyle(status?.isInstalled == true ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(id.displayName).font(.headline)
                    if let version = status?.version { Text(version).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                }
                Text(id.summary).font(.caption).foregroundStyle(.secondary)
                Text(statusDescription)
                    .font(.caption2).foregroundStyle(status?.isInstalled == true ? .green : .secondary)
                Text(capabilitySummary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if model.activeEngineAction == id {
                ProgressView()
                    .controlSize(.small)
                    .help("Waiting for the engine action to finish")
            }
            if status?.isInstalled == true {
                Button("Check for updates") { model.checkForUpdates(id) }.buttonStyle(.bordered)
                if model.updatesAvailable.contains(id) {
                    Button("Update…") { model.updateEngine(id) }.buttonStyle(.borderedProminent)
                }
                Button("Uninstall") { model.uninstallEngine(id) }.buttonStyle(.bordered)
            } else if id.homebrewFormula != nil {
                Button("Install…") { model.installEngine(id) }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("engine.install.\(id.rawValue)")
            }
        }
        .disabled(model.activeEngineAction != nil || model.isConverting || model.isRunningUtility)
        .padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var capabilitySummary: String {
        if id == .ghostscript { return "Operation: PDF compression presets" }
        let pairs = Array(Set((model.registry?.routes ?? []).filter { $0.engine == id }.map {
            ".\($0.inputExtension) → .\($0.output.fileExtension)"
        })).sorted()
        guard !pairs.isEmpty else { return "No conversion routes currently available." }
        return "Formats: " + pairs.prefix(4).joined(separator: ", ") + (pairs.count > 4 ? " · +\(pairs.count - 4)" : "")
    }

    private var statusDescription: String {
        if id == .ghostscript {
            return status?.isInstalled == true ? "Installed · PDF compression enabled" : "Not installed · enables PDF compression"
        }
        return status?.isInstalled == true ? "Installed · \(routeCount) advertised routes" : "Not installed · optional local engine"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: MorphModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Text("Output location").font(.headline)
                    Picker("Save converted files", selection: $model.settings.outputMode) {
                        ForEach(OutputMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.radioGroup)
                    if model.settings.outputMode == .custom {
                        HStack {
                            Text(model.settings.customOutputPath ?? "No folder selected").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Choose…") { model.chooseCustomOutputFolder() }
                        }
                    }
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Finder conversion formats").font(.headline)
                            Text("Choose the output types shown under Convert To. Finder only offers a type when every selected file has a supported route.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !model.finderOutputFormats.isEmpty {
                            Button("Show All") {
                                model.settings.finderHiddenOutputExtensions = []
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.settings.finderHiddenOutputExtensions.isEmpty)
                        }
                    }

                    if model.isDiscovering {
                        ProgressView("Checking installed formats…")
                            .padding(.vertical, 8)
                    } else if model.finderOutputFormats.isEmpty {
                        ContentUnavailableView("No Finder formats available", systemImage: "arrow.left.arrow.right", description: Text("Install or enable a conversion engine to add supported output types."))
                            .frame(minHeight: 120)
                    } else {
                        ForEach(FormatCategory.allCases, id: \.self) { category in
                            let formats = model.finderOutputFormats.filter { $0.category == category }
                            if !formats.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(category.rawValue).font(.subheadline.weight(.semibold))
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), alignment: .leading)], alignment: .leading, spacing: 5) {
                                        ForEach(formats) { format in
                                            Toggle(isOn: Binding(
                                                get: { !model.settings.finderHiddenOutputExtensions.contains(format.fileExtension) },
                                                set: { model.setFinderOutputEnabled(format.fileExtension, enabled: $0) }
                                            )) {
                                                Text("\(format.displayName) (.\(format.fileExtension))")
                                                    .lineLimit(1)
                                            }
                                            .toggleStyle(.checkbox)
                                            .accessibilityIdentifier("settings.finder-format.\(format.fileExtension)")
                                        }
                                    }
                                }
                                .padding(.top, 5)
                            }
                        }
                    }
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Image quality").font(.headline)
                    HStack {
                        Slider(value: $model.settings.imageQuality, in: 0.3...1.0, step: 0.05)
                        Text("\(Int(model.settings.imageQuality * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Text("Used by lossy image formats such as JPEG and WebP. Supported formats preserve metadata when the engine allows it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 10) {
                    Text("PDF compression").font(.headline)
                    Picker("Compression preset", selection: $model.settings.pdfCompressionPreset) {
                        ForEach(PDFCompressionPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.pdf-compression-preset")
                    Text("Compact files use stronger image downsampling. Print quality keeps more detail. Compression creates a new copy and may change metadata, links, forms or annotations; signatures on the original will not remain valid. Ghostscript is installed only after you approve it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))

                Toggle("Reveal completed output in Finder", isOn: $model.settings.revealOutputAfterConversion)
                    .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Appearance").font(.headline)
                    Text("Morph follows your macOS appearance. On macOS 26 and later, the main Choose Files action uses Liquid Glass; older supported versions use a bordered button. Native controls and materials adapt to accessibility settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Privacy & safety").font(.headline)
                    Text("Files are processed locally. Morph does not upload content or replace originals. Optional engine installation and updates require a separate confirmation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
            }
            .padding(30)
            .frame(maxWidth: 850, alignment: .leading)
        }
    }
}
