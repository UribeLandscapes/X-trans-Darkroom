import Foundation

public struct RecipeImportResult: Sendable {
    public var recipes: [Recipe] = []
    public var rowsRead = 0
    public var blankRows = 0
    public var warnings: [RecipeWarning] { recipes.flatMap(\.warnings) }
    public func summary(rowsWritten: Int) -> String {
        var lines = ["Rows read: \(rowsRead); blank rows skipped: \(blankRows); rows written: \(rowsWritten)"]
        for (column, warnings) in Dictionary(grouping: warnings, by: \.field).sorted(by: { $0.key < $1.key }) {
            lines.append("\(column): \(warnings.count) warning(s)")
            lines += warnings.map { "  \($0.message)" }
        }
        return lines.joined(separator: "\n")
    }
}

public enum RecipeImporter {
    /// The source is only ever read. Reject aliases to the destination before any write.
    public static func read(source: URL, destination: URL) throws -> RecipeImportResult {
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw RecipeStoreError.invalidRecipe
        }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let a = try source.resourceValues(forKeys: keys).fileResourceIdentifier
        let b = try destination.resourceValues(forKeys: keys).fileResourceIdentifier
        if let a = a as? NSObject, let b = b as? NSObject, a == b { throw RecipeStoreError.invalidRecipe }
        return try read(Data(contentsOf: source))
    }
    public static func read(_ data: Data) throws -> RecipeImportResult {
        let zip = try WorkbookZIP(data), shared = SheetXML()
        if let strings = try zip.contents(RecipeWorkbook.stringsPath) { try shared.read(strings) }
        guard let book = try zip.contents("xl/workbook.xml"), let rels = try zip.contents("xl/_rels/workbook.xml.rels") else { throw RecipeStoreError.missingSheet }
        let workbook = try XMLDocument(data: book), relationships = try XMLDocument(data: rels)
        var paths: [String: String] = [:]
        for node in try relationships.nodes(forXPath: "//*[local-name()='Relationship']") {
            guard let e = node as? XMLElement, let id = e.attribute(forName: "Id")?.stringValue, let target = e.attribute(forName: "Target")?.stringValue else { continue }
            paths[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        }
        var result = RecipeImportResult(), ids = Set<String>()
        let sheets = try workbook.nodes(forXPath: "//*[local-name()='sheet']")
        var found = Set<String>()
        for node in sheets {
            guard let e = node as? XMLElement, let name = e.attribute(forName: "name")?.stringValue else { continue }
            guard let id = e.attributes?.first(where: { $0.localName == "id" })?.stringValue,
                  let path = paths[id], let data = try zip.contents(path) else { throw RecipeStoreError.missingSheet }
            found.insert(name)
            let reader = SheetXML(); reader.sharedStrings = shared.strings; try reader.read(data)
            let headers = reader.rows[1] ?? [:]
            guard headers.values.contains("Name") else { throw RecipeStoreError.invalidHeaders }
            for row in reader.rows.keys.sorted() where row > 1 {
                result.rowsRead += 1
                let cells = reader.rows[row]!
                if cells.values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { result.blankRows += 1; continue }
                var values: [String: String] = [:]
                for column in cells.keys.sorted() {
                    let header = headers[column] ?? ""
                    let key = header.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    guard values[key.isEmpty ? "Unnamed column \(column)" : key] == nil else { throw RecipeStoreError.invalidHeaders }
                    values[key.isEmpty ? "Unnamed column \(column)" : key] = cells[column]
                }
                var recipe = convert(values, sheet: name, row: row)
                if !ids.insert(recipe.id).inserted { throw RecipeStoreError.invalidRecipe }
                for warning in reader.warnings where warning.row == row {
                    recipe.warnings.append(.init(row: row, field: headers[warning.field] ?? warning.field, message: "\(name) row \(row): \(warning.message)"))
                }
                result.recipes.append(recipe)
            }
        }
        guard found.count == 2 else { throw RecipeStoreError.missingSheet }
        return result
    }

    public static func convert(_ cells: [String: String], sheet: String, row: Int) -> Recipe {
        var recipe = Recipe(fields: Dictionary(uniqueKeysWithValues: RecipeField.allCases.map { ($0, "") }), row: row)
        recipe[.sourceSheet] = sheet
        var notes: [String: String] = [:]
        func warn(_ column: String, _ raw: String, _ reason: String) {
            notes[column] = raw
            recipe.warnings.append(.init(row: row, field: column, message: "\(sheet) row \(row) [\(cells["Name"] ?? "")]: \(reason); original=\(raw)"))
        }
        for (column, raw) in cells.sorted(by: { $0.key < $1.key }) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let direct: [String: RecipeField] = ["Name": .name, "Used?": .used, "Like?": .liked, "Notes": .notes]
            if let field = direct[column] { recipe[field] = raw; continue }
            guard let fields = parse(column, value) else {
                let reason = column == "Exp Comp" && Double(value).map({ abs($0) > 5 }) == true
                    ? "Implausible exposure compensation outside -5...+5 EV; possible mis-aligned source column"
                    : "Ambiguous, annotated, unsupported or out-of-range value; typed fields left empty"
                warn(column, raw, reason); continue
            }
            for (field, value) in fields { recipe[field] = value }
        }
        let slug = recipe.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        recipe[.recipeID] = slug.isEmpty ? "\(sheet.lowercased())-row-\(row)" : slug
        if recipe.name.isEmpty { warn("Name", cells["Name"] ?? "", "Missing name; ID uses source sheet and row") }
        if (cells["Film Simulation"] ?? "").isEmpty { warn("Film Simulation", "", "Missing simulation; incomplete source row (possibly a setting fragment)") }
        let data = try! JSONSerialization.data(withJSONObject: notes, options: [.sortedKeys, .withoutEscapingSlashes])
        recipe[.importNotes] = notes.isEmpty ? "" : String(decoding: data, as: UTF8.self)
        return recipe
    }
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: "^(?:" + pattern + ")$", options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func parse(_ column: String, _ text: String) -> [RecipeField: String]? {
        let n = "([+-]?[0-9]+(?:\\.[0-9]+)?)"
        func numbers(_ values: [(RecipeField, String, ClosedRange<Double>, Double)]) -> [RecipeField: String]? {
            var result: [RecipeField: String] = [:]
            for (field, raw, range, step) in values {
                guard match(n, raw) != nil, let x = Double(raw), x.isFinite, range.contains(x), abs(x / step - (x / step).rounded()) < 1e-8 else { return nil }
                result[field] = x == x.rounded() ? String(Int(x)) : String(x)
            }
            return result
        }
        switch column {
        case "Film Simulation":
            let aliases = ["classicnegative": "Classic Neg", "eternacinema": "Eterna", "acros+yellowfilter": "Acros +Ye", "acros+redfilter": "Acros +R", "acros+greenfilter": "Acros +G", "realaace": "Reala ACE"]
            let key = Recipe.normalized(text)
            if let value = aliases[key] { return [.filmSimulation: value] }
            return Recipe.filmSimulations.first { Recipe.simulationKey($0) == Recipe.simulationKey(text) }.map { [.filmSimulation: $0] }
        case "Grain":
            if ["off", "no"].contains(text.lowercased()) { return [.grainEffect: "Off"] }
            guard let m = match("(Weak|Strong),\\s*(Small|Large)", text) else { return nil }
            return [.grainEffect: m[0].capitalized, .grainSize: m[1].capitalized]
        case "WB":
            let m = match("(.+?),\\s*R:\\s*" + n + ",\\s*B:\\s*" + n, text)
                ?? match("(.+?),\\s*" + n + " Red\\s*(?:&|,)\\s*" + n + " Blue", text)
            guard let m, var fields = numbers([(.wbShiftR, m[1], -9...9, 1), (.wbShiftB, m[2], -9...9, 1)]) else { return nil }
            if let k = match("([0-9]+)K", m[0]), let temperature = numbers([(.wbKelvin, k[0], 2500...10000, 1)]) {
                fields.merge(temperature) { _, b in b }; fields[.wbMode] = "Kelvin"
            } else {
                let modes = ["Auto", "Auto Ambience Priority", "Auto White Priority", "Daylight", "Shade", "Fluorescent 1", "Fluorescent 2", "Fluorescent 3", "Incandescent", "Underwater"]
                guard let mode = modes.first(where: { $0.lowercased() == m[0].lowercased() }) else { return nil }
                fields[.wbMode] = mode
            }
            return fields
        case "Tone Curve":
            guard let m = match("H:\\s*" + n + ",\\s*S:\\s*" + n, text) else { return nil }
            return numbers([(.highlightTone, m[0], -2...4, 0.5), (.shadowTone, m[1], -2...4, 0.5)])
        case "Monochromatic Color":
            guard let m = match("WC:\\s*" + n + ",\\s*MG:\\s*" + n, text) else { return nil }
            return numbers([(.monochromaticColorWC, m[0], -18...18, 1), (.monochromaticColorMG, m[1], -18...18, 1)])
        case "DR": return ["DR100", "DR200", "DR400", "Auto"].first { $0.lowercased() == text.lowercased() }.map { [.dynamicRange: $0] }
        case "Exp Comp":
            var value: Double?
            if match(n, text) != nil { value = Double(text) }
            else if let m = match("([+-]?[0-9]+)/([0-9]+)", text), let a = Double(m[0]), let b = Double(m[1]), b != 0 { value = a / b }
            guard let value, value.isFinite, abs(value) <= 5 else { return nil }
            return [.exposureComp: String(value)]
        case "Color Chrome Effect", "Color Chrome FX Blue":
            guard let value = ["Off", "Weak", "Strong"].first(where: { $0.lowercased() == text.lowercased() }) else { return nil }
            return [column == "Color Chrome Effect" ? .colorChromeEffect : .colorChromeFXBlue: value]
        default:
            let numeric: [String: RecipeField] = ["Color": .color, "Sharpness": .sharpness, "NR": .noiseReduction, "Clarity": .clarity]
            guard let field = numeric[column], let constraint = Recipe.numericConstraints.first(where: { $0.0 == field }) else { return nil }
            return numbers([(field, text, constraint.1, constraint.2)])
        }
    }
}
