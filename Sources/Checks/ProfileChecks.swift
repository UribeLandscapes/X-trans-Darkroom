import Foundation
import EditModel
import Profiles

enum ProfileChecks {
    static func run(_ c: Checks) {
        c.suite("Camera profiles (Build plan section 4)") { c in
            let first = ProfileMatrix([1, -0.2, 0.2, 0.1, 0.8, 0.1, 0, 0.2, 0.8])!
            let second = ProfileMatrix([0.8, 0, 0.2, 0.2, 0.8, 0, 0.1, 0.1, 0.8])!
            var profile = CameraProfile.neutral(matrix: first)
            profile.colorMatrix2 = second; profile.forwardMatrix1 = second; profile.forwardMatrix2 = first
            profile.calibrationIlluminant1 = 17; profile.calibrationIlluminant2 = 21
            for (kelvin, color, forward) in [(2850.0, first, second), (6500.0, second, first)] {
                c.expect(profile.colorMatrix(whiteBalanceKelvin: kelvin) == color && profile.forwardMatrix(whiteBalanceKelvin: kelvin) == forward,
                         "illuminant endpoint K=\(kelvin); color=\(profile.colorMatrix(whiteBalanceKelvin: kelvin)?.elements ?? []), forward=\(profile.forwardMatrix(whiteBalanceKelvin: kelvin)?.elements ?? [])")
            }
            let midpoint = 2 / (1 / 2850.0 + 1 / 6500.0)
            for matrix in [profile.colorMatrix(whiteBalanceKelvin: midpoint), profile.forwardMatrix(whiteBalanceKelvin: midpoint)] {
                let expected = zip(first.elements, second.elements).map { ($0 + $1) / 2 }
                let error = zip(matrix?.elements ?? [], expected).map { abs($0 - $1) }.max() ?? .infinity
                c.expect(error < 1e-12, "reciprocal-temperature halfway K=\(midpoint); max component error=\(error)")
            }
            c.expect(profile.colorMatrix(whiteBalanceKelvin: 1000) == first && profile.colorMatrix(whiteBalanceKelvin: 10000) == second,
                     "out-of-range WB clamps; K=1000,10000")
            let neutral = CameraProfile.neutral(matrix: first)
            let grey = neutral.colorMatrix1!.applied(to: SIMD3(repeating: 0.18))
            let curved = [grey.x, grey.y, grey.z].map { neutral.profileToneCurve!.value(at: $0) }
            c.expect(curved.allSatisfy { abs($0 - 0.18) < 1e-12 } && neutral.profileLookTable == nil && neutral.profileHueSatMap1 == nil,
                     "matrix-only neutral grey channels=\(curved); look tables=0")
            let entries: [SIMD3<Double>] = (0..<8).map { i in
                let d = Double(i)
                return SIMD3(d, 1 + d / 10, 1 + d / 20)
            }
            let grid = ProfileGrid(hueDivisions: 2, saturationDivisions: 2, valueDivisions: 2, entries: entries)!
            profile.profileHueSatMap1 = grid; profile.profileLookTable = grid
            for table in [profile.profileHueSatMap1!, profile.profileLookTable!] {
                let mid = table.lookup(hue: 0.5, saturation: 0.5, value: 0.5)
                c.expect(abs(mid.x - 3.5) < 1e-12 && abs(mid.y - 1.35) < 1e-12 && abs(mid.z - 1.175) < 1e-12,
                         "trilinear center shift/scales=\(mid)")
                let edge = table.lookup(hue: -10, saturation: 20, value: 20)
                c.expect(edge == entries[5], "clamped mixed grid edges=\(edge), expected=\(entries[5])")
                let sample = table.lookup(hue: 0.25, saturation: 0.5, value: 0.75)
                c.expectClose(sample.x, 4, "asymmetric interpolation confirms saturation-fastest layout")
            }
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let bundle = dir.appendingPathComponent("bundled")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let curve = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.25), .init(x: 1, y: 1)])
            for little in [true, false] {
                let data = fixture(little: little)
                let url = bundle.appendingPathComponent(little ? "fuji.dcp" : "fuji-big.DCP")
                try data.write(to: url)
                let parsed = DCPParser.read(from: url)
                c.expect(parsed?.colorMatrix1 == first && parsed?.colorMatrix2 == second && parsed?.forwardMatrix1 == second && parsed?.forwardMatrix2 == first,
                         "DCP endian little=\(little), parsed matrix1=\(parsed?.colorMatrix1?.elements ?? [])")
                c.expect(parsed?.profileToneCurve == curve, "DCP curve little=\(little), points=\(parsed?.profileToneCurve?.points.count ?? 0)/3")
                c.expect(parsed?.calibrationIlluminant1 == 17 && parsed?.calibrationIlluminant2 == 21 && parsed?.cameraModel == "FUJIFILM X-T5",
                         "DCP metadata illuminants=\(parsed?.calibrationIlluminant1 ?? 0),\(parsed?.calibrationIlluminant2 ?? 0)")
                let expectedGrid = ProfileGrid(hueDivisions: 2, saturationDivisions: 2, valueDivisions: 2, entries: entries.map { SIMD3(Double(Float($0.x)), Double(Float($0.y)), Double(Float($0.z))) })!
                c.expect(parsed?.profileHueSatMap1 == expectedGrid && parsed?.profileLookTable == expectedGrid,
                         "DCP grid samples=\(parsed?.profileLookTable?.entries.count ?? 0)/8")
                let rejected = (0..<data.count).filter { DCPParser.parse(Data(data.prefix($0))) == nil }.count
                c.expect(rejected == data.count, "truncated DCP rejected=\(rejected)/\(data.count), little=\(little)")
            }
            let minimal = DCPParser.parse(fixture(minimal: true))
            c.expect(minimal?.colorMatrix1 == first && minimal?.colorMatrix2 == nil && minimal?.profileToneCurve == nil && minimal?.cameraModel == nil,
                     "minimal DCP preserves missing tags; matrix elements=\(minimal?.colorMatrix1?.elements.count ?? 0)/9")
            let garbage = [Data(), Data([0, 1, 2]), Data(repeating: 255, count: 128)]
            c.expect(garbage.allSatisfy { DCPParser.parse($0) == nil }, "garbage files rejected=\(garbage.filter { DCPParser.parse($0) == nil }.count)/3")
            var cycle = fixture(); cycle.replaceSubrange(4..<8, with: [255, 255, 255, 255])
            c.expect(DCPParser.parse(cycle) == nil, "out-of-bounds IFD offset rejected; offset=4294967295")
            var library = ProfileLibrary(bundledDirectory: bundle, userDirectory: dir.appendingPathComponent("user"))
            c.expect(library.profiles(for: " fujifilm   x-t5 ").count == 2, "bundled camera matching count=\(library.profiles(for: "FUJIFILM X-T5").count)/2")
            c.expect(library.profiles(for: "Canon EOS R5").isEmpty, "non-Fuji film simulation matches=\(library.profiles(for: "Canon EOS R5").count)/0")
            let imported = try library.importProfile(from: bundle.appendingPathComponent("fuji.dcp"))
            _ = try library.importProfile(from: bundle.appendingPathComponent("fuji.dcp"))
            let userOnly = ProfileLibrary(bundledDirectory: nil, userDirectory: library.userDirectory)
            c.expect(userOnly.profiles.map(\.identifier) == [imported.identifier], "import persists and deduplicates; rediscovered=\(userOnly.profiles.count)/1")
        }
    }

    /// Construct byte fixtures independently of the parser, including an unknown tag.
    private static func fixture(little: Bool = true, minimal: Bool = false) -> Data {
        func bytes(_ value: UInt32, _ count: Int = 4) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * (little ? $0 : count - 1 - $0))) }
        }
        func rational(_ values: [Int32]) -> [UInt8] {
            values.flatMap { bytes(UInt32(bitPattern: $0)) + bytes(10) }
        }
        func floats(_ values: [Float]) -> [UInt8] { values.flatMap { bytes($0.bitPattern) } }
        var tags: [(UInt32, UInt32, UInt32, [UInt8])] = [(50721, 10, 9, rational([10, -2, 2, 1, 8, 1, 0, 2, 8]))]
        if !minimal {
            let a = rational([10, -2, 2, 1, 8, 1, 0, 2, 8]), b = rational([8, 0, 2, 2, 8, 0, 1, 1, 8])
            let entries: [Float] = (0..<8).flatMap { i -> [Float] in
                let f = Float(i)
                return [f, 1 + f / 10, 1 + f / 20]
            }
            tags += [(50722, 10, 9, b), (50964, 10, 9, b), (50965, 10, 9, a),
                     (50778, 3, 1, bytes(17, 2)), (50779, 3, 1, bytes(21, 2)),
                     (50940, 11, 6, floats([0, 0, 0.5, 0.25, 1, 1])),
                     (50708, 2, 14, Array("FUJIFILM X-T5\0".utf8)),
                     (50936, 2, 8, Array("Provia\0\0".utf8)),
                     (50937, 4, 3, bytes(2) + bytes(2) + bytes(2)), (50938, 11, 24, floats(entries)),
                     (50981, 4, 3, bytes(2) + bytes(2) + bytes(2)), (50982, 11, 24, floats(entries)),
                     (65000, 99, 0, [0, 0, 0, 0])]
        }
        tags.sort { $0.0 < $1.0 }
        var header: [UInt8] = little ? [0x49, 0x49] : [0x4d, 0x4d]
        header += bytes(minimal ? 42 : 0x4352, 2) + bytes(8) + bytes(UInt32(tags.count), 2)
        var payload = [UInt8]()
        let start = 8 + 2 + tags.count * 12 + 4
        for (tag, type, count, value) in tags {
            header += bytes(tag, 2) + bytes(type, 2) + bytes(count)
            if value.count <= 4 { header += value + Array(repeating: 0, count: 4 - value.count) }
            else { header += bytes(UInt32(start + payload.count)); payload += value }
        }
        return Data(header + bytes(0) + payload)
    }
}
