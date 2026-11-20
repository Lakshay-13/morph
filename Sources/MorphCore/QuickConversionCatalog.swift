import Foundation

/// Builds Finder-friendly output choices for the current selection.
///
/// A target is included only when every selected file has an installed route to it.
public enum QuickConversionCatalog {
    public static func availableOutputs(
        for inputs: [URL],
        registry: EngineRegistry,
        hiddenOutputExtensions: Set<String> = []
    ) -> [MorphFormat] {
        guard !inputs.isEmpty else { return [] }

        let routesByInput = inputs.map { input in
            registry.availableOutputs(for: input)
                .filter { registry.isAvailable($0.engine) }
        }
        let outputSets = routesByInput.map { routes in
            Set(routes.map { $0.output.fileExtension })
        }
        guard var common = outputSets.first else { return [] }
        for outputs in outputSets.dropFirst() {
            common.formIntersection(outputs)
            if common.isEmpty { return [] }
        }

        let hidden = Set(hiddenOutputExtensions.map { $0.lowercased() })
        return common.compactMap { fileExtension in
            guard !hidden.contains(fileExtension) else { return nil }
            let selectionRoutes = routesByInput.map { routes in
                routes.filter { $0.output.fileExtension == fileExtension }
            }
            let outputs = selectionRoutes.flatMap { $0 }.map(\.output)
            guard let first = outputs.first else { return nil }
            let outputFormats = Set(outputs)
            if outputFormats.count == 1 { return first }
            if fileExtension == "zip" {
                let allPDFs = inputs.allSatisfy { $0.pathExtension.lowercased() == "pdf" }
                if allPDFs, let pdfPageFormat = outputs.first(where: { $0.displayName == "PNG images" }) {
                    return pdfPageFormat
                }
                return MorphFormat("zip", inputs.count == 1 ? "ZIP archive" : "ZIP archive or PDF page images", .archive)
            }
            if fileExtension == "gif" {
                return MorphFormat("gif", "GIF image or animation", .image)
            }
            return outputs.sorted {
                let firstCategory = FormatCategory.allCases.firstIndex(of: $0.category) ?? .max
                let secondCategory = FormatCategory.allCases.firstIndex(of: $1.category) ?? .max
                if firstCategory != secondCategory { return firstCategory < secondCategory }
                return $0.displayName < $1.displayName
            }.first
        }.sorted {
            let firstCategory = FormatCategory.allCases.firstIndex(of: $0.category) ?? .max
            let secondCategory = FormatCategory.allCases.firstIndex(of: $1.category) ?? .max
            if firstCategory != secondCategory { return firstCategory < secondCategory }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.fileExtension < $1.fileExtension
        }
    }
}
