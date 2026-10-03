import CoreImage
import CoreImage.CIFilterBuiltins
import ImagingCore
import EditModel
import RawDecode
import Profiles

extension RenderCoordinator {
    public func whiteBalance(at point: CGPoint, stack: EditStack) async -> WhiteBalanceSolver.Result? {
        guard let frame = fullFrame else { return nil }
        let samplePoint = CGPoint(x: point.x+frame.image.extent.minX, y: point.y+frame.image.extent.minY)
        guard frame.image.extent.contains(samplePoint) else { return nil }
        let profile = profileLibrary.resolve(identifier: stack.profileID, cameraModel: frame.metadata.cameraModel)
        let pipeline = self.pipeline, context = settleContext
        return await Task.detached(priority: .userInitiated) {
            WhiteBalanceSampling.solve(frame: frame, point: samplePoint, profile: profile, pipeline: pipeline, context: context)
        }.value
    }
}

private enum WhiteBalanceSampling {
    static func solve(frame: DecodedFrame, point: CGPoint, profile: CameraProfile?,
                      pipeline: RenderPipeline, context: CIContext) -> WhiteBalanceSolver.Result? {
        let extent = frame.image.extent
        let rect = CGRect(x: floor(point.x)-2, y: floor(point.y)-2, width: 5, height: 5).intersection(extent)
        // Average full-resolution decoded pixels at the WB INPUT, before any edits.
        let average = CIFilter.areaAverage()
        average.inputImage = frame.image
        average.extent = rect
        guard let patch = average.outputImage else { return nil }
        func read(_ image: CIImage) -> SIMD3<Double> {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 16,
                                 bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 format: .RGBAf, colorSpace: WorkingColorSpace.linearWide)
            return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
        }
        let rgb = read(patch)
        guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite, max(rgb.x, rgb.y, rgb.z) > 1e-8 else { return nil }
        let sample = CIImage(color: CIColor(red: rgb.x, green: rgb.y, blue: rgb.z,
                                           colorSpace: WorkingColorSpace.linearWide)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        return WhiteBalanceSolver.solve { temperature, tint in
            var color = ColorAdjustments(); color.temperature = temperature; color.tint = tint
            let balanced = pipeline.applyWhiteBalance(sample, color, asShot: frame.metadata.asShotTemperature)
            return read(pipeline.applyProfile(balanced, profile: profile, kelvin: temperature))
        }
    }
}
