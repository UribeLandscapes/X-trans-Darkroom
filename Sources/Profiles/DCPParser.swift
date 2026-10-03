import Foundation
import EditModel
import CryptoKit

public enum DCPParser {
    public static func read(from url: URL) -> CameraProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> CameraProfile? {
        let d = Data(data)
        guard d.count >= 8 else { return nil }
        let little: Bool
        if d[0] == 0x49 && d[1] == 0x49 { little = true }
        else if d[0] == 0x4d && d[1] == 0x4d { little = false }
        else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(uint(d, at: i, bytes: 2, little: little)) }
        func u32(_ i: Int) -> UInt32 { UInt32(uint(d, at: i, bytes: 4, little: little)) }
        // Standalone Adobe camera profiles use CR magic; synthetic/embedded TIFF uses 42.
        guard u16(2) == 0x4352 || u16(2) == 42 else { return nil }
        let supported: Set<UInt16> = [50708, 50721, 50722, 50778, 50779, 50932, 50936,
                                     50937, 50938, 50939, 50940, 50964, 50965, 50981, 50982, 51107, 51108]
        var fields: [UInt16: (UInt16, Int, Int)] = [:]
        var offset = Int(u32(4)); var visited = Set<Int>()
        while offset != 0 {
            guard offset >= 8, offset <= d.count - 2, visited.insert(offset).inserted else { return nil }
            let count = Int(u16(offset))
            guard count <= (d.count - offset - 2) / 12 else { return nil }
            let end = offset + 2 + count * 12
            guard end <= d.count - 4 else { return nil }
            for i in 0..<count {
                let entry = offset + 2 + i * 12
                let tag = u16(entry)
                guard supported.contains(tag) else { continue }
                let type = u16(entry + 2), n = Int(u32(entry + 4))
                let size: Int
                switch type {
                case 1, 2: size = 1
                case 3: size = 2
                case 4, 11: size = 4
                case 5, 10, 12: size = 8
                default: return nil
                }
                guard n > 0, n <= d.count / size else { return nil }
                let at = n * size <= 4 ? entry + 8 : Int(u32(entry + 8))
                guard at <= d.count, n * size <= d.count - at, fields[tag] == nil else { return nil }
                fields[tag] = (type, n, at)
            }
            offset = Int(u32(end))
        }
        func numbers(_ tag: UInt16, type expected: UInt16) -> [Double]? {
            guard let (type, n, at) = fields[tag], type == expected else { return nil }
            var values = [Double]()
            for i in 0..<n {
                let value: Double
                switch type {
                case 3: value = Double(u16(at + i * 2))
                case 4: value = Double(u32(at + i * 4))
                case 11: value = Double(Float(bitPattern: u32(at + i * 4)))
                case 10:
                    let denominator = Int32(bitPattern: u32(at + i * 8 + 4))
                    guard denominator != 0 else { return nil }
                    value = Double(Int32(bitPattern: u32(at + i * 8))) / Double(denominator)
                default: return nil
                }
                guard value.isFinite else { return nil }
                values.append(value)
            }
            return values
        }
        func string(_ tag: UInt16) -> String? {
            guard let (type, n, at) = fields[tag], (type == 2 || type == 1) else { return nil }
            return String(data: d.subdata(in: at..<(at + n)).prefix { $0 != 0 }, encoding: .utf8)
        }
        let digest = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        var profile = CameraProfile(identifier: "dcp-" + digest,
                                    displayName: string(50936) ?? "Unnamed camera profile",
                                    cameraModel: string(50708))
        profile.profileCalibrationSignature = string(50932)
        for (tag, key) in [(UInt16(50721), \CameraProfile.colorMatrix1), (50722, \.colorMatrix2),
                           (50964, \.forwardMatrix1), (50965, \.forwardMatrix2)] {
            if fields[tag] != nil {
                guard let values = numbers(tag, type: 10), let matrix = ProfileMatrix(values) else { return nil }
                profile[keyPath: key] = matrix
            }
        }
        guard profile.colorMatrix1 != nil else { return nil }
        for (tag, key) in [(UInt16(50778), \CameraProfile.calibrationIlluminant1), (50779, \.calibrationIlluminant2)] {
            if fields[tag] != nil {
                guard let values = numbers(tag, type: 3), values.count == 1 else { return nil }
                profile[keyPath: key] = UInt16(values[0])
            }
        }
        if fields[50940] != nil {
            guard let values = numbers(50940, type: 11), values.count >= 4, values.count % 2 == 0 else { return nil }
            let points = stride(from: 0, to: values.count, by: 2).map { ToneCurve.Point(x: values[$0], y: values[$0 + 1]) }
            guard zip(points, points.dropFirst()).allSatisfy({ $0.x < $1.x }) else { return nil }
            profile.profileToneCurve = ToneCurve(points: points)
        }
        for (dimsTag, dataTag, key) in [(UInt16(50937), UInt16(50938), \CameraProfile.profileHueSatMap1),
                                      (50937, 50939, \.profileHueSatMap2), (50981, 50982, \.profileLookTable)] {
            if fields[dataTag] != nil {
                guard let dims = numbers(dimsTag, type: 4), dims.count == 3,
                      let values = numbers(dataTag, type: 11), values.count % 3 == 0,
                      let grid = ProfileGrid(hueDivisions: Int(dims[0]), saturationDivisions: Int(dims[1]),
                                             valueDivisions: Int(dims[2]), entries: stride(from: 0, to: values.count, by: 3).map {
                          SIMD3(values[$0], values[$0 + 1], values[$0 + 2])
                      }) else { return nil }
                profile[keyPath: key] = grid
            }
        }
        for (tag, key) in [(UInt16(51107), \CameraProfile.hueSatMapEncoding), (51108, \.lookTableEncoding)] {
            if fields[tag] != nil {
                guard let values = numbers(tag, type: 4), values.count == 1 else { return nil }
                profile[keyPath: key] = UInt32(values[0])
            }
        }
        return profile
    }

    // Byte-wise reads avoid alignment assumptions and support either TIFF byte order.
    private static func uint(_ d: Data, at i: Int, bytes: Int, little: Bool) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<bytes {
            value |= UInt64(d[d.startIndex + i + k]) << (8 * (little ? k : bytes - 1 - k))
        }
        return value
    }
}
