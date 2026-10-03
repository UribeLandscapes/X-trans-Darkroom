import Foundation
import SQLite3
import RawDecode

public struct ImageRecord: Sendable, Equatable {
    public var id: Int64?
    public var path: String
    public var folder: String
    public var filename: String
    public var ext: String
    public var fingerprint: String
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraSource: CameraSource { CameraSource.read(URL(fileURLWithPath: path), make: cameraMake ?? "") }
    public var cameraModel: String?
    public var lensModel: String?
    public var iso: Int?
    public var aperture: Double?
    public var shutter: Double?
    public var focalLength: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var rating = 0
    public var flag = 0
    public var colorLabel = ""
    public var editHash = ""
    public var isRaw = false

    public init(path: String, fingerprint: String) {
        let url = URL(fileURLWithPath: path)
        self.path = path
        folder = url.deletingLastPathComponent().path
        filename = url.lastPathComponent
        ext = url.pathExtension.lowercased()
        self.fingerprint = fingerprint
        isRaw = SupportedFormats.isRaw(ext)
    }
}

public enum CatalogSort: Sendable {
    case filename, captureDate, rating
    case filenameDescending, captureDateDescending, ratingDescending

    fileprivate var sql: String {
        switch self {
        case .filename: "filename ASC, path ASC"
        case .captureDate: "capture_date ASC, path ASC"
        case .rating: "rating ASC, path ASC"
        case .filenameDescending: "filename DESC, path ASC"
        case .captureDateDescending: "capture_date DESC, path ASC"
        case .ratingDescending: "rating DESC, path ASC"
        }
    }
}

public struct CatalogFilter: Sendable {
    public var minimumRating: Int?
    public var flag: Int?
    public var colorLabel: String?
    public var isRaw: Bool?

    public init(minimumRating: Int? = nil, flag: Int? = nil,
                colorLabel: String? = nil, isRaw: Bool? = nil) {
        self.minimumRating = minimumRating
        self.flag = flag
        self.colorLabel = colorLabel
        self.isRaw = isRaw
    }
}

public struct CatalogError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

// Ownership stays inside Catalog; the wrapper lets deinit close the handle without
// transferring a non-Sendable C pointer out of the actor's isolation domain.
private final class DatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close_v2(pointer) }
}

