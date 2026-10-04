import CoreImage
import EditModel

/// Highlights / Whites / Blacks as smooth, luminance-weighted tone moves.
///
/// Every operation is identity at 0, continuous and monotonic in luminance, and none of
/// them clamps, so detail near either end is bent rather than flattened. Masks are built
/// on sqrt(luminance), a cheap stand-in for perceptual lightness, so the weighting falls
/// where the eye expects it even though the working space is linear light. Middle grey
/// (18% linear, sqrt = 0.42) sits below every highlight/whites mask start and above the
/// blacks falloff, which is what keeps it stable.
extension RenderPipeline {

    /// Stops applied at slider +/-100. Recovery is stronger than boost: boosting pushes
    /// values toward display white where headroom is limited.
    static let highlightRecoverStops = 1.0
    static let highlightBoostStops = 0.5
    static let whitesLowerStops = 0.5
    /// Whites boost strength; must stay below 1 so the curve keeps a positive slope at white.
    static let whitesBoostStrength = 0.8
    static let blacksDeepenStops = 1.0
    /// Linear-light lift of true black at Blacks +100, and the luminance scale it falls off over.
    /// Lift must stay below the scale or the curve would fold back on itself.
    static let blacksLiftLinear = 0.02
    static let blacksLiftFalloff = 0.06

    private static let toneKernel: CIColorKernel? = {
        // Runtime CIKL compilation, cached once, as in GlowStage.
        let source = """
        float lumaOf(vec3 c) { return max(dot(c, vec3(0.2627, 0.6780, 0.0593)), 0.0); }
        float lightnessOf(vec3 c) { return sqrt(min(lumaOf(c), 1.0)); }
        kernel vec4 applyTone(__sample s, float hiStops, float whiteLower, float whiteBoost,
                              float blackDeepen, float blackLift, float liftFalloff) {
            vec3 c = s.rgb;
            // Highlights: signed exposure weighted toward the bright end.
            c *= exp2(hiStops * smoothstep(0.45, 1.0, lightnessOf(c)));
            // Whites: lower = gain at the top; boost = lift that vanishes at exactly white.
            float l = lumaOf(c);
            float topMask = min(l, 1.0) * min(l, 1.0);
            c *= exp2(-whiteLower * topMask);
            l = lumaOf(c);
            topMask = min(l, 1.0) * min(l, 1.0);
            c *= 1.0 + whiteBoost * topMask * max(1.0 - l, 0.0);
            // Blacks: deepen scales darks down (zero stays zero); lift adds a fading pedestal.
            float bottomMask = pow(1.0 - lightnessOf(c), 6.0);
            c *= exp2(-blackDeepen * bottomMask);
            float lowLuma = lumaOf(c);
            c = c + blackLift * exp(-lowLuma / liftFalloff);
            return vec4(c, s.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    func applyTone(_ image: CIImage, highlights: Double, whites: Double, blacks: Double) -> CIImage {
        guard highlights != 0 || whites != 0 || blacks != 0, let kernel = Self.toneKernel else { return image }
        let h = highlights / 100, w = whites / 100, b = blacks / 100
        let hiStops = h < 0 ? h * Self.highlightRecoverStops : h * Self.highlightBoostStops
        let args: [Any] = [
            hiStops,
            max(0, -w) * Self.whitesLowerStops,
            max(0, w) * Self.whitesBoostStrength,
            max(0, -b) * Self.blacksDeepenStops,
            max(0, b) * Self.blacksLiftLinear,
            Self.blacksLiftFalloff,
        ].map { Float($0) as Any }
        guard let out = kernel.apply(extent: image.extent, arguments: [image] + args) else { return image }
        return out.cropped(to: image.extent)
    }
}
