import Foundation
import RawDecode
import Recipes
import RecipeUI
import EditModel
import Profiles

enum AsShotCameraChecks {
    static func run(_ c: Checks) {
        c.suite("As-shot settings and camera panel") { c in
            let note = makerFixture()
            guard let shot = AsShotSettings.makerNote(note) else { c.fail("fixture MakerNote decoded=0/1"); return }
            let expected: [String: String] = ["film_simulation":"Acros", "wb_mode":"Auto", "wb_shift_r":"9", "wb_shift_b":"-9",
                "highlight_tone":"0", "shadow_tone":"3", "clarity":"0", "noise_reduction":"-4", "sharpness":"1",
                "grain_effect":"Strong", "grain_size":"Large", "color_chrome_effect":"Strong", "color_chrome_fx_blue":"Off",
                "monochromatic_color_wc":"0", "monochromatic_color_mg":"0", "dynamic_range":"Auto"]
            for (key, value) in expected.sorted(by: { $0.key < $1.key }) {
                let got = shot.values[key] ?? "missing"
                c.expect(got == value || (Double(got) != nil && Double(got) == Double(value)), "\(key)=\(got), expected=\(value)")
            }
            c.expect(shot.lensModulationOptimizer == true, "lens modulation optimizer=\(String(describing: shot.lensModulationOptimizer))/true")
            for little in [true, false] {
                let bytes = rafFixture(note, little: little)
                let parsed = AsShotSettings.parse(bytes)
                c.expect(parsed?.values == shot.values, "EXIF \(little ? "II" : "MM") walks past Make to 0x927C: matched=\(parsed?.values.count ?? 0)/\(shot.values.count)")
                c.expect(parsed?.rawExposureBias == -0.72, "RAF bias=\(parsed?.rawExposureBias ?? 999)/-0.72")
                let dir = try Checks.tempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let url = dir.appendingPathComponent("shot.RAF")
                try bytes.write(to: url)
                c.expect(AsShotSettings.read(from: url) == parsed, "file reader equals byte parser: bytes=\(bytes.count)")
            }
            c.expect(AsShotSettings.parse(Data("not a Fuji file".utf8)) == nil, "non-Fuji parsed=0/1")
            let full = rafFixture(note)
            let rejected = (0..<full.count).filter { AsShotSettings.parse(Data(full.prefix($0))) == nil }.count
            c.expect(rejected > full.count - 20, "truncated RAF prefixes rejected=\(rejected)/\(full.count)")
            var broken = full
            broken.replaceSubrange(84..<88, with: bytes(0xffffffff, 4, little: false))
            c.expect(AsShotSettings.parse(broken) == nil, "out-of-bounds JPEG pointer rejected=1/1")
            let signed = AsShotSettings.makerNote(makerFixture(wc: -7, mg: 11, highlight: -24, clarity: -3000))
            c.expect(signed?.values["monochromatic_color_wc"] == "-7.0" && signed?.values["monochromatic_color_mg"] == "11.0", "signed WC/MG=\(signed?.values["monochromatic_color_wc"] ?? "?")/\(signed?.values["monochromatic_color_mg"] ?? "?") expected=-7/11")
            c.expect(signed?.values["highlight_tone"] == "1.5" && signed?.values["clarity"] == "-3.0", "scaled tone/clarity=\(signed?.values["highlight_tone"] ?? "?")/\(signed?.values["clarity"] ?? "?") expected=1.5/-3")

            var panel = CameraPanelState(asShot: shot)
            c.expect(panel.values == shot.values && panel.differences.isEmpty, "opens at shot: fields=\(panel.values.count), differences=\(panel.differences.count)/0")
            _ = panel.set(.shadowTone, to: "2.5"); _ = panel.set(.wbShiftR, to: "8")
            _ = panel.set(.highlightTone, to: "0")
            c.expect(panel.differences == [.shadowTone, .wbShiftR], "exact changed markers=\(panel.differences.count)/2")
            let beforeInvalid = panel
            let invalid = panel.set(.highlightTone, to: "0.25")
            let outOfRange = panel.set(.sharpness, to: "5")
            c.expect(!invalid && !outOfRange && panel == beforeInvalid, "rejected quarter tone and sharpness 5: mutations=\(panel == beforeInvalid ? 0 : 1)/0")
            for field in [RecipeField.highlightTone, .shadowTone] {
                let accepted = stride(from: -2.0, through: 4.0, by: 0.5).filter { CameraPanelState.accepts(String($0), for: field) }.count
                c.expect(accepted == 13 && !CameraPanelState.accepts("0.25", for: field), "\(field.rawValue) accepted half steps=\(accepted)/13; quarter rejected=1/1")
            }
            panel.resetToShotSettings()
            c.expect(panel.values == shot.values && panel.differences.isEmpty, "reset restored=\(panel.values.count)/\(shot.values.count), markers=\(panel.differences.count)/0")
            c.expect(Recipe.filmSimulations.count == 20 && Recipe.filmSimulations.contains("Reala ACE") && panel.monochrome, "simulations=\(Recipe.filmSimulations.count)/20, Acros enables WC/MG=\(panel.monochrome)")

            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try RecipeChecks.profileFixture().write(to: dir.appendingPathComponent("provia.dcp"))
            let library = ProfileLibrary(bundledDirectory: nil, userDirectory: dir)
            let context = RecipeApplication.Context(asShotTemperature: 5500)
            let recipe = Recipe(fields: [.recipeID:"camera-test", .name:"Camera test", .filmSimulation:"Provia/Standard", .shadowTone:"1.5", .sharpness:"2"])
            var initial = EditStack()
            initial.geometry.rotation = 12
            initial.optics.correctDistortion = true
            initial.light.contrast = 19
            initial.detail.colorNR = 25
            initial.hsl[.green].hue = 7
            initial.cameraSettings = panel.values
            var history = EditHistory(initial)
            try panel.apply(recipe)
            let applied = try panel.resolved(on: initial, profiles: library, context: context, cameraModel: "FUJIFILM X-T5", recipeID: recipe.id)
            history.commit(applied)
            c.expect(applied.geometry == initial.geometry && applied.optics == initial.optics && applied.light.contrast == 19 && applied.detail.colorNR == 25 && applied.hsl[.green].hue == 7,
                     "unmapped fields retained=5/5, contrast=\(applied.light.contrast)/19, NR=\(applied.detail.colorNR)/25")
            c.expect(applied.light.shadows == -18 && applied.detail.sharpenAmount == 60 && applied.cameraSettings == panel.values,
                     "recipe resolves panel via mapping: shadows=\(applied.light.shadows)/-18, sharpness=\(applied.detail.sharpenAmount)/60")
            c.expect(history.undo() == initial && !history.canUndo, "one apply undo: remaining entries=\(history.canUndo ? 1 : 0)/0")
            c.expect(history.redo() == applied, "redo restores camera fields=\(history.current.cameraSettings?.count ?? 0)/\(panel.values.count)")
            let saved = try JSONDecoder().decode(EditStack.self, from: JSONEncoder().encode(applied))
            c.expect(saved == applied && CameraPanelState(asShot: shot, saved: saved.cameraSettings) == panel, "sidecar panel/stack exact round trip=\(saved == applied)")
            c.expect(try JSONDecoder().decode(EditStack.self, from: Data("{}".utf8)).cameraSettings == nil, "legacy sidecar camera settings absent=1/1")
            let emptyLibrary = ProfileLibrary(bundledDirectory: nil, userDirectory: dir.appendingPathComponent("missing"))
            let pending = try panel.resolved(on: applied, profiles: emptyLibrary, context: context,
                cameraModel: "FUJIFILM X-T5", allowUnresolvedSimulation: true)
            c.expect(pending.profileID.isEmpty && pending.cameraSettings == panel.values && pending.light.shadows == -18,
                     "unavailable simulation retains intent without old profile: profile chars=\(pending.profileID.count)/0, shadows=\(pending.light.shadows)/-18")
            panel.resetToShotSettings()
            let reset = try panel.resolved(on: pending, profiles: emptyLibrary, context: context,
                cameraModel: "FUJIFILM X-T5", recipeID: "", allowUnresolvedSimulation: true)
            c.expect(reset.cameraSettings == shot.values && reset.light.shadows == -36 && reset.geometry == initial.geometry && reset.recipeID.isEmpty,
                     "reset resolves shot and preserves crop: shadows=\(reset.light.shadows)/-36, recipe chars=\(reset.recipeID.count)/0")
            c.expect(panel.values == shot.values, "reset after recipe restores fields=\(panel.values.count)/\(shot.values.count)")
            // Optional local verification has no dependency on the user's photo or exiftool.
            let pictures = URL.homeDirectory.appendingPathComponent("Pictures")
            if let folders = try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil),
               let folder = folders.first(where: { $0.lastPathComponent.hasPrefix("05.09.2026") }),
               let real = AsShotSettings.read(from: folder.appendingPathComponent("DSCF8122.RAF")) {
                c.expect(real.values["film_simulation"] == "Acros" && real.values["wb_shift_r"] == "9.0" && real.values["sharpness"] == "1" && real.rawExposureBias == -0.72,
                         "DSCF8122 verified: simulation=\(real.values["film_simulation"] ?? "?"), R=\(real.values["wb_shift_r"] ?? "?"), sharpness=\(real.values["sharpness"] ?? "?"), bias=\(real.rawExposureBias ?? 999)")
            }
        }
    }

    private static func bytes(_ value: Int, _ size: Int, little: Bool = true) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * (little ? $0 : size-1-$0))) })
    }
    static func makerFixture(wc: Int = 0, mg: Int = 0, highlight: Int = 0, clarity: Int = 0) -> Data {
        let tags: [(Int, Int, Data)] = [(0x1003,3,bytes(0x500,2)),(0x1002,3,bytes(0,2)),
            (0x100a,9,bytes(180,4)+bytes(-180,4)),(0x1041,9,bytes(highlight,4)),(0x1040,9,bytes(-48,4)),
            (0x100f,9,bytes(clarity,4)),(0x100e,3,bytes(0x2e0,2)),(0x1001,3,bytes(0x84,2)),
            (0x1047,9,bytes(64,4)),(0x104c,3,bytes(32,2)),(0x1048,9,bytes(64,4)),(0x104e,9,bytes(0,4)),
            (0x1049,7,bytes(wc,1)),(0x104b,7,bytes(mg,1)),(0x1045,4,bytes(1,4)),(0x1402,3,bytes(0,2))]
        var note = Data("FUJIFILM".utf8) + bytes(12,4) + bytes(tags.count,2)
        var payload = Data()
        for (tag,type,value) in tags {
            let width = type == 3 ? 2 : type == 7 ? 1 : 4
            note += bytes(tag,2)+bytes(type,2)+bytes(value.count/width,4)
            if value.count <= 4 { note += value + Data(repeating: 0, count: 4-value.count) }
            else { note += bytes(18+tags.count*12+payload.count,4); payload += value }
        }
        return note + bytes(0,4) + payload
    }
    private static func rafFixture(_ note: Data, little: Bool = true) -> Data {
        func b(_ n: Int, _ size: Int) -> Data { bytes(n,size,little:little) }
        // Make is physically before the ExifIFD and the genuine MakerNote signature.
        var tiff = Data(little ? [73,73] : [77,77]) + b(42,2) + b(8,4) + b(2,2)
        tiff += b(0x10f,2)+b(2,2)+b(9,4)+b(38,4)
        tiff += b(0x8769,2)+b(4,2)+b(1,4)+b(48,4)+b(0,4)
        tiff += Data("FUJIFILM\0\0".utf8)
        tiff += b(1,2)+b(0x927c,2)+b(7,2)+b(note.count,4)+b(66,4)+b(0,4)+note
        let exif = Data([69,120,105,102,0,0]) + tiff
        let jpeg = Data([255,216,255,225]) + bytes(exif.count+2,2,little:false) + exif + Data([255,217])
        let rafMeta = bytes(1,4,little:false)+bytes(0x9650,2,little:false)+bytes(4,2,little:false)+bytes(-72,2,little:false)+bytes(100,2,little:false)
        var raf = Data("FUJIFILMCCD-RAW ".utf8)
        raf += Data(repeating: 0,count:108-raf.count)
        raf.replaceSubrange(84..<100, with: bytes(108,4,little:false)+bytes(jpeg.count,4,little:false)+bytes(108+jpeg.count,4,little:false)+bytes(rafMeta.count,4,little:false))
        return raf+jpeg+rafMeta
    }
}
