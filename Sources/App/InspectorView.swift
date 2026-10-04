import SwiftUI
import EditModel
import ImageCanvas
import LibraryLogic
import StudioTheme

/// The trailing `.inspector` column. Library mode shows the selected image's metadata (moved
/// out of `LibraryView`'s old right panel); Develop mode shows the pinned histogram and
/// collapsible adjustment sections that used to live inline in `EditorView`.
///
/// Palette zoning (§9, hard rule): this column sits directly beside the photo, so - like
/// `CropOverlay`, `HistogramView`, etc. - it stays solid/opaque. No glass, no material
/// backgrounds. `StudioOverlayChecks` scans this file for both.
struct InspectorView: View {
    let libraryMode: Bool
    @ObservedObject var library: LibraryModel
    @ObservedObject var editor: EditorModel
    @ObservedObject var coordinator: RenderCoordinator
    var expansion: InspectorExpansion
    let focusMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            if libraryMode {
                ScrollView { metadataSection.padding(8) }
            } else {
                HistogramView(histogram: coordinator.histogram, viewer: editor.viewer).padding(8)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(InspectorTool.allCases.filter { $0 != .camera || editor.canUseCamera }, id: \.self) { tool in
                                InspectorSection(tool: tool, expanded: expansion[tool],
                                                 toggle: { expansion.toggle(tool) },
                                                 treatment: tool == .color ? Binding(get: { editor.stack.color.blackAndWhite },
                                                     set: { editor.setBlackAndWhite($0) }) : nil) {
                                    panel(tool)
                                }.id(tool)
                            }
                        }
                    }
                    .disabled(!coordinator.hasImage)
                    .onChange(of: expansion.geometry, initial: true) {
                        if expansion.geometry { withAnimation { proxy.scrollTo(InspectorTool.geometry, anchor: .top) } }
                    }
                    .onChange(of: editor.cameraPanelRevision) {
                        expansion.camera = true
                        withAnimation { proxy.scrollTo(InspectorTool.camera, anchor: .top) }
                    }
                }
            }
        }
        .environment(\.freshDefaults, EditStack.freshOpenDefault(for: coordinator.sourceURL))
        .background(focusMode ? Studio.surround(focused: true) : Studio.background)
    }

    @ViewBuilder private func panel(_ tool: InspectorTool) -> some View {
        switch tool {
        case .camera: CameraPanelView(editor: editor)
        case .light: lightPanel
        case .curve: curvePanel
        case .color: colorPanel
        case .mix: mixPanel
        case .effects: effectsPanel
        case .detail: detailPanel
        case .geometry: geometryPanel
        case .optics: opticsPanel
        case .custom: customPanel
        case .performance: performancePanel
        }
    }

    // MARK: Library metadata

    private var metadataSection: some View {
        StudioSection("Metadata") {
            if let row = library.selected {
                Text(row.filename).font(StudioFont.body()).textSelection(.enabled)
                metadata("Camera", row.cameraModel)
                metadata("Lens", row.lensModel)
                metadata("ISO", row.iso.map(String.init))
                metadata("Aperture", row.aperture.map { String(format: "f/%.1f", $0) })
                metadata("Shutter", row.shutter.map { $0 < 1 && $0 > 0 ? String(format: "1/%.0f s", 1 / $0) : String(format: "%.2f s", $0) })
                metadata("Capture", row.captureDate?.formatted())
                metadata("Dimensions", row.pixelWidth.flatMap { w in row.pixelHeight.map { "\(w) × \($0)" } })
                HStack(spacing: 8) {
                    StudioButton("Pick", icon: .flag) { library.annotate(.flag(1)) }
                    StudioButton("Reject", icon: .reject) { library.annotate(.flag(-1)) }
                }
                metadata("Rating / flag", "\(row.rating) / \(row.flag == 1 ? "Pick" : row.flag == -1 ? "Reject" : "Unflagged")")
                Text("Arrows: select · Enter: develop\n0–5: rating · P: pick · X: reject")
                    .font(StudioFont.body()).foregroundStyle(Studio.textSecondary)
            } else {
                Text("Select an image").font(StudioFont.body())
            }
        }
    }

    private func metadata(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(StudioFont.caption()).foregroundStyle(Studio.textSecondary)
            Text(value ?? "—").font(StudioFont.body()).textSelection(.enabled)
        }
    }

    // MARK: Develop panels

    private var lightPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            slider("Exposure", \.light.exposure, -5...5)
            slider("Contrast", \.light.contrast, -100...100)
            slider("Highlights", \.light.highlights, -100...100)
            slider("Shadows", \.light.shadows, -100...100)
            slider("Whites", \.light.whites, -100...100)
            slider("Blacks", \.light.blacks, -100...100)
        }
    }

    private var curvePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToneCurveView(
                curves: Binding(get: { editor.stack.curves },
                                set: { editor.stack.curves = $0 }),
                histogram: coordinator.histogram,
                onLive: { editor.live() },
                onCommit: { editor.commit() })
        }
    }

    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("White Balance Selector", systemImage: "eyedropper") { editor.toggleWhiteBalancePicker() }
                .buttonStyle(.plain).disabled(expansion.geometry)
                .help("W · Pick from a geometry-free preview. Unavailable while Geometry is expanded.")
            StudioButton(editor.cameraSource.brand == .fujifilm ? "Default / Neutral" : "Camera standard (Apple)", style: editor.stack.profileID.isEmpty ? .prominent : .bordered) { selectProfile("") }
            ForEach(coordinator.availableProfiles, id: \.identifier) { profile in
                StudioButton(profile.displayName, style: editor.stack.profileID == profile.identifier ? .prominent : .bordered) { selectProfile(profile.identifier) }
            }
            StudioButton("Import .dcp", icon: .import) { editor.importProfile() }
            slider("Temp", \.color.temperature, 2000...50000, neutral: 0)
            slider("Tint", \.color.tint, -150...150)
            slider("Vibrance", \.color.vibrance, -100...100)
            slider("Saturation", \.color.saturation, -100...100)
        }
    }

    private func selectProfile(_ identifier: String) {
        guard editor.stack.profileID != identifier else { return }
        editor.stack.profileID = identifier
        editor.live()
        editor.commit()
    }

    private var mixPanel: some View {
        VStack(spacing: StudioMetrics.u(1)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HSL / Color mixer").font(StudioFont.caption()).foregroundStyle(Studio.textSecondary)
                HSLMixView(mix: Binding(get: { editor.stack.hsl },
                                        set: { editor.stack.hsl = $0 }),
                           onLive: { editor.live() },
                           onCommit: { editor.commit() })
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Color grading").font(StudioFont.caption()).foregroundStyle(Studio.textSecondary)
                ColorGradingView(grading: Binding(get: { editor.stack.grading },
                                                  set: { editor.stack.grading = $0 }),
                                 onLive: { editor.live() },
                                 onCommit: { editor.commit() })
            }
        }
    }

    private var geometryPanel: some View {
        let size = coordinator.displayImage?.extent.size ?? coordinator.fullPixelSize
        let aspect = size.height > 0 ? Double(size.width / size.height) : 1.5
        return VStack(alignment: .leading, spacing: 6) {
            GeometryView(geometry: Binding(get: { editor.stack.geometry },
                                           set: { editor.stack.geometry = $0 }),
                         imageAspect: aspect,
                         onLive: { editor.live() },
                         onCommit: { editor.commit() })
        }
    }

    private var opticsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            OpticsView(optics: Binding(get: { editor.stack.optics },
                                       set: { editor.stack.optics = $0 }),
                       hasLensCorrection: coordinator.hasLensCorrection,
                       cameraSource: editor.cameraSource,
                       supportsBuiltIn: coordinator.metadata.supportsBuiltInLensCorrection,
                       lensModel: coordinator.metadata.lensModel,
                       onLive: { editor.live() },
                       onCommit: { editor.commit() })
        }
    }

    private var effectsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            slider("Texture", \.effects.texture, -100...100)
            slider("Clarity", \.effects.clarity, -100...100)
            slider("Dehaze", \.effects.dehaze, -100...100)
            Rectangle().fill(Studio.separator).frame(height: 1).padding(.vertical, 2)
            slider("Grain", \.effects.grainAmount, 0...100)
            slider("Grain size", \.effects.grainSize, 5...100, neutral: 25)
            Rectangle().fill(Studio.separator).frame(height: 1).padding(.vertical, 2)
            // Lightroom's convention: negative darkens the corners.
            slider("Vignette", \.effects.vignetteAmount, -100...100)
        }
    }

    private var customPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Glow").font(StudioFont.caption()).foregroundStyle(Studio.textSecondary)
            slider("Glow", \.custom.glowAmount, 0...100, format: .integer)
            slider("Radius", \.custom.glowRadius, 1...250, neutral: 60, format: .integer)
        }
    }

    private var detailPanel: some View {
        VStack(spacing: StudioMetrics.u(1)) {
            VStack(alignment: .leading, spacing: 6) {
                slider("Sharpening", \.detail.sharpenAmount, 0...150)
                slider("Radius", \.detail.sharpenRadius, 0.5...3, neutral: 1)
                Rectangle().fill(Studio.separator).frame(height: 1).padding(.vertical, 2)
                slider("Luminance NR", \.detail.luminanceNR, 0...100)
                slider("Color NR", \.detail.colorNR, 0...100)
            }
            HStack { Image(.oneToOne); Text("1:1 Detail") }
                .font(StudioFont.caption())
                .foregroundStyle(Studio.textPrimary)
            Text("One source pixel per display pixel. Drag the image to inspect another region.")
                .font(StudioFont.body(10))
                .foregroundStyle(Studio.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(StudioMetrics.u(1))
        }
    }

    /// Build plan §2 budgets, measured in-app. Instruments ships with Xcode, which is not
    /// installed here, so the app is its own instrument: this panel is the verification
    /// readout for the interactive (8.3 ms) and settle (350 ms) targets.
    private var performancePanel: some View {
        let live = FrameStats.shared.report(.interactive, budgetMS: RenderCoordinator.interactiveBudgetMS)
        let settle = FrameStats.shared.report(.settle, budgetMS: RenderCoordinator.settleBudgetMS)
        return VStack(alignment: .leading, spacing: 6) {
            statRow("live p50", live.p50, "ms")
            statRow("live p95", live.p95, "ms", warn: live.p95 > RenderCoordinator.interactiveBudgetMS)
            statRow("live max", live.max, "ms", warn: live.max > RenderCoordinator.interactiveBudgetMS)
            statRow("over 8.3ms", Double(live.overBudget), "/\(live.count)", warn: live.overBudget > 0)
            Rectangle().fill(Studio.separator).frame(height: 1).padding(.vertical, 2)
            statRow("settle p95", settle.p95, "ms", warn: settle.p95 > RenderCoordinator.settleBudgetMS)
            statRow("settle max", settle.max, "ms", warn: settle.max > RenderCoordinator.settleBudgetMS)
            StudioButton("Reset stats") { FrameStats.shared.reset() }
        }
    }

    private func statRow(_ label: String, _ value: Double, _ unit: String, warn: Bool = false) -> some View {
        HStack {
            Text(label).font(StudioFont.caption())
                .foregroundStyle(Studio.textSecondary)
            Spacer()
            Text(String(format: "%.2f", value) + unit)
                .font(StudioFont.numeric(11))
                .foregroundStyle(warn ? Studio.destructive : Studio.success)
        }
    }

    // MARK: Slider wiring

    private func slider(_ label: String,
                        _ path: WritableKeyPath<EditStack, Double>,
                        _ range: ClosedRange<Double>,
                        neutral: Double = 0,
                        format: SliderValueFormat? = nil) -> some View {
        StudioSlider(
            label,
            value: Binding(
                get: { editor.stack[keyPath: path] },
                set: { editor.stack[keyPath: path] = $0 }
            ),
            range: range,
            neutral: neutral,
            defaultValue: EditStack.freshOpenDefault(for: coordinator.sourceURL)[keyPath: path],
            format: format ?? (label == "Exposure" ? .signedDecimal(2) : label == "Radius" ? .signedDecimal(1) : label == "Temp" ? .kelvin : .integer),
            onLive: { _ in editor.live() },
            onCommit: { _ in editor.commit() }
        )
    }
}
