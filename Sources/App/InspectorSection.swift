import SwiftUI
import AppKit
import EditModel
import StudioTheme

enum InspectorTool: String, CaseIterable {
    case camera = "Camera"
    case light = "Light"
    case curve = "Curve"
    case color = "Color"
    case mix = "Mix"
    case effects = "Effects"
    case detail = "Detail"
    case geometry = "Geometry"
    case optics = "Optics"
    case custom = "Custom"
    case performance = "Performance"
}

/// Shared persisted expansion state also drives canvas tool behaviour.
struct InspectorExpansion: DynamicProperty {
    @AppStorage("inspector.camera.expanded") var camera = true
    @AppStorage("inspector.light.expanded") var light = false
    @AppStorage("inspector.curve.expanded") var curve = false
    @AppStorage("inspector.color.expanded") var color = false
    @AppStorage("inspector.mix.expanded") var mix = false
    @AppStorage("inspector.effects.expanded") var effects = false
    @AppStorage("inspector.detail.expanded") var detail = false
    @AppStorage("inspector.geometry.expanded") var geometry = false
    @AppStorage("inspector.optics.expanded") var optics = false
    @AppStorage("inspector.custom.expanded") var custom = false
    @AppStorage("inspector.performance.expanded") var performance = false

    subscript(tool: InspectorTool) -> Bool {
        get {
            switch tool {
            case .camera: camera
            case .light: light
            case .curve: curve
            case .color: color
            case .mix: mix
            case .effects: effects
            case .detail: detail
            case .geometry: geometry
            case .optics: optics
            case .custom: custom
            case .performance: performance
            }
        }
        nonmutating set {
            switch tool {
            case .camera: camera = newValue
            case .light: light = newValue
            case .curve: curve = newValue
            case .color: color = newValue
            case .mix: mix = newValue
            case .effects: effects = newValue
            case .detail: detail = newValue
            case .geometry: geometry = newValue
            case .optics: optics = newValue
            case .custom: custom = newValue
            case .performance: performance = newValue
            }
        }
    }

    var activeTools: Int { geometry ? 2 : 0 }

    func toggle(_ tool: InspectorTool) {
        if NSEvent.modifierFlags.contains(.option) {
            for other in InspectorTool.allCases { self[other] = other == tool }
        } else { self[tool].toggle() }
    }
}

struct InspectorSection<Content: View>: View {
    let tool: InspectorTool
    let expanded: Bool
    let toggle: () -> Void
    var treatment: Binding<Bool>? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.18), toggle) }) {
                HStack {
                    if tool == .custom { Image(.sparkles) }
                    Text(tool.rawValue).font(StudioFont.headline())
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
                .foregroundStyle(Studio.textPrimary)
                .padding(.horizontal, 10).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if let treatment {
                Picker("Treatment", selection: treatment) {
                    Text("Color").tag(false)
                    Text("B&W").tag(true)
                }.pickerStyle(.segmented).tint(Studio.textSecondary)
                    .frame(width: 110).padding(.trailing, 10)
            }
            }
            if expanded { content().padding(10) }
            Rectangle().fill(Studio.separator).frame(height: 0.5)
        }
    }
}

private struct FreshDefaultsKey: EnvironmentKey {
    static let defaultValue = EditStack.freshOpenDefault(for: nil)
}

extension EnvironmentValues {
    var freshDefaults: EditStack {
        get { self[FreshDefaultsKey.self] }
        set { self[FreshDefaultsKey.self] = newValue }
    }
}
