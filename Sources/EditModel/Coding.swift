import Foundation

/// Synthesized `Codable` ignores property defaults: a key missing from the JSON throws
/// rather than falling back. Build plan §2 requires the opposite - a sidecar written by
/// an earlier build must stay readable once new fields are added - so every adjustment
/// group decodes through these helpers instead.
extension KeyedDecodingContainer {
    func value(_ key: Key, _ fallback: Double) -> Double {
        (try? decodeIfPresent(Double.self, forKey: key)) .flatMap { $0 } ?? fallback
    }
    func value(_ key: Key, _ fallback: Bool) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)).flatMap { $0 } ?? fallback
    }
    func value(_ key: Key, _ fallback: Int) -> Int {
        (try? decodeIfPresent(Int.self, forKey: key)).flatMap { $0 } ?? fallback
    }
    func value(_ key: Key, _ fallback: String) -> String {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0 } ?? fallback
    }
}
