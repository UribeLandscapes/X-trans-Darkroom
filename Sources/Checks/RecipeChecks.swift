import Foundation
import CoreImage
import zlib
import Recipes
import Profiles
import EditModel
import ImageCanvas
import ImagingCore

enum RecipeChecks {
    @MainActor
    static func run(_ c: Checks) async {
        await c.suite("Recipe system (Build plan section 5)") { c in
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("recipes.xlsx")
            var fields: [RecipeField: String] = [
                .recipeID: "summer", .name: "Summer & café", .filmSimulation: "Provia/Standard", .wbMode: "Auto",
                .wbKelvin: "5600", .wbShiftR: "2", .wbShiftB: "-1", .dynamicRange: "DR200", .dRangePriority: "off",
                .highlightTone: "1.5", .shadowTone: "-0.5", .color: "2", .sharpness: "1", .noiseReduction: "-2",
                .clarity: "3", .colorChromeEffect: "weak", .colorChromeFXBlue: "strong", .grainEffect: "weak",
                .grainSize: "large", .exposureComp: "0.5", .isoRange: "125–6400", .example1: "one.jpg",
                .example2: "two.jpg", .example3: "three.jpg", .exampleExtra: "extra.jpg", .tags: "summer,travel",
                .notes: "  Keep <this> & that\nsecond line  ", .source: "Personal", .created: "2026-09-01",
                .modified: "2026-09-07", .revision: "2"]
            for field in RecipeField.allCases where fields[field] == nil { fields[field] = "" }
            let examples = dir.appendingPathComponent("examples")
            try FileManager.default.createDirectory(at: examples, withIntermediateDirectories: true)
            for name in ["one.jpg", "two.jpg", "three.jpg", "extra.jpg"] { try Data([1]).write(to: examples.appendingPathComponent(name)) }
            let fixture = try workbook(fields: fields)
            try fixture.data.write(to: url)
            let store = LocalRecipeStore(spreadsheet: url)
            let loaded = try await store.loadAll()
            c.expect(loaded.count == 1 && loaded[0].fields == fields, "DEFLATE/shared/rich/inline/numeric-text fields parsed=\(loaded.first?.fields.count ?? 0)/\(fields.count), rows=\(loaded.count)/1")
            c.expect(loaded[0].warnings.isEmpty, "valid X-T5 row warnings=\(loaded[0].warnings.count)/0")
            let photo = try await store.resolveExamplePhoto("one.jpg")
            c.expect(photo == examples.appendingPathComponent("one.jpg"), "portable example resolved=\(photo?.lastPathComponent ?? "nil")/one.jpg")
            let missing = try await store.resolveExamplePhoto("missing.jpg")
            c.expect(missing == nil, "missing example returns nil=\(missing == nil)")
            do { _ = try await store.resolveExamplePhoto("../escape.jpg"); c.fail("traversal accepted") }
            catch { c.expect(true, "example traversal rejected=1/1") }

            let reorderedURL = dir.appendingPathComponent("reordered.xlsx")
            try workbook(fields: fields, reordered: true).data.write(to: reorderedURL)
            let reordered = try await LocalRecipeStore(spreadsheet: reorderedURL).loadAll()
            c.expect(reordered.first?.fields == loaded.first?.fields, "reordered columns equivalent fields=\(reordered.first?.fields.count ?? 0)/\(fields.count)")
            var malformed = fields
            malformed[.recipeID] = "broken"; malformed[.highlightTone] = "9.0"; malformed[.noiseReduction] = "oops"
            malformed[.example1] = "missing.jpg"; malformed[.grainEffect] = "enormous"
            let badURL = dir.appendingPathComponent("bad.xlsx")
            try workbook(fields: fields, second: malformed).data.write(to: badURL)
            let bad = try await LocalRecipeStore(spreadsheet: badURL).loadAll()
            let warned = bad.first { $0.id == "broken" }!
            c.expect(bad.count == 2 && bad[0].warnings.isEmpty && warned.warnings.count == 4,
                     "malformed row isolated: recipes=\(bad.count)/2, valid warnings=\(bad[0].warnings.count)/0, bad warnings=\(warned.warnings.count)/4")
            c.expect(warned.warnings.contains { $0.field == "highlight_tone" && $0.row == 4 }, "highlight=9 flagged on row 4; warnings=\(warned.warnings.map(\.field))")
            var bounds = Recipe(fields: fields)
            bounds[.highlightTone] = "0.25"; bounds[.shadowTone] = "-3"; bounds[.color] = "5"
            bounds[.sharpness] = "1.5"; bounds[.clarity] = "6"; bounds[.wbShiftR] = "10"; bounds[.wbShiftB] = "-10"
            bounds[.dynamicRange] = "DR800"; bounds[.dRangePriority] = "maximum"; bounds[.grainSize] = "huge"
            bounds[.colorChromeEffect] = "yes"; bounds[.colorChromeFXBlue] = "NaN"
            c.expect(bounds.validationWarnings().count == 12, "X-T5 range/step/enum violations=\(bounds.validationWarnings().count)/12")
            let accepted = Recipe.filmSimulations.filter { simulation in
                var r = Recipe(fields: fields); r[.filmSimulation] = simulation
                return r.validationWarnings().isEmpty
            }.count
            c.expect(accepted == 20, "film simulations including Ye/R/G accepted=\(accepted)/20")

            var changed = loaded[0]; changed[.name] = "New <name> & café"; changed[.notes] = "  preserve spaces  "
            try await store.upsert(changed)
            let savedData = try Data(contentsOf: url)
            let fresh = try await LocalRecipeStore(spreadsheet: url).loadAll()
            c.expect(fresh.first?.fields == changed.fields, "reopened saved fields match=\(fresh.first?.fields == changed.fields), count=\(fresh.first?.fields.count ?? 0)")
            c.expect(savedData.range(of: fixture.unrelatedRecord) != nil, "unrelated sheet raw ZIP record preserved=\(fixture.unrelatedRecord.count) bytes")
            let sheet = try unzip(url, "xl/worksheets/sheet1.xml")
            let doc = try XMLDocument(data: sheet)
            let xml = doc.xmlString
            c.expect(xml.contains("KEEP UNKNOWN") && xml.contains("width=\"27\"") && xml.contains("s=\"1\"") && xml.contains("hand-edited comment"),
                     "unknown cell/width/style/comment retained=\([xml.contains("KEEP UNKNOWN"), xml.contains("width=\"27\""), xml.contains("s=\"1\""), xml.contains("hand-edited comment")].filter { $0 }.count)/4")
            c.expect(xml.contains("A1:\(column(RecipeField.allCases.count))4"), "existing worksheet dimension never shrinks: retained A1:\(column(RecipeField.allCases.count))4=\(xml.contains("A1:\(column(RecipeField.allCases.count))4"))")
            let shared = try unzip(url, "xl/sharedStrings.xml")
            c.expect(shared == fixture.shared, "shared-string table preserved=\(shared.count)/\(fixture.shared.count) bytes")
            let backups = dir.appendingPathComponent("recipes-backup")
            var backupURLs = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            let previous = try Data(contentsOf: backupURLs[0])
            c.expect(backupURLs.count == 1 && previous == fixture.data, "backup count=\(backupURLs.count)/1, previous workbook exact=\(previous == fixture.data)")

