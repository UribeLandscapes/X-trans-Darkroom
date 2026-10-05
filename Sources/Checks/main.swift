import Foundation
import ImagingCore
import EditModel

let c = Checks()
await MultiCameraChecks.run(c)
await DataLossChecks.run(c)
await CoordinatorChecks.run(c)
StrictDecodeChecks.run(c)

// ─────────────────────────────────────────────────────────────────────────────
c.suite("EditStack serialization (Build plan §2)") { c in

    // Omitted keys must round-trip to neutral defaults, so a sidecar written by an
    // older build stays readable after fields are added in a later phase.
    let sparse = #"{"version":1,"fingerprint":"abc","light":{"exposure":1.5}}"#
    let stack = try JSONDecoder().decode(EditStack.self, from: Data(sparse.utf8))
    c.expect(stack.light.exposure == 1.5, "sparse JSON keeps the value it does specify")
    c.expect(stack.light.contrast == 0, "sparse JSON fills omitted Light fields with neutral")
    c.expect(stack.color == .neutral, "sparse JSON fills an entirely omitted group with neutral")
    c.expect(stack.geometry.cropWidth == 1, "omitted crop defaults to the full frame")
    c.expect(stack.profileID.isEmpty, "omitted profile defaults to the file's own")

    var full = EditStack()
    full.fingerprint = "deadbeef"
    full.light.exposure = -0.75
    full.light.shadows = 42
    full.color.temperature = 5200
    full.color.vibrance = 18
    full.effects.clarity = 30
    full.detail.sharpenRadius = 1.4
    full.profileID = "fuji-xt5-standard"
    full.recipeID = "classic-neg-01"
    let decoded = try JSONDecoder().decode(EditStack.self, from: JSONEncoder().encode(full))
    c.expect(decoded == full, "every field survives an encode/decode round trip")

    // A decoder fallback that disagrees with its property default means an empty sidecar
    // decodes to something other than a fresh stack - the exact drift that made "neutral"
    // stop being an identity once colour NR defaulted to 25 in one place and 0 in the other.
    let emptyDecoded = try JSONDecoder().decode(EditStack.self, from: Data("{}".utf8))
    c.expect(emptyDecoded == EditStack(),
             "an empty sidecar decodes to exactly a fresh EditStack (defaults and decoder fallbacks agree)")

    var dirty = EditStack()
    c.expect(dirty.isNeutral, "a fresh stack reports neutral")
    dirty.light.exposure = 0.01
    c.expect(!dirty.isNeutral, "any change clears neutral (drives the edited badge)")
}

// ─────────────────────────────────────────────────────────────────────────────
c.suite("Undo / redo (Build plan §2)") { c in
    var a = EditStack(); a.light.exposure = 1
    var b = EditStack(); b.light.exposure = 2
    var history = EditHistory(EditStack())

    history.commit(a)
    history.commit(b)
    c.expect(history.current.light.exposure == 2, "commit advances current state")
    c.expect(history.undo()?.light.exposure == 1, "undo steps back one commit")
    c.expect(history.undo()?.light.exposure == 0, "undo reaches the initial state")
    c.expect(history.undo() == nil, "undo past the start returns nil")
    c.expect(history.redo()?.light.exposure == 1, "redo steps forward again")

    var quiet = EditHistory(EditStack())
    quiet.commit(EditStack())
    c.expect(!quiet.canUndo, "committing an identical state adds no undo entry")
}

