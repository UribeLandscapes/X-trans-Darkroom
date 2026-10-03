import SwiftUI
import LibraryLogic
import StudioTheme

/// Library sources sidebar: folder roots (moved out of `LibraryView`'s old right panel) plus a
/// Recipes shortcut into the existing recipe-browser sheet. A native `List` in `.sidebar` style
/// picks up macOS 26 Liquid Glass automatically - no `chromeGlass` call needed here.
struct SidebarView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var editor: EditorModel

    var body: some View {
        List {
            Section("Folders") {
                ForEach(library.roots, id: \.self) { root in
                    Label(root.lastPathComponent, systemImage: StudioIcon.folder.symbolName)
                        .help(root.path)
                        .contextMenu {
                            Button("Remove", role: .destructive) { library.removeRoot(root) }
                        }
                }
                Button { library.addFolder() } label: {
                    Label("Add folder", systemImage: StudioIcon.folder.symbolName)
                }
                Button { library.scan() } label: {
                    Label("Rescan", systemImage: StudioIcon.redo.symbolName)
                }
            }
            Section {
                Button { editor.showsRecipes = true } label: {
                    Label("Recipes", systemImage: "list.bullet.rectangle")
                }
            }
            if let error = library.error {
                Section {
                    Text(error).font(StudioFont.caption()).foregroundStyle(Studio.destructive)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
    }
}