            let reorderedStore = LocalRecipeStore(spreadsheet: reorderedURL)
            try await reorderedStore.upsert(changed)
            let reorderedSaved = try await LocalRecipeStore(spreadsheet: reorderedURL).loadAll()
            let reorderedXML = try unzip(reorderedURL, "xl/worksheets/sheet1.xml")
            c.expect(reorderedSaved.first?.fields == changed.fields && String(decoding: reorderedXML, as: UTF8.self).contains("KEEP UNKNOWN"),
                     "reordered write field equality=\(reorderedSaved.first?.fields == changed.fields), unknown column retained=1/1")

            enum InjectedFailure: Error { case disk }
            for stage in [LocalRecipeStore.WriteStage.staged, .validated, .backedUp] {
                let failing = LocalRecipeStore(spreadsheet: url) { current, _ in
                    if current == stage { throw InjectedFailure.disk }
                }
                var attempt = changed; attempt[.name] = "Must not commit"
                do { try await failing.upsert(attempt); c.fail("injected write did not fail at \(stage)") }
                catch InjectedFailure.disk {
                    let intact = try Data(contentsOf: url)
                    c.expect(intact == savedData, "failure at \(stage): original exact=\(intact == savedData), bytes=\(intact.count)")
                }
            }
            let corrupting = LocalRecipeStore(spreadsheet: url) { stage, staged in
                if stage == .staged { try Data("corrupt".utf8).write(to: staged) }
            }
            do { try await corrupting.upsert(changed); c.fail("corrupt staged workbook accepted") }
            catch {
                let intact = try Data(contentsOf: url)
                c.expect(intact == savedData, "reopen rejects corrupt stage; original intact=\(intact == savedData)")
            }
            var new = changed; new[.recipeID] = "winter"; new[.name] = "Winter"
            try await store.upsert(new)
            let appended = try await LocalRecipeStore(spreadsheet: url).loadAll()
            c.expect(appended.map(\.id) == ["summer", "winter"], "upsert appends distinct ID: rows=\(appended.count)/2")
            for i in 0..<22 { new[.revision] = String(i); try await store.upsert(new) }
            backupURLs = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            c.expect(backupURLs.count == 20, "backup retention after 25 saves=\(backupURLs.count)/20")
            try Data("external edit".utf8).write(to: url)
            let cached = try await store.loadAll()
            c.expect(cached.count == 2, "launch snapshot survives external change without reload; cached rows=\(cached.count)/2")
            try savedData.write(to: url)

