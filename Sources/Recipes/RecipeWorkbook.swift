import Foundation

struct RecipeWorkbook {
    static let sheetPath = "xl/worksheets/sheet1.xml"
    static let stringsPath = "xl/sharedStrings.xml"
    let zip: WorkbookZIP
    let sheet: Data
    let rows: [Int: [String: String]]
    let headers: [String: String] // column letters -> header TEXT, never positional
    let warnings: [RecipeWarning]

    init(_ data: Data) throws {
        zip = try WorkbookZIP(data)
        guard let sheet = try zip.contents(Self.sheetPath) else { throw RecipeStoreError.missingSheet }
        self.sheet = sheet
        let strings = SheetXML()
        if let data = try zip.contents(Self.stringsPath) { try strings.read(data) }
        let reader = SheetXML(); reader.sharedStrings = strings.strings
        try reader.read(sheet)
        rows = reader.rows; warnings = reader.warnings
        headers = (rows[1] ?? [:]).mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let recognized = headers.values.filter { RecipeField(rawValue: $0) != nil }
        guard recognized.contains("recipe_id"), recognized.contains("name"),
              Set(recognized).count == recognized.count else { throw RecipeStoreError.invalidHeaders }
    }

    func recipes() -> [Recipe] {
        var seen = Set<String>()
        return rows.keys.sorted().filter { $0 > 1 }.compactMap { row in
            let cells = rows[row]!
            guard cells.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            var fields: [RecipeField: String] = [:]
            for (column, header) in headers {
                if let field = RecipeField(rawValue: header) { fields[field] = cells[column] ?? "" }
            }
            var recipe = Recipe(fields: fields, row: row)
            recipe.warnings = recipe.validationWarnings() + warnings.filter { $0.row == row }
            if !seen.insert(recipe.id).inserted {
                recipe.warnings.append(.init(row: row, field: "recipe_id", message: "Duplicate recipe ID"))
            }
            return recipe
        }
    }

