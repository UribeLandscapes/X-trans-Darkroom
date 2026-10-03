import Foundation
import CoreImage
import EditModel
import ImagingCore
import ImageCanvas

@MainActor
enum DevelopFeatureChecks {
    static func run(_ c: Checks) {
        c.suite("Settings section isolation") { c in
            let old = try JSONDecoder().decode(EditStack.self, from: Data(#"{"color":{"temperature":6100}}"#.utf8))
            c.expect(!old.color.blackAndWhite && old.color.temperature == 6100, "old color fields decode with Color treatment")
            var monochrome = EditStack(); monochrome.color.blackAndWhite = true
            c.expect(!monochrome.isNeutral, "B&W alone marks stack non-neutral")
            c.expect(try JSONDecoder().decode(EditStack.self, from: JSONEncoder().encode(monochrome)) == monochrome,
                     "B&W round-trips in sidecars")
            var source = EditStack()
            source.fingerprint = "source"; source.recipeID = "source recipe"
            source.light.exposure = 2
            source.curves.red = .identity.adding(.init(x: 0.5, y: 0.6))
            source.color.temperature = 7200; source.color.tint = 17
            source.color.vibrance = 8; source.color.blackAndWhite = true
            var band = HSLBand(); band.luminance = 25; source.hsl[.red] = band
            source.grading.shadowSaturation = 30
            source.effects.clarity = 22; source.detail.sharpenAmount = 40
            source.geometry.rotation = 1; source.optics.correctDistortion = false
            source.custom.glowAmount = 12; source.profileID = "profile"; source.cameraSettings = ["a": "b"]
            var destination = EditStack(); destination.fingerprint = "destination"; destination.recipeID = "destination recipe"
            let keys: [(EditStackSection, [String])] = [
                (.light, ["light"]), (.curve, ["curves"]), (.color, ["color"]), (.mix, ["hsl", "grading"]),
                (.effects, ["effects"]), (.detail, ["detail"]), (.geometry, ["geometry"]),
                (.optics, ["optics"]), (.custom, ["custom"]), (.profileCamera, ["profileID", "cameraSettings"])
            ]
            func dictionary(_ stack: EditStack) throws -> NSDictionary {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(stack)) as! NSDictionary
            }
            for (section, fields) in keys {
                let expected = try dictionary(destination).mutableCopy() as! NSMutableDictionary
                let values = try dictionary(source)
                for key in fields { expected[key] = values[key] }
                let result = destination.merging(source, sections: [section])
                c.expect(try dictionary(result) == expected, "\(section.rawValue) copies exactly its fields")
                c.expect(result.fingerprint == destination.fingerprint && result.recipeID == destination.recipeID,
                         "\(section.rawValue) retains destination identity and attribution")
            }
            c.expect(destination.merging(source, sections: []) == destination, "empty selection is identity")
            c.expect(!EditStackSections.standard.contains(.geometry) && EditStackSections.standard.count == 9,
                     "default copy excludes only Geometry")
            c.expect(!source.isNeutral && EditStack().isNeutral, "B&W default preserves neutral stack")
        }
        c.suite("Pure white balance optimizer") { c in
            let start = CFAbsoluteTimeGetCurrent()
            for (temperature, tint) in [(2350.0, -123.0), (6500, 17), (43000, 119), (2000, -150), (50000, 150)] {
                let result = WhiteBalanceSolver.solve { k, t in
                    SIMD3(exp(log(k/temperature)), exp((t-tint)/150), exp(-log(k/temperature)))
                }
                c.expect(abs(result.temperature/temperature-1) < 0.01 && abs(result.tint-tint) < 1,
                         "WB recovers \(temperature) K / \(tint): \(result.temperature) / \(result.tint)")
            }
            let ms = (CFAbsoluteTimeGetCurrent()-start)*1000/5
            c.expect(ms < 50, String(format: "pure WB solve averages %.3f ms", ms))
            let outside = WhiteBalanceSolver.solve { k, t in SIMD3(k/80000, exp((t-200)/150), 80000/k) }
            c.expect((2000...50000).contains(outside.temperature) && (-150...150).contains(outside.tint), "WB stays within manual ranges")
            let invalid = WhiteBalanceSolver.solve { _, _ in SIMD3(repeating: .nan) }
            c.expect(invalid.temperature.isFinite && invalid.tint.isFinite, "invalid evaluations never return NaN parameters")
            let viewport = CanvasViewport(imageSize: CGSize(width: 6000, height: 4000),
                viewSizePx: CGSize(width: 1200, height: 800), zoom: 0.2)
            let point = viewport.imagePoint(viewPoint: CGPoint(x: 300, y: 200))
            c.expect(point == CGPoint(x: 1500, y: 3000), "picker uses full-resolution bottom-left image coordinates")
        }
        c.suite("Clipping and B&W readback") { c in
            let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            func image(_ rgb: SIMD3<Float>, alpha: Float = 1) -> CIImage {
                let values: [Float] = [rgb.x*alpha, rgb.y*alpha, rgb.z*alpha, alpha]
                return CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: 16,
                               size: rect.size, format: .RGBAf, colorSpace: WorkingColorSpace.linearWide)
            }
            func read(_ image: CIImage) -> [Float] {
                var result = [Float](repeating: 0, count: 4)
                context.render(image, toBitmap: &result, rowBytes: 16, bounds: rect,
                               format: .RGBAf, colorSpace: WorkingColorSpace.linearWide)
                return result
            }
            for (level, expected) in [(Float(1.2), [Float(1), 0, 0]), (-0.1, [0, 0, 1]), (0.5, [0.5, 0.5, 0.5])] {
                let result = read(ClippingOverlay.applyDisplayValues(image(SIMD3(repeating: level))))
                c.expect(zip(result.prefix(3), expected).allSatisfy { abs($0-$1) < 1/1024 }, "clipping kernel \(level) → \(expected)")
            }
            for (rgb, expected) in [(SIMD3<Float>(0.1, 1, 0.1), [Float(1), 0, 0]),
                                    (SIMD3<Float>(0, 0, 0), [Float(0), 0, 1]),
                                    (SIMD3<Float>(-0.1, 0.4, 0.2), [Float(-0.1), 0.4, 0.2])] {
                let result = read(ClippingOverlay.applyDisplayValues(image(rgb)))
                c.expect(zip(result.prefix(3), expected).allSatisfy { abs($0-$1) < 1/1024 },
                         "clipping respects any-highlight / all-shadow boundaries: \(rgb)")
            }
            let source = image(SIMD3(0.8, 0.05, 0.1), alpha: 0.75)
            let pipeline = RenderPipeline()
            let input = DecodedFrameInput(image: source, asShotTemperature: 5500)
            let neutral = pipeline.render(input, stack: EditStack(), proxyRatio: 1)
            c.expect(read(neutral) == read(source), "B&W false is exact pixel identity")
            var stack = EditStack(); stack.color.blackAndWhite = true
            let mono = pipeline.render(input, stack: stack, proxyRatio: 1)
            let pixel = read(mono)
            c.expect(abs(pixel[0]-pixel[1]) < 1/1024 && abs(pixel[1]-pixel[2]) < 1/1024 && pixel[0] > 0.01,
                     "B&W saturated input becomes non-black equal RGB")
            c.expect(abs(pixel[3]-0.75) < 1/1024 && mono.extent == rect, "B&W preserves alpha and finite extent")
            stack.grading.shadowHue = 240; stack.grading.shadowSaturation = 80
            stack.grading.midtoneHue = 240; stack.grading.midtoneSaturation = 80
            let tinted = read(pipeline.render(input, stack: stack, proxyRatio: 1))
            c.expect(tinted[2] > tinted[0]+0.01, "grading still colours monochrome after conversion")
        }
        c.suite("Develop command wiring") { c in
            let root = Checks.repoRoot()
            func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent("Sources/"+path), encoding: .utf8) }
            let viewer = try source("App/ViewerState.swift")
            c.expect(viewer.contains("func toggleClipping() { showClipping.toggle() }"), "clipping flag toggles without touching EditStack")
            let keys = try source("App/DevelopKeys.swift")
            c.expect(keys.contains("window.firstResponder is NSTextInputClient") && keys.contains("window.attachedSheet == nil"),
                     "letter shortcuts yield to text input and sheets")
            let canvas = try source("App/CanvasArea.swift")
            c.expect(canvas.contains("showClipping: !before && viewer.showClipping"), "all Before panes omit display clipping")
        }
    }
}
