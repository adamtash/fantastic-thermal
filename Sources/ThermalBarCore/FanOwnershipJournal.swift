import Foundation

/// A tiny, root-owned crash journal. Written only when ownership changes, never
/// on sensor polls or steady fan targets. A restarted helper can release exactly
/// the fans its previous process claimed.
public struct FanOwnershipJournal: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> Set<Int> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([Int].self, from: Data(contentsOf: url))
        guard values.count <= 16, values.allSatisfy({ (0..<16).contains($0) }) else {
            throw ThermalBarError.writeRejected("Invalid saved fan ownership")
        }
        return Set(values)
    }

    public func save(_ fans: Set<Int>) throws {
        guard fans.allSatisfy({ (0..<16).contains($0) }) else {
            throw ThermalBarError.writeRejected("Invalid fan ownership")
        }
        try JSONEncoder().encode(fans.sorted()).write(to: url, options: .atomic)
    }
}
