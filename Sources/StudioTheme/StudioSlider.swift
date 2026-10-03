import SwiftUI

public enum SliderValueParser {
    public static func parse(_ text: String, range: ClosedRange<Double>) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

public enum SliderValueFormat {
    case signedDecimal(Int), integer, kelvin, percent

    public func string(_ value: Double) -> String {
        switch self {
        case .signedDecimal(let places):
            return String(format: value == 0 ? "%.*f" : "%+.*f", places, value)
        case .integer, .kelvin: return String(format: "%.0f", value)
        case .percent: return String(format: "%.0f%%", value * 100)
        }
    }

    private var multiplier: Double {
        if case .percent = self { return 100 }
        return 1
    }

    func editingString(_ value: Double) -> String { String(value * multiplier) }

    func parse(_ text: String, range: ClosedRange<Double>) -> Double? {
        SliderValueParser.parse(text, range: (range.lowerBound * multiplier)...(range.upperBound * multiplier))
            .map { $0 / multiplier }
    }
}

/// Live changes bypass history; every completed gesture or valid field edit commits once.
public struct StudioSlider: View {
    let label: String
    let range: ClosedRange<Double>
    let neutral: Double
    let defaultValue: Double
    let format: SliderValueFormat
    let showsValue: Bool
    @Binding var value: Double
    let onLive: (Double) -> Void
    let onCommit: (Double) -> Void
    @Environment(\.sliderKeyboard) private var keyboard
    @Environment(\.sliderKeyboardCommit) private var keyboardCommit
    @State private var keyboardID = UUID()
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    public init(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                neutral: Double = 0, showsValue: Bool = true,
                defaultValue: Double? = nil, format: SliderValueFormat = .signedDecimal(2),
                onLive: @escaping (Double) -> Void, onCommit: @escaping (Double) -> Void) {
        self.label = label; self._value = value; self.range = range
        self.neutral = neutral; self.showsValue = showsValue
        self.defaultValue = defaultValue ?? neutral; self.format = format
        self.onLive = onLive; self.onCommit = onCommit
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(label).font(StudioFont.caption())
                .foregroundStyle(Studio.textSecondary)
                .frame(width: 76, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: reset)
            GeometryReader { geo in
                let width = max(1, geo.size.width - 10)
                let fraction = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
                ZStack(alignment: .leading) {
                    Rectangle().fill(Studio.separator).frame(height: 2)
                    if range.lowerBound < neutral && neutral < range.upperBound {
                        Rectangle().fill(Studio.textTertiary).frame(width: 1, height: 6)
                            .offset(x: 5 + (neutral - range.lowerBound) / (range.upperBound - range.lowerBound) * width)
                    }
                    Circle().fill(Studio.textSecondary).frame(width: 10, height: 10)
                        .offset(x: fraction * width)
                }
                .frame(height: 22).contentShape(Rectangle())
                // A movement threshold lets a double click reset without two drag commits.
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { gesture in
                        let fraction = min(1, max(0, (gesture.location.x - 5) / width))
                        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                        onLive(value)
                    }
                    .onEnded { _ in onCommit(value) })
                .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
            }
            if showsValue { valueField.frame(width: 49) }
        }
        .frame(height: 22)
        .background {
            if let keyboard { SliderKeyboardHighlight(keyboard: keyboard, id: keyboardID) }
        }
        .background {
            GeometryReader { geo in
                Color.clear.onChange(of: geo.frame(in: .global).minY, initial: true) {
                    keyboard?.register(keyboardID, y: geo.frame(in: .global).minY) { amount in
                        value = min(range.upperBound, max(range.lowerBound,
                            value + Double(amount) * (range.upperBound - range.lowerBound) / 100))
                        onLive(value)
                        if let keyboardCommit { keyboardCommit(keyboardID.uuidString) }
                        else { onCommit(value) }
                    }
                }
            }
        }
        .onDisappear { keyboard?.remove(keyboardID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var valueField: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.plain).font(StudioFont.numeric(11))
                .multilineTextAlignment(.trailing).focused($focused)
                .onSubmit { finish() }
                .onExitCommand { editing = false; focused = false }
                .onChange(of: focused) { if !focused { finish() } }
                .onAppear { focused = true }
        } else {
            Button {
                draft = format.editingString(value); editing = true
            } label: {
                Text(format.string(value)).font(StudioFont.numeric(11))
                    .foregroundStyle(Studio.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private func finish() {
        guard editing else { return }
        editing = false; focused = false
        guard let parsed = format.parse(draft, range: range) else { return }
        value = parsed; onLive(parsed); onCommit(parsed)
    }

    private func reset() {
        editing = false; focused = false
        // Temperature's zero is an as-shot sentinel outside its manual Kelvin range.
        value = defaultValue; onLive(defaultValue); onCommit(defaultValue)
    }
}