/// A REBUILDABLE INDEX over files and sidecars, never a source of truth.
public actor Catalog {
    private let database: DatabaseHandle

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database"
            if let pointer { sqlite3_close_v2(pointer) }
            throw CatalogError(description: message)
        }
        database = DatabaseHandle(pointer)
        sqlite3_busy_timeout(pointer, 5_000)
        let schema = """
        CREATE TABLE IF NOT EXISTS images (
            id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, folder TEXT NOT NULL,
            filename TEXT NOT NULL, ext TEXT NOT NULL, fingerprint TEXT NOT NULL,
            capture_date REAL, camera_model TEXT, lens_model TEXT, iso INTEGER,
            aperture REAL, shutter REAL, focal_length REAL,
            pixel_width INTEGER, pixel_height INTEGER,
            rating INTEGER NOT NULL DEFAULT 0, flag INTEGER NOT NULL DEFAULT 0,
            color_label TEXT NOT NULL DEFAULT '', edit_hash TEXT NOT NULL DEFAULT '',
            is_raw INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS images_folder ON images(folder);
        CREATE INDEX IF NOT EXISTS images_capture_date ON images(capture_date);
        CREATE INDEX IF NOT EXISTS images_rating ON images(rating);
        """
        guard sqlite3_exec(pointer, schema, nil, nil, nil) == SQLITE_OK else {
            throw CatalogError(description: String(cString: sqlite3_errmsg(pointer)))
        }
        // Append the new column so existing SELECT * offsets remain stable.
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, "PRAGMA table_info(images)", -1, &columns, nil) == SQLITE_OK,
              let columns else { throw CatalogError(description: String(cString: sqlite3_errmsg(pointer))) }
        var hasMake = false
        while sqlite3_step(columns) == SQLITE_ROW {
            if let name = sqlite3_column_text(columns, 1), String(cString: name) == "camera_make" { hasMake = true }
        }
        sqlite3_finalize(columns)
        if !hasMake, sqlite3_exec(pointer, "ALTER TABLE images ADD COLUMN camera_make TEXT", nil, nil, nil) != SQLITE_OK {
            throw CatalogError(description: String(cString: sqlite3_errmsg(pointer)))
        }
    }

    @discardableResult
    public func upsert(_ record: ImageRecord) throws -> Int64 {
        try write(record, preservingAnnotations: false)
    }

    // Scan refreshes only file facts: indexing a changed source must not discard
    // annotations already recovered from sidecars or supplied by the caller.
    @discardableResult
    func index(_ record: ImageRecord) throws -> Int64 {
        try write(record, preservingAnnotations: true)
    }

    private func write(_ r: ImageRecord, preservingAnnotations: Bool) throws -> Int64 {
        let annotationUpdates = preservingAnnotations ? "" : """
        , rating=excluded.rating, flag=excluded.flag, color_label=excluded.color_label,
        edit_hash=excluded.edit_hash
        """
        let sql = """
        INSERT INTO images (path,folder,filename,ext,fingerprint,capture_date,camera_model,
        lens_model,iso,aperture,shutter,focal_length,pixel_width,pixel_height,rating,flag,color_label,edit_hash,is_raw,camera_make)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET folder=excluded.folder, filename=excluded.filename,
        ext=excluded.ext, fingerprint=excluded.fingerprint, capture_date=excluded.capture_date,
        camera_model=excluded.camera_model, lens_model=excluded.lens_model, iso=excluded.iso,
        aperture=excluded.aperture, shutter=excluded.shutter, focal_length=excluded.focal_length,
        pixel_width=excluded.pixel_width, pixel_height=excluded.pixel_height, is_raw=excluded.is_raw, camera_make=excluded.camera_make
        """ + annotationUpdates + " RETURNING id"
        return try statement(sql, [
            .text(r.path), .text(r.folder), .text(r.filename), .text(r.ext), .text(r.fingerprint),
            .real(r.captureDate?.timeIntervalSince1970), .optionalText(r.cameraModel), .optionalText(r.lensModel),
            .integer(r.iso), .real(r.aperture), .real(r.shutter), .real(r.focalLength),
            .integer(r.pixelWidth), .integer(r.pixelHeight), .integer(r.rating), .integer(r.flag),
            .text(r.colorLabel), .text(r.editHash), .integer(SupportedFormats.isRaw(r.ext) ? 1 : 0), .optionalText(r.cameraMake)
        ]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
            let id = sqlite3_column_int64(stmt, 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            return id
        }
    }

    public func record(path: String) throws -> ImageRecord? {
        try records("SELECT * FROM images WHERE path = ?", [.text(path)]).first
    }

    public func matches(path: String, fingerprint: String) throws -> Bool {
        try statement("SELECT 1 FROM images WHERE path = ? AND fingerprint = ? AND camera_make IS NOT NULL", [.text(path), .text(fingerprint)]) { stmt in
            let result = sqlite3_step(stmt)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
            return result == SQLITE_ROW
        }
    }

    public func fetch(folder: String? = nil, sortBy: CatalogSort = .filename,
                      filter: CatalogFilter = .init()) throws -> [ImageRecord] {
        var clauses: [String] = []
        var values: [Value] = []
        if let folder { clauses.append("folder = ?"); values.append(.text(folder)) }
        if let rating = filter.minimumRating { clauses.append("rating >= ?"); values.append(.integer(rating)) }
        if let flag = filter.flag { clauses.append("flag = ?"); values.append(.integer(flag)) }
        if let label = filter.colorLabel { clauses.append("color_label = ?"); values.append(.text(label)) }
        if let raw = filter.isRaw { clauses.append("is_raw = ?"); values.append(.integer(raw ? 1 : 0)) }
        // Only closed, internal SQL fragments are composed; file and user values are bound.
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return try records("SELECT * FROM images" + predicate + " ORDER BY " + sortBy.sql, values)
    }

    public func setRating(_ rating: Int, for id: Int64) throws {
        try execute("UPDATE images SET rating = ? WHERE id = ?", [.integer(rating), .int64(id)])
    }
    public func setFlag(_ flag: Int, for id: Int64) throws {
        try execute("UPDATE images SET flag = ? WHERE id = ?", [.integer(flag), .int64(id)])
    }
    public func setColorLabel(_ label: String, for id: Int64) throws {
        try execute("UPDATE images SET color_label = ? WHERE id = ?", [.text(label), .int64(id)])
    }
    public func delete(id: Int64) throws {
        try execute("DELETE FROM images WHERE id = ?", [.int64(id)])
    }
    public func count() throws -> Int {
        try statement("SELECT COUNT(*) FROM images", []) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private enum Value {
        case text(String), int64(Int64), integer(Int?), real(Double?), optionalText(String?)
    }

    private func failure() -> CatalogError {
        CatalogError(description: String(cString: sqlite3_errmsg(database.pointer)))
    }

    private func statement<T>(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared else { throw failure() }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let status: Int32
            switch value {
            case .text(let s):
                status = s.withCString { sqlite3_bind_text(prepared, i, $0, Int32(s.utf8.count), transient) }
            case .optionalText(let s):
                status = s.map { s in s.withCString { sqlite3_bind_text(prepared, i, $0, Int32(s.utf8.count), transient) } }
                    ?? sqlite3_bind_null(prepared, i)
            case .int64(let n): status = sqlite3_bind_int64(prepared, i, n)
            case .integer(let n): status = n.map { sqlite3_bind_int64(prepared, i, Int64($0)) } ?? sqlite3_bind_null(prepared, i)
            case .real(let n): status = n.map { sqlite3_bind_double(prepared, i, $0) } ?? sqlite3_bind_null(prepared, i)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        return try body(prepared)
    }

    private func execute(_ sql: String, _ values: [Value]) throws {
        try statement(sql, values) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
    }

    private func records(_ sql: String, _ values: [Value]) throws -> [ImageRecord] {
        try statement(sql, values) { stmt in
            func string(_ i: Int32) -> String? {
                guard let bytes = sqlite3_column_text(stmt, i) else { return nil }
                let count = Int(sqlite3_column_bytes(stmt, i))
                return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            }
            func integer(_ i: Int32) -> Int? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
            }
            func real(_ i: Int32) -> Double? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
            }
            var rows: [ImageRecord] = []
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else { throw failure() }
                var r = ImageRecord(path: string(1)!, fingerprint: string(5)!)
                r.id = sqlite3_column_int64(stmt, 0)
                r.folder = string(2)!; r.filename = string(3)!; r.ext = string(4)!
                r.captureDate = real(6).map(Date.init(timeIntervalSince1970:))
                r.cameraModel = string(7); r.lensModel = string(8); r.iso = integer(9)
                r.aperture = real(10); r.shutter = real(11); r.focalLength = real(12)
                r.pixelWidth = integer(13); r.pixelHeight = integer(14)
                r.rating = integer(15)!; r.flag = integer(16)!
                r.colorLabel = string(17)!; r.editHash = string(18)!; r.isRaw = SupportedFormats.isRaw(r.ext)
                r.cameraMake = string(20)
                rows.append(r)
            }
        }
    }
}
