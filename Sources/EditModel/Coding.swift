import Foundation

/// Synthesized `Codable` ignores property defaults: a key missing from the JSON throws
/// rather than falling back. Build plan §2 requires the opposite - a sidecar written by
/// an earlier build must stay readable once new fields are added - so every adjustment
/// group decodes through these helpers instead.
extension KeyedDecodingContainer {
    func value(_ key: Key, _ fallback: Double) throws -> Double {
        (try decodeIfPresent(Double.self, forKey: key)) ?? fallback
    }
    func value(_ key: Key, _ fallback: Bool) throws -> Bool {
        (try decodeIfPresent(Bool.self, forKey: key)) ?? fallback
    }
    func value(_ key: Key, _ fallback: Int) throws -> Int {
        (try decodeIfPresent(Int.self, forKey: key)) ?? fallback
    }
    func value(_ key: Key, _ fallback: String) throws -> String {
        (try decodeIfPresent(String.self, forKey: key)) ?? fallback
    }
}
