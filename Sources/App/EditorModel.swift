import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EditModel
import ImageCanvas
import ImagingCore
import Export
import Recipes
import RecipeUI
import ShortcutLogic
import RawDecode

/// Owns the edit stack, the history, and the bridge to the render coordinator.
///
/// Build plan §3: a slider drag calls `live(_:)`, which pushes straight through to the
/// coordinator's interactive path. `commit()` runs once on release and is the only thing
/// that touches undo history.
@MainActor
final class EditorModel: ObservableObject {

    @Published private(set) var openRevision = 0
    @Published var stack = EditStack()
    @Published var canvasLongEdge = 2560
    @Published var statusLine = "No image open"

    let recipes = RecipeBrowserModel()
    @Published var showsRecipes = false
    @Published var showsCopySettings = false
    @Published var wbPickerBusy = false
    var wbPickerRevision = 0
    @Published var copySections: EditStackSections = .standard
    @Published var settingsClipboard: SettingsClipboard?
    @Published var previousStack: EditStack?
    @Published var libraryMode = true
    @Published var selectedLibraryPaths: Set<String> = []
    weak var library: LibraryModel?

    init() {
        // Smoke-test hook: exercise the develop layout without opening an image.
        if ProcessInfo.processInfo.environment["XTD_START_MODE"] == "develop" { libraryMode = false }
        // The model is owned by the App, so window recreation cannot trigger automatic reloads.
        Task { await recipes.reload() }
    }

    let viewer = ViewerState()
    let coordinator = RenderCoordinator()

    func viewerChanged() {
        coordinator.wbPicking = viewer.wbPickerActive
        let wasFull = coordinator.usesFullFrame
        coordinator.displayedScale = max(viewer.viewport.zoom,
            viewer.beforeAfterMode == .off ? 0 : viewer.viewport(for: coordinator.beforePixelSize).zoom)
        if wasFull != coordinator.usesFullFrame { live() }
        coordinator.scheduleSettle(stack)
    }
    private var sliderCoalescing = SliderCoalescing()
    private var persistence = SidecarPersistence()
    private var history = EditHistory(EditStack())

    var cameraSource: CameraSource { coordinator.cameraSource }
    var canUseCamera: Bool { coordinator.hasImage && cameraSource.isFujifilmRAF }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    private var recipeContext: RecipeApplication.Context {
        .init(asShotTemperature: coordinator.metadata.asShotTemperature,
              asShotTint: coordinator.metadata.asShotTint)
    }

    func recipeAttribution(in loaded: [Recipe]) -> String? {
        guard canUseCamera, !stack.recipeID.isEmpty else { return nil }
        guard let recipe = loaded.first(where: { $0.id == stack.recipeID }) else {
            return "based on " + stack.recipeID + " — recipe unavailable"
        }
        do {
            var expected = cameraPanel
            try expected.apply(recipe)
            let resolved = try expected.resolved(on: stack, profiles: coordinator.profileLibrary,
                context: recipeContext, cameraModel: coordinator.metadata.cameraModel,
                recipeID: recipe.id, allowUnresolvedSimulation: true)
            let modified = resolved != stack
            return RecipeBrowserModel.attribution(for: recipe, modified: modified)
        } catch { return "based on " + recipe.name + " — comparison unavailable" }
    }

    @Published var cameraMessage: String?
    @Published var cameraPanelRevision = 0

    var cameraPanel: CameraPanelState {
        CameraPanelState(asShot: canUseCamera ? coordinator.asShotSettings : nil, saved: canUseCamera ? stack.cameraSettings : nil)
    }

    private func resolveCamera(_ panel: CameraPanelState, recipeID: String? = nil) throws {
        guard canUseCamera else { return }
        stack = try panel.resolved(on: stack, profiles: coordinator.profileLibrary,
            context: recipeContext, cameraModel: coordinator.metadata.cameraModel, recipeID: recipeID,
            allowUnresolvedSimulation: true)
        cameraMessage = nil
        commit()
        live()
    }

    func changeCamera(_ field: RecipeField, to value: String) {
        var panel = cameraPanel
        guard panel.set(field, to: value) else { return }
        do { try resolveCamera(panel) }
        catch { cameraMessage = cameraError(error) }
    }

    func resetToShotSettings() {
        var panel = cameraPanel
        panel.resetToShotSettings()
        do { try resolveCamera(panel, recipeID: "") }
        catch { cameraMessage = cameraError(error) }
    }

    private func cameraError(_ error: Error) -> String {
        if case RecipeApplication.ApplicationError.missingProfile(let name) = error {
            return "Import a matching \(name) camera profile in Color to render these settings."
        }
        return "Could not apply camera settings: \(error)"
    }

    func applyRecipe(_ recipe: Recipe) throws {
        if libraryMode { try applyLibraryRecipe(recipe); return }
        guard canUseCamera else { return }
        var panel = cameraPanel
        try panel.apply(recipe)
        try resolveCamera(panel, recipeID: recipe.id)
        cameraPanelRevision += 1
    }

    func adoptRecipeStack(_ applied: EditStack) {
        stack = applied
        history.commit(stack)
        live()
        coordinator.scheduleSettle(stack)
    }

