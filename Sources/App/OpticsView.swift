import SwiftUI
import EditModel
import RawDecode
import StudioTheme

/// Build plan §6: name the correction source so unavailable corrections are explicit.
struct OpticsView: View {
    @Binding var optics: OpticsAdjustments
    let hasLensCorrection: Bool
    let cameraSource: CameraSource
    let supportsBuiltIn: Bool
    let lensModel: String?
    let onLive: () -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudioMetrics.u(2)) {
            if let lensModel, !lensModel.isEmpty {
                Text(lensModel)
                    .font(StudioFont.body(11))
                    .foregroundStyle(Studio.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cameraSource.isFujifilmRAF {
                Text(hasLensCorrection ? "From camera" : "Manual - no profile for this lens")
                    .font(StudioFont.body(10))
                    .foregroundStyle(hasLensCorrection ? Studio.textSecondary : Studio.warning)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: StudioMetrics.u(2)) {
                    StudioToggle("Correct distortion", isOn: $optics.correctDistortion, onCommit: commitNow)
                    StudioToggle("Correct vignetting", isOn: $optics.correctVignetting, onCommit: commitNow)
                    StudioToggle("Remove chromatic aberration", isOn: $optics.removeChromaticAberration,
                                onCommit: commitNow)
                }
                .disabled(!hasLensCorrection)
            } else if cameraSource.isRaw && supportsBuiltIn {
                StudioToggle("Built-in lens correction", isOn: $optics.builtInLensCorrection, onCommit: commitNow)
            }
        }
    }

    private func commitNow() { onLive(); onCommit() }
}
