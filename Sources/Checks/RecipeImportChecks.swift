import Foundation
import Recipes

enum RecipeImportChecks {
    @MainActor static func run(_ c: Checks) async {
        await c.suite("Recipe import") { c in
            func check(_ column: String, _ text: String, _ expected: [RecipeField: String]) {
                var cells = ["Name": "Test", "Film Simulation": "Classic Chrome"]; cells[column] = text
                let recipe = RecipeImporter.convert(cells, sheet: "Sheet1", row: 2)
                c.expect(expected.allSatisfy { recipe[$0.key] == $0.value } && recipe.warnings.isEmpty, "\(column) \(text): exact typed values, no warnings")
            }
            func rejected(_ column: String, _ text: String, _ fields: [RecipeField]) throws {
                var cells = ["Name": "Test", "Film Simulation": "Classic Chrome"]; cells[column] = text
                let recipe = RecipeImporter.convert(cells, sheet: "Sheet1", row: 2)
                let notes = try JSONSerialization.jsonObject(with: Data(recipe[.importNotes].utf8)) as? [String: String]
                c.expect(fields.allSatisfy { recipe[$0].isEmpty } && notes?[column] == text && recipe.warnings.contains { $0.field == column }, "\(column) \(text): empty fields AND verbatim preserved AND warning")
            }
            for (text, mode, kelvin, r, b) in [
                ("Auto, R: 2, B: -4", "Auto", "", "2", "-4"),
                ("Auto Ambience Priority, R: -1, B: -4", "Auto Ambience Priority", "", "-1", "-4"),
                ("5200K, R: +1, B: -5", "Kelvin", "5200", "1", "-5"),
                ("5600K, -4 Red & -5 Blue", "Kelvin", "5600", "-4", "-5"),
                ("Fluorescent 2, -2 Red, -6 Blue", "Fluorescent 2", "", "-2", "-6"),
                ("Underwater, R: 0, B: 0", "Underwater", "", "0", "0"),
                ("Daylight, R: +4, B: -5", "Daylight", "", "4", "-5")
            ] { check("WB", text, [.wbMode: mode, .wbKelvin: kelvin, .wbShiftR: r, .wbShiftB: b]) }
            for (text, effect, size) in [("Weak, Small", "Weak", "Small"), ("Strong, Large", "Strong", "Large"), ("Off", "Off", ""), ("No", "Off", "")] {
                check("Grain", text, [.grainEffect: effect, .grainSize: size])
            }
            try rejected("Grain", "Off (Mod: Try Weak, Small)", [.grainEffect, .grainSize])
            check("Tone Curve", "H: +1, S: -2", [.highlightTone: "1", .shadowTone: "-2"])
            check("Tone Curve", "H: -1.5, S: +0.5", [.highlightTone: "-1.5", .shadowTone: "0.5"])
            for text in ["H: -1 or -2, S: +2 to +4", "H: +1, S: +1 (Mod: Try +2 for moody, 0 for soft)"] { try rejected("Tone Curve", text, [.highlightTone, .shadowTone]) }
            for (text, value) in [("Classic Chrome", "Classic Chrome"), ("Classic Negative", "Classic Neg"), ("Eterna/Cinema", "Eterna"), ("Acros+G", "Acros +G"), ("Acros + Yellow Filter", "Acros +Ye"), ("Reala ACE", "Reala ACE")] { check("Film Simulation", text, [.filmSimulation: value]) }
            for text in ["Classic Chrome or Eterna", "Monochrome (Std, R, Y, or G)", "Acros + Red/Yellow Filter"] { try rejected("Film Simulation", text, [.filmSimulation]) }
            check("DR", "DR400", [.dynamicRange: "DR400"]); check("DR", "Auto", [.dynamicRange: "Auto"])
            try rejected("DR", "DR200 or DR400", [.dynamicRange])
            check("Exp Comp", "+1/3", [.exposureComp: String(1.0 / 3)])
            for text in ["0 to +2/3", "92", "31", "105", "98", "69", " 0 to +2/3 "] { try rejected("Exp Comp", text, [.exposureComp]) }
            check("Monochromatic Color", "WC: +1, MG: 0", [.monochromaticColorWC: "1", .monochromaticColorMG: "0"])
            for (column, field) in [("Clarity", RecipeField.clarity), ("NR", .noiseReduction), ("Sharpness", .sharpness)] {
                for (text, value) in [("+2", "2"), ("-4", "-4"), ("0", "0")] { check(column, text, [field: value]) }
                try rejected(column, "Color: 0 to +2", [field])
            }
            let dir = try Checks.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            // Build a real XLSX fixture in a temporary folder with both differently shaped sheets.
            func sheet(_ rows: [[String]]) -> String {
                "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>" + rows.enumerated().map { r, row in
                    "<row r=\"\(r + 1)\">" + row.enumerated().map { i, value in
                        "<c r=\"\(String(UnicodeScalar(65 + i)!))\(r + 1)\" t=\"inlineStr\"><is><t>\(value)</t></is></c>"
                    }.joined() + "</row>"
                }.joined() + "</sheetData></worksheet>"
            }
            let parts = [
                "xl/workbook.xml": "<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Color\" r:id=\"one\"/><sheet name=\"B&amp;W\" r:id=\"two\"/></sheets></workbook>",
                "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id=\"one\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"two\" Target=\"worksheets/sheet2.xml\"/></Relationships>",
                "xl/worksheets/sheet1.xml": sheet([["Name", "Film Simulation:", "Used?", "Like?", "Exp Comp"], ["Colour", "Classic Chrome", "Camera", "Try", "92"]]),
                "xl/worksheets/sheet2.xml": sheet([["Name", "Monochromatic Color", "Film Simulation", "Used?", "Like?"], ["Mono", "WC: +1, MG: 0", "Acros+G", "Yes", "2"]])
            ]
            for (path, text) in parts {
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            func archive(_ name: String) throws -> URL {
                let url = dir.appendingPathComponent(name), process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.currentDirectoryURL = dir
                process.arguments = ["-q", "-r", url.path, "xl"]; try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw RecipeStoreError.invalidZIP }; return url
            }
            let source = try archive("source.xlsx"), original = try Data(contentsOf: source)
            let result = try RecipeImporter.read(original)
            c.expect(result.rowsRead == 2 && result.recipes.count == 2 && result.recipes.map { $0[.sourceSheet] } == ["Color", "B&W"], "both sheets read; exact row count")
            for path in ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] { try Data(sheet([]).utf8).write(to: dir.appendingPathComponent(path)) }
            let destination = try archive("target.xlsx"), blank = try Data(contentsOf: destination)
            let store = LocalRecipeStore(spreadsheet: destination)
            try await store.importIntoBlank(result.recipes)
            let loaded = try await LocalRecipeStore(spreadsheet: destination).loadAll()
            c.expect(loaded.map(\.fields) == result.recipes.map(\.fields), "all fields survive round trip, including used/liked/monochromatic/import_notes")
            let backups = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("recipes-backup"), includingPropertiesForKeys: nil)
            let backup = try Data(contentsOf: backups[0])
            c.expect(backups.count == 1 && backup == blank, "one exact blank backup before batch import")
            c.expect(try Data(contentsOf: source) == original, "source bytes untouched")
            do { try await store.importIntoBlank(result.recipes); c.fail("nonblank destination accepted") } catch { c.expect(true, "nonblank destination rejected") }
            do { _ = try RecipeImporter.read(source: source, destination: source); c.fail("source alias accepted") } catch { c.expect(true, "source/destination alias rejected") }
        }
    }
}
