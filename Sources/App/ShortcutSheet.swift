import SwiftUI
import ShortcutLogic
import StudioTheme

struct ShortcutSheet: View {
    let library: Bool
    var isFujifilmRAF = false
    @Environment(\.dismiss) private var dismiss
    private var sections: [String] {
        let entries = ShortcutCatalog.entries
        let names = Array(Set(entries.map(\.section)))
        return names.sorted { left, right in
            let a = entries.contains { $0.section == left && $0.scope.active(library: library) }
            let b = entries.contains { $0.section == right && $0.scope.active(library: library) }
            return a == b ? left < right : a
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("E opens Develop; L toggles two Lights Out states (Lightroom has three). Import adds a folder. Space taps zoom; hold and drag pans.")
                .font(.callout).foregroundStyle(Studio.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.self) { section in
                        Text(section).font(.headline)
                        ForEach(ShortcutCatalog.entries.filter { $0.section == section }.sorted {
                            $0.scope.active(library: library) && !$1.scope.active(library: library)
                        }) { entry in
                            HStack {
                                Text(entry.title).foregroundStyle((entry.scope.active(library: library) && entry.enabledForCamera(isFujifilmRAF: isFujifilmRAF)) ? Studio.textPrimary : Studio.textSecondary)
                                Spacer()
                                Text(entry.caps).font(.system(.caption, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Studio.neutralSelection, in: RoundedRectangle(cornerRadius: 4))
                            }.disabled(!entry.enabledForCamera(isFujifilmRAF: isFujifilmRAF))
                        }
                    }
                    Text("Not available in X-Trans Darkroom").font(.headline)
                    ForEach(ShortcutCatalog.unavailable, id: \.self) { Text($0).foregroundStyle(Studio.textSecondary) }
                }.padding(.trailing, 8)
            }
        }.padding(24).frame(width: 620, height: 650).background(Studio.background)
    }
}
