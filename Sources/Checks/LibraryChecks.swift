import Foundation
import Catalog
import LibraryLogic

enum LibraryChecks {
    static func run(_ c: Checks) {
        c.suite("Library model (Build plan section 7)") { c in
            var a = ImageRecord(path: "/library/a.RAF", fingerprint: "1")
            var b = ImageRecord(path: "/library/b.JPG", fingerprint: "2")
            a.captureDate = Date(timeIntervalSince1970: 20); b.captureDate = Date(timeIntervalSince1970: 10)
            a.rating = 5; b.rating = 2; a.flag = 1; b.flag = -1
            let dates = [a.path: Date(timeIntervalSince1970: 1), b.path: Date(timeIntervalSince1970: 2)]
            for (sort, expected) in [(LibrarySort.filename, [a.path, b.path]), (.captureDate, [b.path, a.path]), (.fileDate, [a.path, b.path]), (.rating, [a.path, b.path])] {
                let actual = [b, a].sorted { sort.precedes($0, $1, fileDates: dates) }.map(\.path)
                c.expect(actual == expected && !sort.precedes(a, a, fileDates: dates), "\(sort.rawValue) comparator; rows=\(actual.count), first=\(actual.first ?? "nil"), self-order=\(sort.precedes(a, a, fileDates: dates))")
            }
            var tied = b; tied.captureDate = a.captureDate; tied.rating = a.rating; tied.filename = a.filename
            let stable = LibrarySort.allCases.filter { $0.precedes(a, tied) && !$0.precedes(tied, a) }.count
            c.expect(stable == 4, "ties use independent full paths; stable comparators=\(stable)/4")
            var missing = b; missing.captureDate = nil
            c.expect(LibrarySort.captureDate.precedes(missing, a), "missing capture date sorts first; missing dates=\([missing, a].filter { $0.captureDate == nil }.count)")
            var filter = LibraryFilter()
            c.expect([a, b].filter(filter.matches).count == 2, "default filter includes 2/2 records; actual=\([a, b].filter(filter.matches).count)")
            filter.fileType = "raf"
            c.expect([a, b].filter(filter.matches) == [a], "RAF type predicate; matches=\([a, b].filter(filter.matches).count)/2")
            filter.fileType = "All"; filter.minimumRating = 3
            c.expect([a, b].filter(filter.matches) == [a], "rating >=3 predicate; matches=\([a, b].filter(filter.matches).count)/2")
            filter.minimumRating = 2; filter.flag = -1
            c.expect([a, b].filter(filter.matches) == [b], "inclusive rating and reject predicate; matches=\([a, b].filter(filter.matches).count)/2")
            filter.flag = 0
            c.expect([a, b].filter(filter.matches).isEmpty, "unflagged excludes picks/rejects; matches=\([a, b].filter(filter.matches).count)/2")
            let cases: [(Int?, Int, Int, Int?)] = [(0, -1, 3, 0), (2, 1, 3, 2), (0, -8, 3, 0), (2, 8, 3, 2), (1, 1, 3, 2), (1, -1, 3, 0), (nil, 1, 3, 0), (nil, -1, 0, nil), (0, 1, 1, 0), (0, -1, 1, 0)]
            for (index, delta, count, expected) in cases {
                let actual = LibraryKey.move(index: index, by: delta, count: count)
                c.expect(actual == expected, "selection boundary count=\(count), index=\(index ?? -1), delta=\(delta), result=\(actual ?? -1), expected=\(expected ?? -1)")
            }
            let ratings = (0...5).filter { LibraryKey.map(String($0)) == .rating($0) }.count
            c.expect(ratings == 6, "rating keys map 0–5; matched=\(ratings)/6")
            let flags = ["p", "P", "x", "X"].compactMap(LibraryKey.map)
            c.expect(flags == [.flag(1), .flag(1), .flag(-1), .flag(-1)], "case-insensitive flag keys; mapped=\(flags.count)/4")
            let ignored = ["6", "9", "-1", "", "00", "z"].filter { LibraryKey.map($0) == nil }.count
            c.expect(ignored == 6, "unsupported keys ignored; ignored=\(ignored)/6")
            c.expect(LibraryKey.map("\r") == .open && LibraryKey.map("\u{3}") == .open, "Return and keypad Enter open; mapped=2/2")
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let lease = FolderAccess(dir)
            defer { withExtendedLifetime(lease) {} }
            let data = try FolderBookmark.encode(dir)
            let suite = "library-check-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set([data], forKey: "roots")
            let restored = defaults.array(forKey: "roots") as? [Data] ?? []
            let decoded = try FolderBookmark.decode(restored[0])
            // Directory hints/trailing slashes can make Foundation URLs unequal for the same path.
            c.expect(decoded.url.standardizedFileURL.resolvingSymlinksInPath().path == dir.standardizedFileURL.resolvingSymlinksInPath().path && !data.isEmpty && restored.count == 1,
                     "security bookmark persists and resolves; bytes=\(data.count), restored=\(restored.count), stale=\(decoded.stale)")
            var rejected = 0
            do { _ = try FolderBookmark.decode(Data([0, 1, 2])) } catch { rejected += 1 }
            c.expect(rejected == 1, "invalid bookmark reports error; rejected=\(rejected)/1")
        }
    }
}
