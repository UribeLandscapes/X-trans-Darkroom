import SwiftUI
import EditModel
import ImageCanvas
import ImagingCore
import StudioTheme
import LibraryLogic
import Export
import ShortcutLogic
import AppKit

/// Build plan §9 in practice, restyled again as an iPadOS-style shell: `NavigationSplitView`
/// (sidebar of library sources + detail) with a trailing `.inspector`, and a native toolbar
/// standing in for the old capsule title bar. In the middle, unchanged, sits an
/// `ImageCanvasView` that knows nothing about any of it. See `SidebarView`, `InspectorView`,
/// `DevelopToolbarContent` for the split-out pieces this file used to contain inline.
struct EditorView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var coordinator: RenderCoordinator
    @State var focusMode = false
    @State var showCanvasBar = true
    @State var showsShortcuts = false
    @StateObject var sliderKeyboard = SliderKeyboard()
    @ObservedObject var viewer: ViewerState
    var expansion = InspectorExpansion()
    @StateObject var library = LibraryModel()
    @State private var blipBusy = false
    @State private var exportRequest: ExportRequest?
    var libraryMode: Bool {
        get { editor.libraryMode }
        nonmutating set { editor.libraryMode = newValue }
    }
    @State var developAccess: LibraryLogic.FolderAccess?

    // Split-view chrome state. Focus mode collapses both the sidebar and the inspector; their
    // prior visibility is restored on exit rather than hard-reset to a default.
    @State var columnVisibility: NavigationSplitViewVisibility = .all
    @State var showInspector = true
    @State private var preFocusColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var preFocusShowInspector = true

    init(editor: EditorModel) {
        self.editor = editor
        self.coordinator = editor.coordinator
        self.viewer = editor.viewer
    }


    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(library: library, editor: editor)
        } detail: {
            VStack(spacing: 0) {
                if libraryMode {
                    LibraryView(model: library) { row in
                        developAccess = library.access(for: row.path)
                        editor.open(URL(fileURLWithPath: row.path))
                        libraryMode = false
                    }
                } else {
                    CanvasArea(editor: editor, coordinator: coordinator, viewer: viewer, focusMode: focusMode)
                    if showCanvasBar { CanvasBar(viewer: viewer) }
                }
                RecipeAttributionView(editor: editor, recipes: editor.recipes)
                statusBar.saturation(focusMode ? 0 : 1)
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(libraryMode: libraryMode, library: library, editor: editor,
                          coordinator: coordinator, expansion: expansion, focusMode: focusMode)
                .environment(\.sliderKeyboard, sliderKeyboard)
                .environment(\.sliderKeyboardCommit, { id in editor.commitKeyboardSlider(id: id) })
                .inspectorColumnWidth(min: StudioMetrics.panelWidth, ideal: StudioMetrics.panelWidth,
                                       max: StudioMetrics.panelWidth * 1.4)
        }
        .toolbar {
            DevelopToolbarContent(
                editor: editor, coordinator: coordinator, libraryMode: $editor.libraryMode,
                focusMode: focusMode, showInspector: showInspector,
                exportDisabled: libraryMode ? library.selectedPaths.isEmpty : !coordinator.hasImage,
                blipBusy: blipBusy, onBlip: sendToPhone,
                onExport: presentExport, onToggleFocus: toggleFocus,
                onToggleInspector: { showInspector.toggle() })
        }
        .background(focusMode ? Studio.surround(focused: true) : Studio.background)
        .environment(\.studioFocusMode, focusMode)
        .sheet(isPresented: $editor.showsRecipes) { RecipeBrowserView(editor: editor, model: editor.recipes) }
        .sheet(isPresented: $editor.showsCopySettings) { CopySettingsSheet(editor: editor) }
        .background(DevelopKeys(editor: editor, perform: performShortcut).frame(width: 0, height: 0))
        .focusedSceneValue(\.shortcutHandler, ShortcutHandler(run: performShortcut, enabled: shortcutEnabled))
        .sheet(isPresented: $showsShortcuts) { ShortcutSheet(library: libraryMode, isFujifilmRAF: editor.canUseCamera) }
        .onAppear { editor.library = library }
        .onChange(of: library.selectedPaths, initial: true) { editor.selectedLibraryPaths = library.selectedPaths }
        .alert("Couldn't save edits", isPresented: Binding(
            get: { editor.blockedSwitch != nil },
            set: { if !$0 { editor.cancelBlockedSwitch() } })) {
            Button("Discard Edits", role: .destructive) { editor.discardEditsAndOpenBlocked() }
            Button("Cancel", role: .cancel) { editor.cancelBlockedSwitch() }
        } message: { Text(editor.blockedSwitch?.message ?? "") }
        .sheet(item: $exportRequest) { request in ExportSheet(request: request) }
        .onChange(of: editor.openRevision) { libraryMode = false }
        .onChange(of: editor.cameraPanelRevision) { expansion.camera = true }
        .onChange(of: libraryMode) { if libraryMode { editor.cancelWhiteBalancePicker(); library.scan() } }
        .onChange(of: expansion.activeTools, initial: true) {
            coordinator.cropEditing = expansion.geometry
            if expansion.geometry { editor.cancelWhiteBalancePicker() }
            viewer.setCropEditing(expansion.geometry)
            editor.live()
            coordinator.scheduleSettle(editor.stack)
        }
    }

    /// Collapses sidebar + inspector on entry, restores their prior visibility on exit.
    func toggleFocus() {
        if focusMode {
            focusMode = false
            columnVisibility = preFocusColumnVisibility
            showInspector = preFocusShowInspector
        } else {
            preFocusColumnVisibility = columnVisibility
            preFocusShowInspector = showInspector
            focusMode = true
            columnVisibility = .detailOnly
            showInspector = false
        }
    }

    private func sendToPhone() {
        guard !blipBusy, BlipShare.isInstalled, let url = coordinator.sourceURL else { return }
        let item = ExportItem(source: url, stack: editor.stack, access: developAccess)
        blipBusy = true
        editor.statusLine = "Rendering for Blip..."
        Task {
            defer { blipBusy = false }
            do {
                let file = try await BlipShare.render(item)
                try BlipShare.handoff(file)
                editor.statusLine = "Sent to Blip"
            } catch { editor.statusLine = "Blip: \(error.localizedDescription)" }
        }
    }

    func presentExport() {
        do {
            let items: [ExportItem]
            if libraryMode {
                items = try library.rows.filter { library.selectedPaths.contains($0.path) }.map { row in
                    let url = URL(fileURLWithPath: row.path)
                    let saved = try Sidecar.load(forImageAt: url)
                    var stack = saved ?? EditStack.freshOpenDefault(for: url)
                    if coordinator.sourceURL == url { stack = editor.stack }
                    return ExportItem(source: url, stack: stack, access: library.access(for: row.path))
                }
            } else if let url = coordinator.sourceURL {
                items = [ExportItem(source: url, stack: editor.stack, access: developAccess)]
            } else { return }
            exportRequest = try ExportRequest(items: items, settings: ExportSettings())
        } catch { editor.statusLine = "Export: \(error)" }
    }

    private var statusBar: some View {
        HStack {
            Text(editor.statusLine)
                .font(StudioFont.body(11))
                .foregroundStyle(Studio.textSecondary)
                .lineLimit(1).truncationMode(.tail)
            Text(viewer.percent).font(StudioFont.numeric(11)).foregroundStyle(Studio.textSecondary)
            Spacer(minLength: 0)
            if !editor.stack.isNeutral {
                Text("EDITED").font(StudioFont.caption())
                    .foregroundStyle(Studio.warning)
            }
        }
        .lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, StudioMetrics.u(2))
        .padding(.vertical, StudioMetrics.u(1))
        .frame(minWidth: 0, maxWidth: .infinity)
        .studioSurface(fill: Studio.groupedPanel, corner: 0).clipped()
    }
}
