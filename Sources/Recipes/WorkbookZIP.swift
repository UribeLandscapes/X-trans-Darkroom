import Foundation
import zlib

public enum RecipeStoreError: Error {
    case invalidZIP, unsupportedZIP, invalidXML, missingSheet, invalidHeaders, invalidRecipe, unsafeFilename
}

/// ZIP32 only. Untouched local records (including compressed bytes, extras and descriptors)
/// are copied verbatim; their central records change only in the required offset field.
struct WorkbookZIP {
    struct Entry {
        let name: String
        let offset: Int
        let method: Int
        let compressedSize: Int
        let size: Int
        let crc: UInt32
        let central: Data
    }
    let data: Data
    let entries: [Entry]
    let centralOffset: Int
    let comment: Data
    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw RecipeStoreError.invalidZIP }
        let end = stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1).first {
            data.uint($0, 4) == 0x06054b50 && $0 + 22 + data.uint($0 + 20, 2) == data.count
        }
        guard let end, data.uint(end + 4, 2) == 0, data.uint(end + 6, 2) == 0,
              data.uint(end + 8, 2) == data.uint(end + 10, 2) else { throw RecipeStoreError.unsupportedZIP }
        let count = data.uint(end + 10, 2), start = data.uint(end + 16, 4)
        guard count < 65535, start <= end, start + data.uint(end + 12, 4) == end else { throw RecipeStoreError.unsupportedZIP }
        centralOffset = start; comment = data.subdata(in: end + 22..<data.count)
        var records: [Entry] = []; var cursor = start
        for _ in 0..<count {
            guard cursor + 46 <= end, data.uint(cursor, 4) == 0x02014b50 else { throw RecipeStoreError.invalidZIP }
            let nameCount = data.uint(cursor + 28, 2)
            let length = 46 + nameCount + data.uint(cursor + 30, 2) + data.uint(cursor + 32, 2)
            guard cursor + length <= end, data.uint(cursor + 34, 2) == 0,
                  data.uint(cursor + 8, 2) & 1 == 0 else { throw RecipeStoreError.unsupportedZIP }
            guard let name = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameCount), encoding: .utf8),
                  !records.contains(where: { $0.name == name }) else { throw RecipeStoreError.invalidZIP }
            let offset = data.uint(cursor + 42, 4)
            guard offset + 30 <= start, data.uint(offset, 4) == 0x04034b50 else { throw RecipeStoreError.invalidZIP }
            records.append(Entry(name: name, offset: offset, method: data.uint(cursor + 10, 2),
                compressedSize: data.uint(cursor + 20, 4), size: data.uint(cursor + 24, 4),
                crc: UInt32(data.uint(cursor + 16, 4)), central: data.subdata(in: cursor..<cursor + length)))
            cursor += length
        }
        guard cursor == end, Set(records.map(\.offset)).count == records.count else { throw RecipeStoreError.invalidZIP }
        entries = records
    }
    func contents(_ name: String) throws -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        let start = e.offset + 30 + data.uint(e.offset + 26, 2) + data.uint(e.offset + 28, 2)
        let boundary = entries.map(\.offset).filter { $0 > e.offset }.min() ?? centralOffset
        guard e.size <= 64 * 1024 * 1024, start <= boundary, e.compressedSize <= boundary - start else { throw RecipeStoreError.invalidZIP }
        let compressed = data.subdata(in: start..<start + e.compressedSize)
        let output: Data
        switch e.method {
        case 0: output = compressed
        case 8:
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw RecipeStoreError.invalidZIP }
            defer { inflateEnd(&stream) }
            var buffer = Data(count: max(e.size, 1))
            let status = compressed.withUnsafeBytes { input in
                buffer.withUnsafeMutableBytes { out in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(out.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == e.size, stream.total_in == compressed.count else { throw RecipeStoreError.invalidZIP }
            output = buffer.prefix(e.size)
        default: throw RecipeStoreError.unsupportedZIP
        }
        guard output.count == e.size, output.checksum == e.crc else { throw RecipeStoreError.invalidZIP }
        return output
    }
    func replacing(_ replacements: [String: Data]) throws -> Data {
        guard replacements.keys.allSatisfy({ key in entries.contains { $0.name == key } }) else { throw RecipeStoreError.invalidZIP }
        var output = data.prefix(entries.map(\.offset).min() ?? centralOffset)
        var directories: [String: Data] = [:]
        let ordered = entries.sorted { $0.offset < $1.offset }
        for (index, e) in ordered.enumerated() {
            let newOffset = output.count
            var central = e.central
            if let value = replacements[e.name] {
                // Retain the original filename, timestamps and extra fields; use stored bytes
                // for the two small XML parts so no compressor can alter unrelated entries.
                let headerEnd = e.offset + 30 + data.uint(e.offset + 26, 2) + data.uint(e.offset + 28, 2)
                guard headerEnd <= centralOffset else { throw RecipeStoreError.invalidZIP }
                var local = data.subdata(in: e.offset..<headerEnd)
                local.put(local.uint(6, 2) & ~8, at: 6, count: 2); local.put(0, at: 8, count: 2)
                central.put(central.uint(8, 2) & ~8, at: 8, count: 2); central.put(0, at: 10, count: 2)
                for (l, c, v) in [(14, 16, Int(value.checksum)), (18, 20, value.count), (22, 24, value.count)] {
                    local.put(v, at: l); central.put(v, at: c)
                }
                output.append(local); output.append(value)
            } else {
                let end = index + 1 < ordered.count ? ordered[index + 1].offset : centralOffset
                output.append(data.subdata(in: e.offset..<end))
            }
            central.put(newOffset, at: 42); directories[e.name] = central
        }
        let start = output.count
        for entry in entries { output.append(directories[entry.name]!) }
        let size = output.count - start
        var end = Data(count: 22)
        end.put(0x06054b50, at: 0); end.put(entries.count, at: 8, count: 2); end.put(entries.count, at: 10, count: 2)
        end.put(size, at: 12); end.put(start, at: 16); end.put(comment.count, at: 20, count: 2)
        output.append(end); output.append(comment)
        return output
    }
}
private extension Data {
    func uint(_ offset: Int, _ count: Int) -> Int {
        guard offset >= 0, offset + count <= self.count else { return -1 }
        return (0..<count).reduce(0) { $0 | Int(self[offset + $1]) << (8 * $1) }
    }
    mutating func put(_ value: Int, at offset: Int, count: Int = 4) {
        for i in 0..<count { self[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    var checksum: UInt32 { withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(count))) } }
}
