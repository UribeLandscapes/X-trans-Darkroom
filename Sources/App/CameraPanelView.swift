import SwiftUI
import Recipes
import RecipeUI
import StudioTheme

struct CameraPanelView: View {
    @ObservedObject var editor: EditorModel
    private var panel: CameraPanelState { editor.cameraPanel }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera rendering approximations; not the camera’s own output.")
                .font(.caption).foregroundStyle(Studio.textSecondary)
            if editor.coordinator.asShotSettings == nil {
                Text("As-shot camera settings unavailable for this file.").font(.caption)
            }
            if !panel[.filmSimulation].isEmpty, editor.stack.profileID.isEmpty {
                Text("Film simulation preview needs a matching profile imported in Color. Other settings use the adjustment mapping.")
                    .font(.caption).foregroundStyle(Studio.warning)
            }
            if panel.monochrome {
                Text("WC/MG settings are retained; their rendering is not mapped yet.")
                    .font(.caption).foregroundStyle(Studio.textSecondary)
            }
            if let message = editor.cameraMessage { Text(message).font(.caption).foregroundStyle(Studio.warning) }
            StudioButton("Reset to shot settings") { editor.resetToShotSettings() }
                .disabled(editor.coordinator.asShotSettings == nil)
            Text("● Changed from shot · — Not recorded").font(.caption2).foregroundStyle(Studio.textSecondary)
            ForEach(CameraPanelState.fields, id: \.self) { field in
                row(field)
                    .disabled(!enabled(field) || !editor.coordinator.hasImage)
            }
            if let shot = editor.coordinator.asShotSettings {
                if let lmo = shot.lensModulationOptimizer {
                    Text("Shot lens modulation optimizer: \(lmo ? "On" : "Off")").font(.caption)
                }
                if let bias = shot.rawExposureBias {
                    Text("Shot RAW exposure bias: \(bias, specifier: "%.2f") EV").font(.caption)
                }
            }
        }
    }

    private func enabled(_ field: RecipeField) -> Bool {
        if [.monochromaticColorWC, .monochromaticColorMG, .color].contains(field) {
            return field == .color ? !panel.monochrome : panel.monochrome
        }
        if field == .wbKelvin { return Recipe.normalized(panel[.wbMode]) == "kelvin" }
        if field == .grainSize { return Recipe.normalized(panel[.grainEffect]) != "off" }
        return true
    }
    private func label(_ field: RecipeField) -> String {
        switch field {
        case .monochromaticColorWC: "Monochromatic Color WC"
        case .monochromaticColorMG: "Monochromatic Color MG"
        case .wbMode: "White Balance"
        case .wbKelvin: "WB Kelvin"
        case .wbShiftR: "WB Red shift"
        case .wbShiftB: "WB Blue shift"
        case .colorChromeFXBlue: "Color Chrome FX Blue"
        case .dRangePriority: "D Range Priority"
        case .exposureComp: "Exposure compensation"
        default: field.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    private func row(_ field: RecipeField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((panel.differs(field) ? "● " : "") + label(field))
                .font(.caption).foregroundStyle(panel.differs(field) ? Studio.warning : Studio.textPrimary)
                .help("Shot: " + (panel.asShot[field.rawValue] ?? "Not recorded"))
            HStack {
                Button("−") { step(field, direction: -1) }.disabled(next(field, -1) == nil)
                Spacer(minLength: 2)
                Text(display(panel[field])).font(.caption).monospacedDigit()
                Spacer(minLength: 2)
                Button("+") { step(field, direction: 1) }.disabled(next(field, 1) == nil)
            }
            .buttonStyle(.bordered)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label(field))
        }
        .padding(.vertical, 3)
    }
    private func display(_ value: String) -> String {
        if value.isEmpty { return "—" }
        if let n = Double(value) { return n.formatted(.number.precision(.fractionLength(0...2))) }
        return value
    }
    private func next(_ field: RecipeField, _ direction: Int) -> String? {
        if let choices = CameraPanelState.choices(for: field) {
            let raw = Recipe.normalized(panel[field])
            let value = field == .dynamicRange ? raw.replacingOccurrences(of: "dr", with: "") : raw
            guard let i = choices.firstIndex(where: { Recipe.simulationKey($0) == Recipe.simulationKey(value) }) else {
                return direction > 0 ? choices.first : choices.last
            }
            let j = i + direction
            return choices.indices.contains(j) ? choices[j] : nil
        }
        let constraint = Recipe.numericConstraints.first { $0.0 == field }
        let step = constraint?.2 ?? (1.0 / 3)
        let value = (Double(panel[field]) ?? 0) + Double(direction) * step
        guard (constraint?.1 ?? -5...5).contains(value) else { return nil }
        return String(value)
    }
    private func step(_ field: RecipeField, direction: Int) {
        if let value = next(field, direction) { editor.changeCamera(field, to: value) }
    }
}
