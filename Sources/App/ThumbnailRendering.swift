import Foundation
import Catalog
import EditModel
import ImageCanvas
import Profiles
import RecipeUI

/// Both prefetch and visible cells must use the same edit-aware cache request.
enum ThumbnailRendering {
    static func thumbnail(_ row: ImageRecord, cache: ThumbnailCache) async throws -> URL {
        let source = URL(fileURLWithPath: row.path)
        let saved = try Sidecar.load(forImageAt: source)
        let stack = saved ?? .freshOpenDefault(for: source)
        let profiles = ProfileLibrary()
        // No sidecar: the photo shows its first-open (as-shot) look, resolved from the frame being rendered.
        return try await cache.thumbnail(for: source, fingerprint: row.fingerprint,
                                         editHash: ThumbnailEditKey.editHash(sidecar: saved, url: source), size: .grid,
                                         builtInLensCorrection: stack.optics.builtInLensCorrection) { frame in
            let stack = saved ?? FirstOpenStack.resolve(frame: frame, for: source, profiles: profiles).stack
            let input = DecodedFrameInput(image: frame.image, asShotTemperature: frame.metadata.asShotTemperature,
                lensCorrection: frame.lensCorrection,
                profile: profiles.resolve(identifier: stack.profileID, cameraModel: frame.metadata.cameraModel))
            let ratio = frame.image.extent.width / max(1, Double(row.pixelWidth ?? Int(frame.pixelSize.width)))
            return RenderPipeline().render(input, stack: stack, proxyRatio: min(1, ratio))
        }
    }
}
