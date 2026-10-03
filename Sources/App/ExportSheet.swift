import SwiftUI
import AppKit
import Export
import ImagingCore
import StudioTheme

struct ExportSheet: View {
    @State var request: ExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var status = ""
    @State private var fraction = 0.0
    @State private var cancellation = ExportCancellation()
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export · \(request.items.count) files").font(StudioFont.headline())
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    StudioSection("Destination") {
                        Text(request.destination.path).font(StudioFont.body()).textSelection(.enabled)
                        if request.isOneOff { Text("This export only").font(StudioFont.caption()).foregroundStyle(Studio.warning) }
                        StudioButton("Choose folder", icon: .folder) { chooseFolder() }
                        StudioToggle("Make this my default", isOn: $request.makeDefault, onCommit: {})
                    }
                    StudioSection("File") {
                        choice("Format", $request.options.format, ExportFormat.allCases)
                        if request.options.format == .jpeg {
                            StudioSlider("Quality", value: $request.options.jpegQuality, range: 0...100, neutral: 90, format: .integer, onLive: { _ in }, onCommit: { _ in })
                        } else {
                            Menu("Bit depth: \(request.options.tiffDepth.rawValue)") {
                                Button("8 bit") { request.options.tiffDepth = .eight }
                                Button("16 bit") { request.options.tiffDepth = .sixteen }
                            }.font(StudioFont.body()).menuStyle(.borderlessButton)
                            choice("Compression", $request.options.tiffCompression, TIFFCompression.allCases)
                        }
                        Menu("Colour space: \(request.options.colorSpace.displayName)") {
                            ForEach(OutputColorSpace.allCases, id: \.self) { space in
                                Button(space.displayName) { request.options.colorSpace = space }
                            }
                        }.font(StudioFont.body()).menuStyle(.borderlessButton)
                        choice("Metadata", $request.options.metadata, MetadataPolicy.allCases)
                    }
                    StudioSection("Size and output sharpening") {
                        choice("Resize", $request.options.resize, ResizeMode.allCases)
                        if request.options.resize != .none {
                            TextField(request.options.resize == .megapixels ? "Megapixels" : "Pixels", value: $request.options.resizeValue, format: .number)
                                .textFieldStyle(.plain).padding(8).studioSurface(fill: Studio.sunken)
                            Text("Never upscale").font(StudioFont.body())
                        }
                        choice("Sharpening", $request.options.sharpening, OutputSharpening.allCases)
                        if request.options.sharpening != .none { choice("Amount", $request.options.sharpeningAmount, SharpeningAmount.allCases) }
                    }
                    StudioSection("Naming") {
                        choice("Filename", $request.options.filename, FilenamePolicy.allCases)
                        if request.options.filename == .suffix {
                            TextField("Suffix", text: $request.options.suffix).textFieldStyle(.plain).padding(8).studioSurface(fill: Studio.sunken)
                        }
                        if request.options.filename == .pattern {
                            TextField("Pattern", text: $request.options.pattern).textFieldStyle(.plain).padding(8).studioSurface(fill: Studio.sunken)
                            Text("Tokens: {name}, {index}").font(StudioFont.body())
                        }
                        choice("Existing file", $request.options.collision, CollisionPolicy.allCases)
                    }
                }.disabled(running)
            }
            if running { ProgressView(value: fraction).tint(Studio.accent) }
            Text(status).font(StudioFont.body()).textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer()
                StudioButton(running ? "Cancel export" : "Close") {
                    if running { cancellation.cancel(); status = "Cancelling…" } else { dismiss() }
                }
                StudioButton("Export", icon: .export, style: .prominent) { start() }.disabled(running || request.items.isEmpty)
            }
        }.padding(16).frame(width: 512, height: 720).foregroundStyle(Studio.textPrimary).background(Studio.background)
            .interactiveDismissDisabled(running)
            .onDisappear { cancellation.cancel(); task?.cancel() }
    }

    private func choice<T: RawRepresentable & Hashable>(_ label: String, _ value: Binding<T>, _ cases: [T]) -> some View where T.RawValue == String {
        Menu("\(label): \(value.wrappedValue.rawValue)") {
            ForEach(cases, id: \.self) { item in Button(item.rawValue) { value.wrappedValue = item } }
        }.font(StudioFont.body()).menuStyle(.borderlessButton).padding(8).studioSurface(fill: Studio.elevated)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = request.destination
        if panel.runModal() == .OK, let url = panel.url { request.destination = url }
    }
    private func start() {
        do {
            for (index, item) in request.items.enumerated() { _ = try request.options.basename(source: item.source, index: index + 1) }
            try ExportSettings().accept(request)
        } catch { status = "Export settings: \(error)"; return }
        running = true; fraction = 0; cancellation = ExportCancellation()
        let snapshot = request, token = cancellation
        task = Task {
            let results = await ExportEngine().run(snapshot, cancellation: token) { progress in
                await MainActor.run {
                    fraction = (Double(progress.index) + progress.fraction) / Double(max(1, progress.total))
                    status = "\(progress.index + 1)/\(progress.total) · \(progress.filename) · \(Int(progress.fraction * 100))%"
                }
            }
            let written = results.filter { $0.output != nil }.count
            let errors = results.compactMap(\.error)
            status = "\(written) written · \(results.filter { $0.output == nil && $0.error == nil }.count) skipped · \(errors.count) failed" + (results.count < snapshot.items.count ? " · Cancelled" : "")
            if !errors.isEmpty { status += "\n" + errors.joined(separator: "\n") }
            running = false
        }
    }
}
