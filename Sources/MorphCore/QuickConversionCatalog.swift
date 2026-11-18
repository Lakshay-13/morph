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

        let outputSets = inputs.map { input in
            Set(registry.availableOutputs(for: input)
                .filter { registry.isAvailable($0.engine) }
                .map { $0.output.fileExtension })
        }
        guard var common = outputSets.first else { return [] }
        for outputs in outputSets.dropFirst() {
            common.formIntersection(outputs)
            if common.isEmpty { return [] }
        }

        let hidden = Set(hiddenOutputExtensions.map { $0.lowercased() })
        let availableRoutes = registry.routes.filter {
            common.contains($0.output.fileExtension)
                && !hidden.contains($0.output.fileExtension)
                && registry.isAvailable($0.engine)
        }
        let uniqueFormats = Dictionary(availableRoutes.map { ($0.output.fileExtension, $0.output) }, uniquingKeysWith: { first, _ in first })
        return uniqueFormats.values.sorted {
            let firstCategory = FormatCategory.allCases.firstIndex(of: $0.category) ?? .max
            let secondCategory = FormatCategory.allCases.firstIndex(of: $1.category) ?? .max
            if firstCategory != secondCategory { return firstCategory < secondCategory }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.fileExtension < $1.fileExtension
        }
    }
}
