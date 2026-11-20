import Foundation

/// Retains recent Finder request identifiers so Launch Services retries remain
/// idempotent even when the background conversion helper is relaunched.
public struct FinderRequestIDLedger: Codable, Sendable {
    public static let capacity = 2_048
    private var orderedIDs: [String]

    public init() {
        orderedIDs = []
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var uniqueIDs: [String] = []
        var seen = Set<String>()
        while !container.isAtEnd {
            let identifier = try container.decode(String.self)
            guard let uuid = UUID(uuidString: identifier) else { continue }
            let normalized = uuid.uuidString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            uniqueIDs.append(normalized)
            if uniqueIDs.count > Self.capacity {
                let removed = uniqueIDs.removeFirst()
                seen.remove(removed)
            }
        }
        orderedIDs = uniqueIDs
    }

    public func contains(_ identifier: String) -> Bool {
        guard let uuid = UUID(uuidString: identifier) else { return false }
        return orderedIDs.contains(uuid.uuidString.lowercased())
    }

    @discardableResult
    public mutating func register(_ identifier: String) -> Bool {
        guard let uuid = UUID(uuidString: identifier) else { return false }
        let normalized = uuid.uuidString.lowercased()
        guard !orderedIDs.contains(normalized) else { return false }
        orderedIDs.append(normalized)
        if orderedIDs.count > Self.capacity { orderedIDs.removeFirst(orderedIDs.count - Self.capacity) }
        return true
    }

    public var requestIDs: [String] { orderedIDs }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for identifier in orderedIDs { try container.encode(identifier) }
    }
}
