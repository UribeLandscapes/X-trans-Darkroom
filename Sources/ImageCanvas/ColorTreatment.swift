import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel

extension RenderPipeline {
    func applyTreatment(_ image: CIImage, stack: EditStack) -> CIImage {
        // Preserve the original combined cube exactly for Color treatment.
        guard stack.color.blackAndWhite else { return applyColorMix(image, stack.hsl, stack.grading) }
        let mixed = applyColorMix(image, stack.hsl, .neutral)
        let mono = CIFilter.colorMatrix()
        mono.inputImage = mixed
        // Y row of the working linear Rec. 2020 RGB-to-XYZ matrix.
        let y = CIVector(x: 0.2627, y: 0.6780, z: 0.0593, w: 0)
        mono.rVector = y; mono.gVector = y; mono.bVector = y
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let output = (mono.outputImage ?? mixed).cropped(to: image.extent)
        // Split toning follows monochrome, so grading can still introduce colour.
        return applyColorMix(output, .neutral, stack.grading)
    }
}
