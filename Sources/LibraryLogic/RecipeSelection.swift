import Catalog

public struct RecipeSelection: Sendable {
    public let eligible: [ImageRecord]
    public let total: Int
    public var skipped: Int { total - eligible.count }
    public init(_ rows: [ImageRecord]) {
        total = rows.count
        eligible = rows.filter { $0.cameraSource.isFujifilmRAF }
    }
    public func status(applied: Int) -> String {
        "Applied to \(applied) of \(total) (skipped non-Fujifilm RAF)"
    }
}