// ─────────────────────────────────────────────────────────────────────────────
c.suite("Sidecar persistence (Build plan §2, §7)") { c in
    let dir = try Checks.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let image = dir.appendingPathComponent("DSCF1234.RAF")
    try Data("not really a raf".utf8).write(to: image)

    var stack = EditStack()
    stack.light.exposure = 0.66
    try Sidecar.save(stack, forImageAt: image)

    c.expect(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("DSCF1234.RAF.xtd.json").path),
        "sidecar is written beside the image as <filename>.xtd.json")

    let loaded = try Sidecar.load(forImageAt: image)
    c.expect(loaded?.light.exposure == 0.66, "sidecar reloads the committed value")

    let fp1 = try SourceFingerprint.compute(for: image)
    let fp2 = try SourceFingerprint.compute(for: image)
    c.expect(fp1 == fp2, "fingerprint is stable for an unchanged file")

    // §7: an externally modified source must yield a different key, so derivatives
    // regenerate without any explicit cache-invalidation pass.
    Thread.sleep(forTimeInterval: 0.02)
    try Data("modified".utf8).write(to: image)
    let fp3 = try SourceFingerprint.compute(for: image)
    c.expect(fp1 != fp3, "fingerprint changes when the source file changes")
}

// ─────────────────────────────────────────────────────────────────────────────
c.suite("Scale-dependent parameters (Build plan §2, dual-resolution trap)") { c in
    let radius = Parameter(key: "sharpenRadius", range: 0...10, neutral: 1, domain: .pixels)
    c.expectClose(radius.resolved(4.0, proxyRatio: 0.25), 1.0,
                  "pixel-domain radius scales down for a quarter-scale proxy")
    c.expectClose(radius.resolved(4.0, proxyRatio: 1.0), 4.0,
                  "pixel-domain radius is unchanged at full resolution")

    let exposure = Parameter(key: "exposure", range: -5...5, neutral: 0)
    c.expectClose(exposure.resolved(1.5, proxyRatio: 0.25), 1.5,
                  "invariant parameter does not scale with the proxy")

    let k1 = Parameter(key: "k1", range: -1...1, neutral: 0, domain: .normalized)
    c.expectClose(k1.resolved(0.3, proxyRatio: 0.1), 0.3,
                  "normalized parameter does not scale with the proxy")

    let contrast = Parameter(key: "contrast", range: -100...100, neutral: 0)
    c.expect(contrast.clamped(250) == 100, "clamping respects the declared upper bound")
    c.expect(contrast.clamped(-250) == -100, "clamping respects the declared lower bound")
}

// ─────────────────────────────────────────────────────────────────────────────
// Build plan §9: the Liquid Glass chrome must never be able to reach the image. The
// guarantee is structural, and this check keeps it from being undone in a later refactor.
c.suite("Canvas / chrome isolation (Build plan §9)") { c in
    let root = Checks.repoRoot()
    let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)

    if let line = manifest.split(separator: "\n").first(where: {
        $0.contains(#".target(name: "ImageCanvas""#)
    }) {
        c.expect(!line.contains("StudioTheme"),
                 "ImageCanvas target declares no dependency on StudioTheme")
    } else {
        c.fail("ImageCanvas target declaration not found in Package.swift")
    }

    let canvasDir = root.appendingPathComponent("Sources/ImageCanvas")
    var checked = 0
    var offenders: [String] = []
    if let walker = FileManager.default.enumerator(at: canvasDir, includingPropertiesForKeys: nil) {
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            checked += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("import StudioTheme") { offenders.append(url.lastPathComponent) }
        }
    }
    c.expect(checked > 0, "canvas sources were actually scanned (\(checked) files)")
    c.expect(offenders.isEmpty, "no canvas source imports StudioTheme\(offenders.isEmpty ? "" : " - \(offenders)")")
}

RenderChecks.run(c)
GlowChecks.run(c)
LightToneChecks.run(c)

await CatalogChecks.run(c)

LibraryChecks.run(c)

ProfileChecks.run(c)

ProfilePipelineChecks.run(c)

await RecipeChecks.run(c)
await RecipeImportChecks.run(c)

await RecipeUIWiringChecks.run(c)

await ExportChecks.run(c)
await ExportLinkChecks.run(c)
await ExportStacksChecks.run(c)

AsShotCameraChecks.run(c)
QuitGuardChecks.run(c)

LayoutChecks.run(c)
StudioOverlayChecks.run(c)
SliderChecks.run(c)
ViewportChecks.run(c)

DevelopFeatureChecks.run(c)
ShortcutChecks.run(c)
AdvisoryMediumChecks.run(c)

c.finish()
