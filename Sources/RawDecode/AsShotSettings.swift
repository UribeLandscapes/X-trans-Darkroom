import Foundation

/// Camera vocabulary, independent of the renderer. Missing/unknown tags stay absent rather
/// than being presented as measured zeroes. Offsets are walked, never signature-searched.
public struct AsShotSettings: Sendable, Equatable {
    public private(set) var values: [String: String] = [:]
    public private(set) var lensModulationOptimizer: Bool?
    public private(set) var rawExposureBias: Double?

    public static func read(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> Self? {
        let raf = Bytes(data: Data(data), little: false)
        guard data.count >= 108, data.prefix(15) == Data("FUJIFILMCCD-RAW".utf8),
              let offset = raf.uint(84, 4), let length = raf.uint(88, 4),
              let jpeg = raf.slice(offset, length), var result = embeddedJPEG(jpeg) else { return nil }
        // Exposure bias belongs to the RAF metadata directory, not the JPEG MakerNote.
        if let start = raf.uint(92, 4), let length = raf.uint(96, 4),
           let block = raf.slice(start, length) {
            let b = Bytes(data: block, little: false)
            if let count = b.uint(0, 4), count < 4096 {
                var p = 4
                for _ in 0..<count {
                    guard let tag = b.uint(p, 2), let size = b.uint(p + 2, 2), b.slice(p + 4, size) != nil else { break }
                    if tag == 0x9650, size == 4, let n = b.uint(p + 4, 2), let d = b.uint(p + 6, 2), d != 0 {
                        result.rawExposureBias = Double(Int16(bitPattern: UInt16(n))) / Double(Int16(bitPattern: UInt16(d)))
                    }
                    p += 4 + size
                }
            }
        }
        return result
    }

    private static func embeddedJPEG(_ data: Data) -> Self? {
        let b = Bytes(data: data, little: false)
        guard b.uint(0, 2) == 0xffd8 else { return nil }
        var p = 2
        while p + 4 <= data.count {
            guard b.uint(p, 1) == 255 else { return nil }
            if b.uint(p + 1, 1) == 255 { p += 1; continue }
            guard let marker = b.uint(p + 1, 1), marker != 0xda, marker != 0xd9,
                  let size = b.uint(p + 2, 2), size >= 2,
                  let segment = b.slice(p + 4, size - 2) else { return nil }
            if marker == 0xe1, segment.prefix(6) == Data([69,120,105,102,0,0]),
               let result = exif(Data(segment.dropFirst(6))) { return result }
            p += 2 + size
        }
        return nil
    }

    private static func exif(_ data: Data) -> Self? {
        guard data.count >= 8 else { return nil }
        let order = Array(data.prefix(2))
        guard order == [73,73] || order == [77,77] else { return nil }
        let b = Bytes(data: data, little: order == [73,73])
        guard b.uint(2, 2) == 42, let first = b.uint(4, 4), let ifd = b.ifd(first),
              let pointer = ifd[0x8769]?.numbers.first,
              let exif = b.ifd(Int(pointer)), let note = exif[0x927c] else { return nil }
        // The EXIF Make can also say FUJIFILM. Only tag 0x927C identifies a MakerNote.
        return makerNote(note.data)
    }

    public static func makerNote(_ data: Data) -> Self? {
        guard data.prefix(8) == Data("FUJIFILM".utf8) else { return nil }
        let b = Bytes(data: data, little: true)
        guard let offset = b.uint(8, 4), offset >= 12, let tags = b.ifd(offset) else { return nil }
        var result = Self()
        func n(_ tag: Int) -> Double? { tags[tag]?.numbers.first }
        func put(_ key: String, _ value: Double?) { if let value { result.values[key] = String(value) } }
        func choice(_ key: String, _ tag: Int, _ options: [Int: String]) {
            if let value = n(tag), let text = options[Int(value)] { result.values[key] = text }
        }
        choice("film_simulation", 0x1401, [0:"Provia/Standard",0x120:"Astia",0x200:"Velvia",0x400:"Velvia",0x500:"PRO Neg. Std",0x501:"PRO Neg. Hi",0x600:"Classic Chrome",0x700:"Eterna",0x800:"Classic Neg",0x900:"Eterna Bleach Bypass",0xa00:"Nostalgic Neg",0xb00:"Reala ACE"])
        choice("film_simulation", 0x1003, [0x300:"Monochrome",0x301:"Monochrome +R",0x302:"Monochrome +Ye",0x303:"Monochrome +G",0x310:"Sepia",0x500:"Acros",0x501:"Acros +R",0x502:"Acros +Ye",0x503:"Acros +G"])
        choice("color", 0x1003, [0:"0",0x80:"1",0x100:"2",0xc0:"3",0xe0:"4",0x180:"-1",0x200:"-2",0x400:"-2",0x4c0:"-3",0x4e0:"-4"])
        choice("sharpness", 0x1001, [0:"-4",1:"-3",2:"-2",3:"0",4:"2",5:"3",6:"4",0x82:"-1",0x84:"1"])
        choice("noise_reduction", 0x100e, [0:"0",0x100:"2",0x180:"1",0x1c0:"3",0x1e0:"4",0x200:"-2",0x280:"-1",0x2c0:"-3",0x2e0:"-4"])
        choice("wb_mode", 0x1002, [0:"Auto",1:"Auto (white priority)",2:"Auto (ambiance priority)",0x100:"Daylight",0x200:"Cloudy",0x300:"Daylight Fluorescent",0x301:"Day White Fluorescent",0x302:"White Fluorescent",0x400:"Incandescent",0x500:"Flash",0x600:"Underwater",0xf00:"Custom",0xf01:"Custom2",0xf02:"Custom3",0xff0:"Kelvin"])
        put("wb_kelvin", n(0x1005))
        if let shifts = tags[0x100a]?.numbers, shifts.count == 2 {
            put("wb_shift_r", shifts[0] / 20); put("wb_shift_b", shifts[1] / 20)
        }
        put("highlight_tone", n(0x1041).map { -$0 / 16 })
        put("shadow_tone", n(0x1040).map { -$0 / 16 })
        put("clarity", n(0x100f).map { $0 / 1000 })
        // These two tags are signed bytes even when the TIFF entry says UNDEFINED.
        for (tag, key) in [(0x1049,"monochromatic_color_wc"),(0x104b,"monochromatic_color_mg")] {
            if let byte = tags[tag]?.data.first { put(key, Double(Int8(bitPattern: byte))) }
        }
        for (tag, key) in [(0x1047,"grain_effect"),(0x1048,"color_chrome_effect"),(0x104e,"color_chrome_fx_blue")] {
            choice(key, tag, [0:"Off",32:"Weak",64:"Strong"])
        }
        choice("grain_size", 0x104c, [16:"Small",32:"Large"])
        if let lmo = n(0x1045), lmo == 0 || lmo == 1 { result.lensModulationOptimizer = lmo == 1 }
        if n(0x1402) == 0 { result.values["dynamic_range"] = "Auto" }
        else if let dr = n(0x1403), [100,200,400].contains(dr) { result.values["dynamic_range"] = String(Int(dr)) }
        else { choice("dynamic_range", 0x1402, [0x100:"100",0x201:"400"]) }
        if result.values["dynamic_range"] == nil, n(0x1400) == 1 { result.values["dynamic_range"] = "100" }
        choice("d_range_priority", 0x1445, [1:"Weak",2:"Strong"])
        if n(0x1443) == 0 { result.values["d_range_priority"] = "Auto" }
        return result
    }

    private struct Entry { let data: Data; let numbers: [Double] }
    private struct Bytes {
        let data: Data
        let little: Bool
        func uint(_ p: Int, _ size: Int) -> Int? {
            guard p >= 0, size > 0, p <= data.count, size <= data.count - p else { return nil }
            var result = 0
            for i in 0..<size { result |= Int(data[p+i]) << (8 * (little ? i : size-1-i)) }
            return result
        }
        func slice(_ p: Int, _ size: Int) -> Data? {
            guard p >= 0, size >= 0, p <= data.count, size <= data.count-p else { return nil }
            return Data(data[p..<p+size])
        }
        func ifd(_ p: Int) -> [Int: Entry]? {
            guard let count = uint(p, 2), count <= 4096, slice(p+2, count*12) != nil else { return nil }
            var entries: [Int: Entry] = [:]
            for i in 0..<count {
                let e = p+2+i*12
                guard let tag = uint(e,2), let type = uint(e+2,2), let n = uint(e+4,4), n > 0,
                      let size = [1:1,2:1,3:2,4:4,5:8,6:1,7:1,8:2,9:4,10:8][type], n <= data.count / size,
                      let offset = n*size <= 4 ? e+8 : uint(e+8,4), let value = slice(offset,n*size) else { continue }
                let v = Bytes(data: value, little: little)
                var numbers: [Double] = []
                if [1,3,4,6,8,9].contains(type) {
                    for k in 0..<n {
                        guard let raw = v.uint(k*size,size) else { break }
                        let signed = type == 6 ? Int(Int8(bitPattern: UInt8(raw))) : type == 8 ? Int(Int16(bitPattern: UInt16(raw))) : type == 9 ? Int(Int32(bitPattern: UInt32(raw))) : raw
                        numbers.append(Double(signed))
                    }
                }
                entries[tag] = Entry(data: value, numbers: numbers)
            }
            return entries
        }
    }
}
