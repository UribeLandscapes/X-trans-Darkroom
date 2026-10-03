import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel

extension RenderPipeline {
    // MARK: Stage 11 - Geometry

    /// Geometry runs last so grain, vignette and sharpening are all computed on the full
    /// uncropped frame and then cropped with it - cropping first would change what "corner"
    /// means to the vignette and re-scale the grain.
    ///
    /// Every parameter here is normalized or angular, so nothing needs proxy scaling.
    func applyGeometry(_ image: CIImage, _ geo: GeometryAdjustments) -> CIImage {
        guard !geo.isNeutral else { return image }
        var out = image
        var extent = out.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }

        // Orientation first: quarter turns and flips are lossless.
        if geo.rotation % 4 != 0 || geo.flipHorizontal || geo.flipVertical {
            var t = CGAffineTransform.identity
            if geo.flipHorizontal { t = t.scaledBy(x: -1, y: 1) }
            if geo.flipVertical { t = t.scaledBy(x: 1, y: -1) }
            t = t.rotated(by: CGFloat(Double(geo.rotation % 4) * .pi / 2))
            out = out.transformed(by: t)
            out = out.transformed(by: .init(translationX: -out.extent.origin.x,
                                            y: -out.extent.origin.y))
            extent = out.extent
        }

        if geo.perspectiveVertical != 0 || geo.perspectiveHorizontal != 0 {
            let w = extent.width, h = extent.height
            let v = CGFloat(geo.perspectiveVertical / 100) * w * 0.25
            let hz = CGFloat(geo.perspectiveHorizontal / 100) * h * 0.25
            let f = CIFilter.perspectiveTransform()
            f.inputImage = out
            f.topLeft     = CGPoint(x: extent.minX + v, y: extent.maxY - hz)
            f.topRight    = CGPoint(x: extent.maxX - v, y: extent.maxY + hz)
            f.bottomLeft  = CGPoint(x: extent.minX - v, y: extent.minY + hz)
            f.bottomRight = CGPoint(x: extent.maxX + v, y: extent.minY - hz)
            // Perspective moves corners beyond the frame; trim that expanded support
            // to the oriented frame before subsequent geometry computes its bounds.
            out = (f.outputImage ?? out).cropped(to: extent)
        }

        if geo.straightenAngle != 0 {
            let angle = CGFloat(geo.straightenAngle * .pi / 180)
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let t = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .translatedBy(x: -center.x, y: -center.y)
            out = out.transformed(by: t)

            // Trim to the largest inscribed rectangle so straightening never leaves
            // transparent wedges in the corners.
            let scale = GeometryAdjustments.autoCropScale(
                angleDegrees: geo.straightenAngle,
                aspect: Double(extent.width / extent.height))
            let w = extent.width * CGFloat(scale)
            let h = extent.height * CGFloat(scale)
            out = out.cropped(to: CGRect(x: center.x - w / 2, y: center.y - h / 2,
                                         width: w, height: h))
            extent = out.extent
        }

