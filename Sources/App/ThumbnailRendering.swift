import Foundation
import Catalog
import EditModel
import ImageCanvas
import Profiles

/// Both prefetch and visible cells must use the same edit-aware cache request.
enum ThumbnailRendering {
    static func thumbnail(_ row: ImageRecord, cache: ThumbnailCache) async throws -> URL {
        let source = URL(fileURLWithPath: row.path)
        let stack = try Sidecar.load(forImageAt: source) ?? .freshOpenDefault(for: source)
        let profiles = ProfileLibrary()
        return try await cache.thumbnail(for: source, fingerprint: row.fingerprint,
                                         editHash: stack.settingsHash, size: .grid,
                                         builtInLensCorrection: stack.optics.builtInLensCorrection) { frame in
            let input = DecodedFrameInput(image: frame.image, asShotTemperature: frame.metadata.asShotTemperature,
                lensCorrection: frame.lensCorrection,
                profile: profiles.resolve(identifier: stack.profileID, cameraModel: frame.metadata.cameraModel))
            let ratio = frame.image.extent.width / max(1, Double(row.pixelWidth ?? Int(frame.pixelSize.width)))
            return RenderPipeline().render(input, stack: stack, proxyRatio: min(1, ratio))
        }
    }
}