    func chooseRecipeSpreadsheet() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.message = "Choose your recipe spreadsheet. Download it in Finder first if it is stored in Google Drive."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showsRecipes = true
        Task { await recipes.choose(url) }
    }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SupportedFormats.contentTypes
        panel.message = "Open " + SupportedFormats.all.sorted().joined(separator: ", ").uppercased()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dcp") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try coordinator.importProfile(from: url)
            live()
            coordinator.scheduleSettle(stack)
        } catch { statusLine = "Could not import profile: \(error)" }
    }

    /// Set when a photo switch was blocked by a failed save; drives the confirmation alert.
    struct BlockedSwitch: Equatable { let url: URL; let message: String }
    @Published var blockedSwitch: BlockedSwitch?

    func open(_ url: URL) {
        sliderCoalescing.reset()
        if coordinator.hasImage {
            persist()
            if case .blocked(let message) = persistence.prepareSwitch(stack, currentSource: coordinator.sourceURL) {
                NSLog("XTransDarkroom: switch blocked: %@", message)
                statusLine = message
                blockedSwitch = BlockedSwitch(url: url, message: message)
                return
            }
        }
        openUnguarded(url)
    }

    func discardEditsAndOpenBlocked() {
        guard let pending = blockedSwitch else { return }
        blockedSwitch = nil
        persistence.discardUnsavedEdits()
        openUnguarded(pending.url)
    }

    func cancelBlockedSwitch() { blockedSwitch = nil }

    private func openUnguarded(_ url: URL) {
        if coordinator.hasImage, coordinator.sourceURL != url { previousStack = stack }
        openRevision += 1
        let existing = (try? Sidecar.load(forImageAt: url)) ?? nil
        var loaded = existing ?? EditStack.freshOpenDefault(for: url)
        loaded.fingerprint = (try? SourceFingerprint.compute(for: url)) ?? ""
        stack = loaded
        persistence.adopt(stackFor: url)
        history = EditHistory(loaded)

        coordinator.open(url, canvasLongEdge: canvasLongEdge)

        cameraMessage = nil
        if canUseCamera, existing == nil, coordinator.asShotSettings != nil {
            let panel = cameraPanel
            stack.cameraSettings = panel.values
            do {
                stack = try panel.resolved(on: stack, profiles: coordinator.profileLibrary,
                    context: recipeContext, cameraModel: coordinator.metadata.cameraModel, allowUnresolvedSimulation: true)
            } catch { cameraMessage = cameraError(error) }
            history = EditHistory(stack)
        }
        // Match first-open treatment, including as-shot camera/profile resolution;
        // saved sidecars and subsequent edits never become the Before baseline.
        var before = EditStack.freshOpenDefault(for: url)
        if canUseCamera, let asShot = coordinator.asShotSettings {
            let panel = CameraPanelState(asShot: asShot, saved: nil)
            before = (try? panel.resolved(on: before, profiles: coordinator.profileLibrary,
                context: recipeContext, cameraModel: coordinator.metadata.cameraModel,
                allowUnresolvedSimulation: true)) ?? before
        }
        coordinator.setBeforeStack(before)
        viewer.reset()
        coordinator.displayedScale = 0
        coordinator.renderInteractive(stack)
        coordinator.scheduleSettle(stack)

        if let error = coordinator.lastError {
            statusLine = error
        } else if let fallback = coordinator.metadata.fallbackStatus {
            statusLine = fallback
        } else {
            let size = coordinator.fullPixelSize
            let mp = size.width * size.height / 1_000_000
            statusLine = String(format: "%@  ·  %.0f × %.0f (%.1f MP)  ·  proxy %.0f%%",
                                url.lastPathComponent, size.width, size.height, mp,
                                coordinator.currentProxyRatio * 100)
        }
    }

    // MARK: Editing

    /// Continuous during a drag. Never touches history, never writes a sidecar.
    func live() {
        coordinator.renderInteractive(stack)
    }

    /// Once on release: one undo entry, one settle render, one sidecar write.
    func commitKeyboardSlider(id: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard stack != history.current else { return }
        if sliderCoalescing.press(id: id, now: now) { history.coalesce(stack) }
        else { history.commit(stack) }
        coordinator.scheduleSettle(stack)
        persist()
    }

    func commit() {
        sliderCoalescing.reset()
        history.commit(stack)
        coordinator.scheduleSettle(stack)
        persist()
    }

    func undo() {
        sliderCoalescing.reset()
        guard let s = history.undo() else { return }
        stack = s
        coordinator.renderInteractive(stack)
        coordinator.scheduleSettle(stack)
        persist()
    }

    func redo() {
        sliderCoalescing.reset()
        guard let s = history.redo() else { return }
        stack = s
        coordinator.renderInteractive(stack)
        coordinator.scheduleSettle(stack)
        persist()
    }

    func resetAll() {
        var fresh = EditStack()
        fresh.fingerprint = stack.fingerprint
        if canUseCamera, coordinator.asShotSettings != nil {
            var panel = cameraPanel
            panel.resetToShotSettings()
            do {
                fresh = try panel.resolved(on: fresh, profiles: coordinator.profileLibrary,
                    context: recipeContext, cameraModel: coordinator.metadata.cameraModel,
                    allowUnresolvedSimulation: true)
            } catch { cameraMessage = cameraError(error); return }
        }
        stack = fresh
        commit()
        coordinator.renderInteractive(stack)
    }

    private func persist() {
        if !persistence.save(stack, currentSource: coordinator.sourceURL),
           persistence.isDirty, let message = persistence.failure {
            NSLog("XTransDarkroom: %@", message)
            statusLine = message
        }
    }

    func canvasResized(to longEdge: Int) {
        guard abs(longEdge - canvasLongEdge) > 32 else { return }
        canvasLongEdge = longEdge
        coordinator.rebuildProxy(canvasLongEdge: longEdge)
        coordinator.renderInteractive(stack)
    }
}