            let profileDir = dir.appendingPathComponent("profiles")
            try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
            try profileFixture().write(to: profileDir.appendingPathComponent("provia.dcp"))
            let library = ProfileLibrary(bundledDirectory: nil, userDirectory: profileDir)
            let context = RecipeApplication.Context(asShotTemperature: 5500, asShotTint: 3)
            let applied = try RecipeApplication.apply(loaded[0], to: EditStack(), profiles: library, context: context)
            var manual = EditStack()
            manual.profileID = library.profiles[0].identifier
            manual.light.highlights = -2; manual.light.shadows = 6; manual.light.exposure = 1.5
            manual.curves.composite = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.26), .init(x: 0.75, y: 0.78), .init(x: 1, y: 1)])
            manual.color.saturation = 16; manual.color.vibrance = 8; manual.color.temperature = 5950; manual.color.tint = 5
            manual.detail.sharpenAmount = 50; manual.detail.luminanceNR = 20
            manual.effects.grainAmount = 20; manual.effects.grainSize = 50; manual.effects.clarity = 30
            for band in [HSLColor.red, .orange, .yellow] { manual.hsl[band].saturation = -6 }
            for band in [HSLColor.aqua, .blue] { manual.hsl[band].saturation = -16 }
            var untagged = applied; untagged.recipeID = ""
            c.expect(untagged == manual && applied.recipeID == "summer", "7 mapping rows: EV=\(applied.light.exposure)/1.5, highlights=\(applied.light.highlights)/−2, WB=\(applied.color.temperature)/5950; full stack match=\(untagged == manual), recipeID=\(applied.recipeID)")
            let reapplied = try RecipeApplication.apply(loaded[0], to: applied, profiles: library, context: context)
            c.expect(reapplied == applied, "reapplying preset accumulates zero changes=\(reapplied == applied)")
            var unavailable = loaded[0]; unavailable[.filmSimulation] = "Velvia"
            do { _ = try RecipeApplication.apply(unavailable, to: EditStack(), profiles: library, context: context); c.fail("missing profile silently substituted") }
            catch RecipeApplication.ApplicationError.missingProfile { c.expect(true, "missing simulation profile rejected=1/1") }
            var kelvin = loaded[0]; kelvin[.wbMode] = "Kelvin"; kelvin[.dRangePriority] = "strong"
            let k = try RecipeApplication.apply(kelvin, to: EditStack(), profiles: library, context: context)
            c.expect(k.color.temperature == 6050 && k.light.exposure == 2.5 && k.light.highlights == -22,
                     "Kelvin and DR-P override: K=\(k.color.temperature)/6050, EV=\(k.light.exposure)/2.5, highlights=\(k.light.highlights)/−22")
            let canvas = Checks.repoRoot().appendingPathComponent("Sources/ImageCanvas")
            let sources = try FileManager.default.contentsOfDirectory(at: canvas, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            let dependencies = try sources.filter { try String(contentsOf: $0, encoding: .utf8).contains("recipeID") || String(contentsOf: $0, encoding: .utf8).contains("import Recipes") }
            c.expect(dependencies.isEmpty, "renderer recipe references=\(dependencies.count)/0 across \(sources.count) files")
            let ci = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])
            let input = CIImage(color: CIColor(red: 0.3, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            let pipeline = RenderPipeline()
            func pixels(_ stack: EditStack) -> [Float] {
                let output = pipeline.render(DecodedFrameInput(image: input, asShotTemperature: 5500, profile: library.profiles[0]), stack: stack, proxyRatio: 1)
                var values = [Float](repeating: 0, count: 32 * 32 * 4)
                ci.render(output, toBitmap: &values, rowBytes: 32 * 4 * 4, bounds: output.extent, format: .RGBAf, colorSpace: WorkingColorSpace.linearWide)
                return values
            }
            let recipePixels = pixels(applied), manualPixels = pixels(manual)
            let error = zip(recipePixels, manualPixels).map { abs($0 - $1) }.max() ?? .infinity
            c.expect(error == 0 && recipePixels.contains { $0 != 0 }, "recipe/hand-set render max error=\(error), samples=\(recipePixels.count), nonzero=\(recipePixels.filter { $0 != 0 }.count)")
        }
    }

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    private static func column(_ number: Int) -> String {
        var n = number + 1, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }
    private static func workbook(fields: [RecipeField: String], reordered: Bool = false, second: [RecipeField: String]? = nil) throws -> (data: Data, unrelatedRecord: Data, shared: Data) {
        let headers = (reordered ? RecipeField.allCases.reversed().map { $0.rawValue } : RecipeField.allCases.map(\.rawValue)) + ["my extra column"]
        var shared = headers
        let header = headers.indices.map { "<c r=\"\(column($0))1\" t=\"s\"><v>\($0)</v></c>" }.joined()
        func row(_ fields: [RecipeField: String], _ number: Int) -> String {
            let cells = headers.enumerated().map { i, key -> String in
                let value = RecipeField(rawValue: key).flatMap { fields[$0] } ?? "KEEP UNKNOWN"
                let reference = column(i) + String(number)
                if key == "name" {
                    let index = shared.count; shared.append(value)
                    return "<c r=\"\(reference)\" s=\"1\" t=\"s\"><v>\(index)</v></c>"
                }
                if key == "wb_shift_r" { return "<c r=\"\(reference)\"><v>\(escape(value))</v></c>" }
                return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
            }.joined()
            return "<row r=\"\(number)\">\(cells)</row>"
        }
        let rows = row(fields, 2) + "<row r=\"3\"/>" + (second.map { row($0, 4) } ?? "")
        let sheet = "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><dimension ref=\"A1:\(column(RecipeField.allCases.count))4\"/><cols><col min=\"1\" max=\"33\" width=\"27\" customWidth=\"1\"/></cols><!--hand-edited comment--><sheetData><row r=\"1\">\(header)</row>\(rows)</sheetData></worksheet>"
        let strings = Data(("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" uniqueCount=\"\(shared.count)\">" + shared.map { "<si><r><t xml:space=\"preserve\">\(escape($0))</t></r></si>" }.joined() + "</sst>").utf8)
        let parts: [(String, Data)] = [
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
            ("xl/sharedStrings.xml", strings),
            ("xl/worksheets/sheet2.xml", Data("<worksheet><sheetData><!--irreplaceable notes--></sheetData></worksheet>".utf8)),
            ("[Content_Types].xml", Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/></Types>".utf8)),
            ("_rels/.rels", Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>".utf8)),
            ("xl/workbook.xml", Data("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Recipes\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/></Relationships>".utf8))]
        var data = Data(), central = Data(), unrelated = Data()
        for (name, content) in parts {
            let compressed = try deflate(content)
            let crc = content.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(content.count))) }
            let filename = Data(name.utf8), offset = data.count
            // Include a data descriptor, private extra field and per-entry comment.
            let extra = bytes(0xcafe, 2) + bytes(2, 2) + Data([12, 34])
            let local = [bytes(0x04034b50), bytes(20, 2), bytes(8, 2), bytes(8, 2), bytes(0), bytes(0), bytes(0), bytes(0), bytes(filename.count, 2), bytes(extra.count, 2), filename, extra, compressed, bytes(0x08074b50), bytes(crc), bytes(compressed.count), bytes(content.count)].reduce(Data(), +)
            data.append(local)
            if name == "xl/worksheets/sheet2.xml" { unrelated = local }
            central.append([bytes(0x02014b50), bytes(20, 2), bytes(20, 2), bytes(8, 2), bytes(8, 2), bytes(0), bytes(crc), bytes(compressed.count), bytes(content.count), bytes(filename.count, 2), bytes(extra.count, 2), bytes(4, 2), bytes(0, 2), bytes(0, 2), bytes(0), bytes(offset), filename, extra, Data("note".utf8)].reduce(Data(), +))
        }
        let start = data.count; data.append(central)
        data.append([bytes(0x06054b50), bytes(0), bytes(parts.count, 2), bytes(parts.count, 2), bytes(central.count), bytes(start), bytes(7, 2), Data("archive".utf8)].reduce(Data(), +))
        return (data, unrelated, strings)
    }
    private static func bytes(_ n: Int, _ count: Int = 4) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: n >> (8 * $0)) }) }
    private static func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw RecipeStoreError.invalidZIP }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(compressBound(uLong(data.count))))
        let status = data.withUnsafeBytes { input in output.withUnsafeMutableBytes { buffer in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(data.count)
            stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(buffer.count)
            return zlib.deflate(&stream, Z_FINISH)
        } }
        guard status == Z_STREAM_END else { throw RecipeStoreError.invalidZIP }
        return output.prefix(Int(stream.total_out))
    }
    private static func unzip(_ url: URL, _ entry: String) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-p", url.path, entry]
        process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RecipeStoreError.invalidZIP }
        return data
    }
    static func profileFixture() -> Data {
        let camera = Data("FUJIFILM X-T5\0".utf8), name = Data("Provia\0".utf8)
        let matrix = [1, 0, 0, 0, 1, 0, 0, 0, 1].reduce(Data()) { $0 + bytes($1) + bytes(1) }
        let tags = [(50708, 2, camera.count, camera), (50721, 10, 9, matrix), (50936, 2, name.count, name)]
        var data = Data([0x49, 0x49]) + bytes(42, 2) + bytes(8) + bytes(3, 2), payload = Data()
        for (tag, type, count, value) in tags {
            data.append(bytes(tag, 2) + bytes(type, 2) + bytes(count) + bytes(50 + payload.count)); payload.append(value)
        }
        return data + bytes(0) + payload
    }
}
