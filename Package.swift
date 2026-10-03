// swift-tools-version: 6.2
import PackageDescription

// Target graph note (Build plan §9): ImageCanvas MUST NOT depend on StudioTheme.
// The Liquid Glass chrome can never reach the image pipeline. Enforced here by the
// compiler, and asserted by ArchitectureTests so a future edit cannot quietly undo it.
let package = Package(
    name: "XTransDarkroom",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "XTransDarkroom", targets: ["App"]),
        .executable(name: "Checks", targets: ["Checks"]),
        .executable(name: "Spike", targets: ["Spike"]),
        .executable(name: "ImportRecipes", targets: ["ImportRecipes"])
    ],
    targets: [
        // Colour maths, pixel formats, shared value types. No UI, no I/O.
        .target(name: "ImagingCore"),
        .target(name: "ShortcutLogic"),
        .executableTarget(name: "ImportRecipes", dependencies: ["Recipes"]),

        // The non-destructive edit stack + serialization.
        .target(name: "EditModel", dependencies: ["ImagingCore", "RawDecode"]),

        .target(name: "Profiles", dependencies: ["EditModel"]),
        .target(name: "Recipes", dependencies: ["EditModel", "Profiles"], linkerSettings: [.linkedLibrary("z")]),

        // RawDecoder protocol + Core Image implementation.
        .target(name: "RawDecode", dependencies: ["ImagingCore"]),

        // Catalog / thumbnail cache (Phase 6).
        .target(name: "Catalog", dependencies: ["ImagingCore", "EditModel", "RawDecode"]),

        // Liquid Glass chrome: tokens, metrics, type roles, controls.
        .target(name: "StudioTheme"),
        .target(name: "RecipeUI", dependencies: ["Recipes", "LibraryLogic", "Catalog", "RawDecode", "EditModel", "Profiles"]),
        .target(name: "LibraryLogic", dependencies: ["Catalog"]),

        // Full-fidelity image canvas. Depends on imaging only - NEVER on StudioTheme.
        .target(name: "ImageCanvas", dependencies: ["ImagingCore", "EditModel", "RawDecode", "Profiles"]),

        .target(name: "Export", dependencies: ["ImagingCore", "EditModel", "RawDecode", "ImageCanvas", "LibraryLogic", "Profiles"]),

        .executableTarget(name: "App", dependencies: [
            "ShortcutLogic", "ImagingCore", "EditModel", "RawDecode", "Catalog", "StudioTheme", "ImageCanvas", "LibraryLogic", "Profiles", "Recipes", "RecipeUI", "Export"
        ]),

        // Verification gate. Xcode is absent on this machine, so XCTest/swift-testing
        // are unavailable; `swift run Checks` is the project's test command instead.
        .executableTarget(name: "Checks", dependencies: ["ShortcutLogic", "ImagingCore", "EditModel", "RawDecode", "ImageCanvas", "Catalog", "LibraryLogic", "Profiles", "Recipes", "RecipeUI", "Export", "StudioTheme"]),

        // Phase 0 measurement tool: decode timing, metadata, embedded lens data.
        .executableTarget(name: "Spike", dependencies: ["ImagingCore", "EditModel", "RawDecode", "ImageCanvas"]),
    ]
)