    func updating(_ recipe: Recipe) throws -> Data {
        guard !recipe.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecipeStoreError.invalidRecipe }
        let matches = recipes().filter { $0.id == recipe.id }
        guard matches.count <= 1 else { throw RecipeStoreError.invalidRecipe }
        let rowNumber = matches.first?.row ?? max(2, (rows.keys.max() ?? 1) + 1)
        let document = try XMLDocument(data: sheet, options: [.nodePreserveAll])
        guard let root = document.rootElement(), let sheetData = root.elements(forLocalName: "sheetData", uri: root.uri).first else {
            throw RecipeStoreError.invalidXML
        }
        func element(_ name: String) -> XMLElement {
            let prefix = root.prefix ?? ""
            return XMLElement(name: prefix.isEmpty ? name : prefix + ":" + name, uri: root.uri)
        }
        var headerMap = headers
        let headerRow = sheetData.elements(forLocalName: "row", uri: root.uri).first { $0.attribute(forName: "r")?.stringValue == "1" }
        guard let headerRow else { throw RecipeStoreError.invalidHeaders }
        // New schema columns are appended; unknown columns and their cells remain untouched.
        for field in RecipeField.allCases where recipe.fields[field] != nil && !headerMap.values.contains(field.rawValue) {
            let next = (headerMap.keys.map(Self.columnNumber).max() ?? 0) + 1
            let column = Self.columnName(next)
            headerMap[column] = field.rawValue
            headerRow.addChild(Self.inlineCell(reference: column + "1", value: field.rawValue, make: element))
        }
        let row = sheetData.elements(forLocalName: "row", uri: root.uri).first { $0.attribute(forName: "r")?.stringValue == String(rowNumber) } ?? element("row")
        if row.parent == nil {
            row.addAttribute(XMLNode.attribute(withName: "r", stringValue: String(rowNumber)) as! XMLNode)
            sheetData.addChild(row)
        }
        for (column, header) in headerMap.sorted(by: { Self.columnNumber($0.key) < Self.columnNumber($1.key) }) {
            guard let field = RecipeField(rawValue: header), let value = recipe.fields[field],
                  rows[rowNumber]?[column] != value else { continue }
            let reference = column + String(rowNumber)
            if let cell = row.elements(forLocalName: "c", uri: root.uri).first(where: { $0.attribute(forName: "r")?.stringValue == reference }) {
                // Retain style, metadata and extension attributes on the edited cell.
                cell.removeAttribute(forName: "t")
                cell.addAttribute(XMLNode.attribute(withName: "t", stringValue: "inlineStr") as! XMLNode)
                for child in cell.children ?? [] where ["v", "f", "is"].contains(child.localName ?? "") { child.detach() }
                let replacement = Self.inlineCell(reference: reference, value: value, make: element)
                let inline = replacement.children!.first!; inline.detach(); cell.addChild(inline)
            } else {
                let cell = Self.inlineCell(reference: reference, value: value, make: element)
                let following = (row.children ?? []).first { child in
                    guard let e = child as? XMLElement, e.localName == "c" else { return false }
                    return Self.columnNumber(e.attribute(forName: "r")?.stringValue ?? "") > Self.columnNumber(column)
                }
                if let following { row.insertChild(cell, at: following.index) } else { row.addChild(cell) }
            }
        }
        // Dimensions are a hint but Excel uses them to discover appended rows and columns.
        if let dimension = root.elements(forLocalName: "dimension", uri: root.uri).first {
            let previous = (dimension.attribute(forName: "ref")?.stringValue ?? "A1").split(separator: ":").last.map(String.init) ?? "A1"
            let lastColumn = max(Self.columnNumber(previous), headerMap.keys.map(Self.columnNumber).max() ?? 1)
            let lastRow = max(Int(previous.drop(while: { $0.isLetter })) ?? 1, max(rowNumber, rows.keys.max() ?? 1))
            dimension.attribute(forName: "ref")?.stringValue = "A1:\(Self.columnName(lastColumn))\(lastRow)"
        }
        // Inline strings avoid reindexing shared strings referenced by other sheets. The
        // existing sharedStrings.xml is therefore preserved byte-for-byte as well.
        return try zip.replacing([Self.sheetPath: document.xmlData(options: [.nodePreserveAll])])
    }
    private static func inlineCell(reference: String, value: String, make: (String) -> XMLElement) -> XMLElement {
        let cell = make("c")
        cell.addAttribute(XMLNode.attribute(withName: "r", stringValue: reference) as! XMLNode)
        cell.addAttribute(XMLNode.attribute(withName: "t", stringValue: "inlineStr") as! XMLNode)
        let inline = make("is"), text = make("t")
        text.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
        text.stringValue = value; inline.addChild(text); cell.addChild(inline)
        return cell
    }
    static func columnNumber(_ reference: String) -> Int {
        reference.prefix(while: { $0.isASCII && $0.isLetter }).uppercased().utf8.reduce(0) { $0 * 26 + Int($1) - 64 }
    }
    static func columnName(_ number: Int) -> String {
        var n = number, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
}

final class SheetXML: NSObject, XMLParserDelegate {
    var sharedStrings: [String] = []
    var strings: [String] = []
    var rows: [Int: [String: String]] = [:]
    var warnings: [RecipeWarning] = []
    private var row = 0, column = "", type = "", value = "", inline = "", shared = ""
    private var inCell = false, inValue = false, inText = false, inShared = false, inPhonetic = false
    func read(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse() else { throw RecipeStoreError.invalidXML }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "row": row = Int(attributes["r"] ?? "") ?? row + 1; rows[row] = [:]
        case "c":
            inCell = true; column = String((attributes["r"] ?? "").prefix(while: { $0.isLetter })).uppercased()
            if column.isEmpty { column = RecipeWorkbook.columnName((rows[row]?.keys.map(RecipeWorkbook.columnNumber).max() ?? 0) + 1) }
            type = attributes["t"] ?? "n"; value = ""; inline = ""
        case "v": inValue = true
        case "si": inShared = true; shared = ""
        case "rPh": inPhonetic = true
        case "t": inText = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { value += string }
        if inText && !inPhonetic {
            if inCell { inline += string }
            if inShared { shared += string }
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v": inValue = false
        case "t": inText = false
        case "rPh": inPhonetic = false
        case "si": strings.append(shared); inShared = false
        case "c":
            var text = type == "inlineStr" ? inline : value
            if type == "s" {
                if let index = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), sharedStrings.indices.contains(index) { text = sharedStrings[index] }
                else { warnings.append(.init(row: row, field: column, message: "Invalid shared string index: \(value)")) }
            } else if type == "e" { warnings.append(.init(row: row, field: column, message: "Spreadsheet error: \(value)")) }
            rows[row, default: [:]][column] = text; inCell = false
        default: break
        }
    }
}