        if geo.transformScale != 1 {
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let t = CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: CGFloat(geo.transformScale), y: CGFloat(geo.transformScale))
                .translatedBy(x: -center.x, y: -center.y)
            out = out.transformed(by: t).cropped(to: extent)
        }

        if geo.hasCrop {
            let rect = CGRect(x: extent.minX + extent.width * CGFloat(geo.cropX),
                              y: extent.minY + extent.height * CGFloat(geo.cropY),
                              width: extent.width * CGFloat(geo.cropWidth),
                              height: extent.height * CGFloat(geo.cropHeight))
            out = out.cropped(to: rect)
        }

        // Re-origin so downstream code and the canvas always see an image at (0,0).
        return out.transformed(by: .init(translationX: -out.extent.origin.x,
                                         y: -out.extent.origin.y))
    }

    // MARK: Stage 6 - Effects (texture, clarity, dehaze)

    /// All three are local-contrast operations separated by the spatial frequency they act
    /// on, so every radius here is in the PIXEL domain and must be scaled for the proxy or
    /// the preview shows a different effect from the one that will be exported (§2).
    func applyEffects(_ image: CIImage, _ fx: EffectsAdjustments, proxyRatio: Double) -> CIImage {
        var out = image

        // Texture: high frequency only - fine detail, deliberately skips skin tones' larger
        // structures. Radius stays small.
        if fx.texture != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = out
            f.radius = Float(Self.textureRadius * proxyRatio)
            f.intensity = Float(fx.texture / 100.0)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        // Clarity: mid-frequency local contrast, a much larger radius than texture.
        if fx.clarity != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = out
            f.radius = Float(Self.clarityRadius * proxyRatio)
            f.intensity = Float(fx.clarity / 100.0 * 0.6)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        // Dehaze proper needs a dark-channel prior, which is a Phase 4+ item of its own.
        // This is an honest approximation: lift the black point, add contrast, and recover
        // the saturation haze removal reveals. It reads correctly on hazy landscapes and is
        // NOT a physically-based dehaze - flagged so nobody mistakes it for one.
        if fx.dehaze != 0 {
            let amount = fx.dehaze / 100.0
            let k = 1.0 + amount * 0.5
            let bias = -amount * 0.06
            let m = CIFilter.colorMatrix()
            m.inputImage = out
            m.rVector = CIVector(x: CGFloat(k), y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: CGFloat(k), z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: CGFloat(k), w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            m.biasVector = CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 0)
            // A biased CIColorMatrix yields infinite extent even with a finite input;
            // re-crop before subsequent filters consume that extent.
            out = (m.outputImage ?? out).cropped(to: image.extent)

            if amount > 0 {
                let v = CIFilter.vibrance()
                v.inputImage = out
                v.amount = Float(amount * 0.35)
                out = (v.outputImage ?? out).cropped(to: image.extent)
            }
        }

        return out
    }

    // MARK: Stage 9 - Detail (noise reduction, then sharpening)

    /// Order matters: sharpening before noise reduction amplifies the noise it is about to
    /// smooth. Both are pixel-domain and both are scaled for the proxy - and neither can be
    /// judged at proxy scale, which is why the canvas switches to a 1:1 crop when the Detail
    /// panel is open (§2).
    func applyDetail(_ image: CIImage, _ detail: DetailAdjustments, proxyRatio: Double) -> CIImage {
        var out = image

        if detail.luminanceNR > 0 || detail.colorNR > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = out
            f.noiseLevel = Float(detail.luminanceNR / 100.0 * 0.05)
            f.sharpness = Float(1.0 - detail.colorNR / 100.0 * 0.4)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        if detail.sharpenAmount != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = out
            f.radius = Float(detail.sharpenRadius * proxyRatio)
            f.intensity = Float(detail.sharpenAmount / 100.0)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        return out
    }

    // MARK: Stage 10 - Grain and vignette

    func applyGrainAndVignette(_ image: CIImage, _ fx: EffectsAdjustments, proxyRatio: Double) -> CIImage {
        var out = image
        let extent = out.extent

        if fx.grainAmount > 0, !extent.isInfinite {
            // Grain size is pixel domain: identical numbers must produce visually identical
            // grain at proxy and full resolution, so the noise is scaled, not re-sampled.
            let scale = fx.grainSize / 25.0 * proxyRatio
            let noise = CIFilter.randomGenerator().outputImage?
                .transformed(by: .init(scaleX: CGFloat(scale), y: CGFloat(scale)))
                .cropped(to: extent)
            if let noise {
                let mono = CIFilter.colorMatrix()
                mono.inputImage = noise
                let w = CGFloat(fx.grainAmount / 100.0 * 0.5)
                mono.rVector = CIVector(x: w, y: 0, z: 0, w: 0)
                mono.gVector = CIVector(x: w, y: 0, z: 0, w: 0)
                mono.bVector = CIVector(x: w, y: 0, z: 0, w: 0)
                mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
                mono.biasVector = CIVector(x: -w / 2, y: -w / 2, z: -w / 2, w: 1)
                // The non-zero bias makes CIColorMatrix infinite, undoing the random
                // generator's earlier crop. Re-crop before the addition unions extents.
                if let grain = mono.outputImage?.cropped(to: extent) {
                    let add = CIFilter.additionCompositing()
                    add.inputImage = grain
                    add.backgroundImage = out
                    out = (add.outputImage ?? out).cropped(to: extent)
                }
            }
        }

        if fx.vignetteAmount != 0, !extent.isInfinite {
            let f = CIFilter.vignetteEffect()
            f.inputImage = out
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            // Radius is a fraction of the frame, so it is normalized and needs no scaling.
            f.radius = Float(max(extent.width, extent.height) * 0.55)
            // Lightroom's convention: NEGATIVE darkens the corners, positive brightens them.
            // CIVignetteEffect darkens on positive intensity, so the sign is inverted here.
            f.intensity = Float(-fx.vignetteAmount / 100.0)
            f.falloff = 0.5
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        return out
    }

}
