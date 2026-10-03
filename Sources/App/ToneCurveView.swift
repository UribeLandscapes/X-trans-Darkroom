import SwiftUI
import EditModel
import ImageCanvas
import StudioTheme

/// Build plan §3, carried forward as modern chrome: an interactive curve editor drawn
/// smooth, plotting and editing real curve data. Click to add a point, drag to move,
/// double-click to remove.
struct ToneCurveView: View {
    @Binding var curves: ToneCurveSet
    let histogram: Histogram
    let onLive: () -> Void
    let onCommit: () -> Void

    @State private var channel: Channel = .composite
    @State private var draggingIndex: Int?

    enum Channel: String, CaseIterable {
        case composite = "RGB", red = "R", green = "G", blue = "B"
        var color: Color {
            switch self {
            case .composite: return Studio.textPrimary
            case .red: return Color(nsColor: .systemRed)
            case .green: return Color(nsColor: .systemGreen)
            case .blue: return Color(nsColor: .systemBlue)
            }
        }
    }

    private var curve: ToneCurve {
        get {
            switch channel {
            case .composite: return curves.composite
            case .red: return curves.red
            case .green: return curves.green
            case .blue: return curves.blue
            }
        }
        nonmutating set {
            switch channel {
            case .composite: curves.composite = newValue
            case .red: curves.red = newValue
            case .green: curves.green = newValue
            case .blue: curves.blue = newValue
            }
        }
    }

    var body: some View {
        VStack(spacing: StudioMetrics.u(1)) {
            channelPicker
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    grid(size)
                    curvePath(size)
                    handles(size)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size))
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: StudioMetrics.cornerControl, style: .continuous))
            .studioSurface(fill: Studio.sunken)

            HStack {
                Text(curve.isIdentity ? "Linear" : "\(curve.points.count) pts")
                    .font(StudioFont.numeric(10))
                    .foregroundStyle(curve.isIdentity ? Studio.textSecondary : Studio.accent)
                Spacer()
                StudioButton("Reset") {
                    curve = .identity
                    onLive(); onCommit()
                }
            }
        }
    }

    private var channelPicker: some View {
        HStack(spacing: 4) {
            ForEach(Channel.allCases, id: \.self) { ch in
                StudioChip(ch.rawValue, isSelected: channel == ch, tint: ch.color) { channel = ch }
            }
        }
    }

    // The histogram sits behind the curve so tonal decisions are made against the data,
    // the way it works in Lightroom. Chrome styling, real numbers.
    private func grid(_ size: CGSize) -> some View {
        Canvas { ctx, s in
            let bars = 64, step = Histogram.binCount / 64
            let w = s.width / CGFloat(bars)
            for i in 0..<bars {
                var peak: Float = 0
                for j in 0..<step { peak = max(peak, histogram.luma[i * step + j]) }
                let h = min(1, CGFloat(peak)) * s.height * 0.85
                guard h > 0.5 else { continue }
                ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: s.height - h, width: max(1, w - 1), height: h)),
                         with: .color(Studio.separator.opacity(0.5)))
            }
            for i in 1..<4 {
                let t = CGFloat(i) / 4
                ctx.stroke(Path { $0.move(to: .init(x: t * s.width, y: 0))
                                  $0.addLine(to: .init(x: t * s.width, y: s.height)) },
                           with: .color(Studio.separator.opacity(0.35)), lineWidth: 1)
                ctx.stroke(Path { $0.move(to: .init(x: 0, y: t * s.height))
                                  $0.addLine(to: .init(x: s.width, y: t * s.height)) },
                           with: .color(Studio.separator.opacity(0.35)), lineWidth: 1)
            }
            ctx.stroke(Path { $0.move(to: .init(x: 0, y: s.height)); $0.addLine(to: .init(x: s.width, y: 0)) },
                       with: .color(Studio.separator.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func curvePath(_ size: CGSize) -> some View {
        Canvas { ctx, s in
            var path = Path()
            let steps = 96
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let p = CGPoint(x: CGFloat(x) * s.width,
                                y: (1 - CGFloat(curve.value(at: x))) * s.height)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(channel.color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func handles(_ size: CGSize) -> some View {
        Canvas { ctx, s in
            for point in curve.points {
                let p = CGPoint(x: CGFloat(point.x) * s.width, y: (1 - CGFloat(point.y)) * s.height)
                let r: CGFloat = 4
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r + 1, y: p.y - r + 1, width: r * 2 - 2, height: r * 2 - 2)),
                         with: .color(channel.color))
            }
        }
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let x = min(max(g.location.x / size.width, 0), 1)
                let y = min(max(1 - g.location.y / size.height, 0), 1)

                if draggingIndex == nil {
                    // Grab a nearby handle, otherwise add a point where the user pressed.
                    let hit = curve.points.firstIndex {
                        abs($0.x - x) * size.width < 10 && abs($0.y - y) * size.height < 10
                    }
                    if let hit {
                        draggingIndex = hit
                    } else {
                        let updated = curve.adding(.init(x: x, y: y))
                        curve = updated
                        draggingIndex = updated.points.firstIndex { abs($0.x - x) < 0.005 }
                    }
                }
                if let i = draggingIndex {
                    curve = curve.moving(index: i, to: .init(x: x, y: y))
                    onLive()   // Continuous: proxy render only, no history entry.
                }
            }
            .onEnded { _ in
                draggingIndex = nil
                onCommit()     // Once: one undo entry, one settle render, one sidecar write.
            }
    }
}
