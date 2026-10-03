import Foundation
import CoreImage
import ImagingCore
import EditModel
import ImageCanvas
import Profiles

enum ProfilePipelineChecks {
    static func run(_ c: Checks) {
        c.suite("Profile pipeline (Build plan section 4)") { c in
            let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])
            let cache = ProfileCubeCache()
            let pipeline = RenderPipeline(profileCubeCache: cache)
            func patch(_ rgb: SIMD3<Double>) -> CIImage {
                CIImage(color: CIColor(red: rgb.x, green: rgb.y, blue: rgb.z,
                                       colorSpace: WorkingColorSpace.linearWide)!)
                    .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            func sample(_ image: CIImage) -> [Float] {
                var values = [Float](repeating: 0, count: 8 * 8 * 4)
                context.render(image, toBitmap: &values, rowBytes: 8 * 4 * MemoryLayout<Float>.size,
                               bounds: image.extent, format: .RGBAf, colorSpace: WorkingColorSpace.linearWide)
                return values
            }
            func render(_ image: CIImage, _ profile: CameraProfile?, kelvin: Double = 5500,
                        stack: EditStack = EditStack()) -> [Float] {
                sample(pipeline.render(DecodedFrameInput(image: image, asShotTemperature: kelvin, profile: profile),
                                       stack: stack, proxyRatio: 1))
            }
            func rgb(_ values: [Float]) -> SIMD3<Double> { SIMD3(Double(values[0]), Double(values[1]), Double(values[2])) }
            func error(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
                (0..<3).map { abs(a[$0] - b[$0]) }.max()!
            }
            let neutralMatrix = ProfileMatrix([0.8, 0.1, 0.1, 0.2, 0.7, 0.1, 0.1, 0.2, 0.7])!
            let grey = rgb(render(patch(SIMD3(repeating: 0.18)), .neutral(matrix: neutralMatrix)))
            c.expect(error(grey, SIMD3(repeating: 0.18)) <= 1 / 255,
                     "neutral matrix grey=\(grey), expected=0.18, max error=\(error(grey, SIMD3(repeating: 0.18)))")

            let input = SIMD3<Double>(0.4, 0.2, 0.1)
            let image = patch(input)
            let matrix = ProfileMatrix([0.8, 0.1, 0.05, 0.1, 0.9, 0.1, 0.05, 0.2, 0.7])!
            var profile = CameraProfile.neutral(identifier: "matrix-check", matrix: matrix)
            let actual = rgb(render(image, profile))
            let expected = matrix.applied(to: input)
            let actualRatios = actual / SIMD3(repeating: max(actual.y, 1e-12))
            let expectedRatios = expected / SIMD3(repeating: expected.y)
            c.expect(error(actual, expected) < 0.001 && error(actualRatios, expectedRatios) < 0.005,
                     "matrix RGB=\(actual), expected=\(expected); ratios=\(actualRatios), expected=\(expectedRatios)")

            let otherMatrix = ProfileMatrix([0.7, 0.2, 0.05, 0.05, 0.8, 0.1, 0.1, 0.1, 0.8])!
            profile.colorMatrix2 = otherMatrix
            profile.calibrationIlluminant1 = 17; profile.calibrationIlluminant2 = 21
            let halfway = 2 / (1 / 2850.0 + 1 / 6500.0)
            let midpointExpected = (matrix.applied(to: input) + otherMatrix.applied(to: input)) / 2
            let midpoint = rgb(render(image, profile, kelvin: halfway))
            c.expect(error(midpoint, midpointExpected) < 0.001,
                     "as-shot reciprocal WB=\(halfway), RGB=\(midpoint), expected=\(midpointExpected)")
            var explicitWB = EditStack(); explicitWB.color.temperature = halfway
            let explicit = rgb(render(image, profile, kelvin: halfway, stack: explicitWB))
            c.expect(error(explicit, midpointExpected) < 0.001,
                     "explicit resolved WB=\(halfway), RGB=\(explicit), expected=\(midpointExpected)")
            profile.forwardMatrix1 = otherMatrix; profile.forwardMatrix2 = matrix
            let forward = rgb(render(image, profile, kelvin: 2850))
            c.expect(error(forward, otherMatrix.applied(to: input)) < 0.001,
                     "forward matrix precedence RGB=\(forward), expected=\(otherMatrix.applied(to: input))")

            func grid(_ hue: Double, _ saturation: Double = 1, _ value: Double = 1) -> ProfileGrid {
                ProfileGrid(hueDivisions: 1, saturationDivisions: 1, valueDivisions: 1,
                            entries: [SIMD3(hue, saturation, value)])!
            }
            var a = CameraProfile.neutral(identifier: "cube-a")
            a.profileHueSatMap1 = grid(60)
            a.profileLookTable = grid(0, 0.7)
            var b = CameraProfile.neutral(identifier: "cube-b")
            b.profileHueSatMap1 = grid(-60)
            b.profileLookTable = grid(0, 0.4)
            let first = render(image, a)
            let afterFirst = cache.rebuildCount
            let repeated = render(image, a)
            c.expect(first == repeated && cache.rebuildCount == afterFirst && afterFirst == 2,
                     "same profile rebuilds=\(afterFirst)→\(cache.rebuildCount), expected=2→2; exact pixels=\(first == repeated)")
            let switched = render(image, b)
            let back = render(image, a)
            let difference = error(rgb(first), rgb(switched))
            c.expect(difference > 1 / 255 && first == back && cache.rebuildCount == 4,
                     "A/B difference=\(difference), A/back exact=\(first == back), rebuilds=\(cache.rebuildCount)/4")

            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let library = ProfileLibrary(bundledDirectory: nil, userDirectory: dir)
            let unresolved = library.resolve(identifier: "", cameraModel: "Samsung NX")
            let untouched = render(image, unresolved)
            let baseline = sample(image)
            c.expect(unresolved == nil && untouched == baseline,
                     "empty ID defaults=\(library.profiles.count), exact pixels=\(untouched == baseline), input RGB=\(rgb(baseline)), output=\(rgb(untouched))")
            try Self.dcp(camera: "FUJIFILM X-T5", look: false).write(to: dir.appendingPathComponent("neutral.dcp"))
            try Self.dcp(camera: "FUJIFILM X-T5", look: true).write(to: dir.appendingPathComponent("film.dcp"))
            let populated = ProfileLibrary(bundledDirectory: nil, userDirectory: dir)
            let fuji = populated.profiles(for: "FUJIFILM X-T5")
            let film = fuji.first { $0.profileLookTable != nil }
            let fallback = populated.resolve(identifier: "missing", cameraModel: "FUJIFILM X-T5")
            c.expect(fuji.count == 2 && fallback?.profileLookTable == nil && fallback?.colorMatrix1 == .identity,
                     "matching profiles=\(fuji.count)/2, fallback matrix elements=\(fallback?.colorMatrix1?.elements.count ?? 0)/9, look tables=\(fallback?.profileLookTable == nil ? 0 : 1)/0")
            c.expect(film != nil && populated.resolve(identifier: film!.identifier, cameraModel: "FUJIFILM X-T5") == film,
                     "explicit profile resolved=\(populated.resolve(identifier: film?.identifier ?? "", cameraModel: "FUJIFILM X-T5")?.identifier ?? "nil")")
            c.expect(populated.profiles(for: "Samsung NX").isEmpty && populated.resolve(identifier: film?.identifier ?? "", cameraModel: "Samsung NX") == nil,
                     "Samsung picker matches=\(populated.profiles(for: "Samsung NX").count)/0; foreign selection defaults=0")
            c.expect(Array(RenderPipeline.stages.prefix(3)) == [.whiteBalance, .profile, .optics],
                     "executed stage prefix=\(Array(RenderPipeline.stages.prefix(3))), profile index=\(RenderPipeline.stages.firstIndex(of: .profile) ?? -1), optics index=\(RenderPipeline.stages.firstIndex(of: .optics) ?? -1)")

            var curve = CameraProfile.neutral(identifier: "curve-order", matrix: ProfileMatrix([0.8, 0, 0, 0, 0.8, 0, 0, 0, 0.8])!)
            curve.profileHueSatMap1 = grid(0, 1, 0.5)
            curve.profileToneCurve = ToneCurve(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 0.6)])
            curve.profileLookTable = grid(0, 1, 0.5)
            let curved = rgb(render(image, curve))
            let curveExpected = input * 0.1 + SIMD3(repeating: 0.05)
            c.expect(error(curved, curveExpected) < 0.001,
                     "matrix, HueSatMap, profile curve, LookTable RGB=\(curved), expected=\(curveExpected)")

            var dual = CameraProfile.neutral(identifier: "dual-cube")
            dual.calibrationIlluminant1 = 17; dual.calibrationIlluminant2 = 21
            dual.profileHueSatMap1 = grid(0, 1, 0.5); dual.profileHueSatMap2 = grid(0, 1, 1)
            let low = cache.cube(for: dual, kind: .hueSat, kelvin: 2850)
            let high = cache.cube(for: dual, kind: .hueSat, kelvin: 6500)
            let count = cache.rebuildCount
            let lowAgain = cache.cube(for: dual, kind: .hueSat, kelvin: 2850)
            c.expect(low != high && low == lowAgain && cache.rebuildCount == count,
                     "WB cube endpoint bytes differ=\(low != high), return exact=\(low == lowAgain), rebuilds=\(count)→\(cache.rebuildCount)")
            let midData = cache.cube(for: dual, kind: .hueSat, kelvin: halfway)!
            let floats = midData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let n = ProfileCubeCache.dimension
            let cubeIndex = ((4 * n + 8) * n + 16) * 4
            let cubeRGB = SIMD3<Double>(Double(floats[cubeIndex]), Double(floats[cubeIndex + 1]), Double(floats[cubeIndex + 2]))
            let cubeExpected = SIMD3<Double>(16, 8, 4) / Double(n - 1) * 0.75
            c.expect(error(cubeRGB, cubeExpected) < 1e-6,
                     "dual-map midpoint CPU cube RGB=\(cubeRGB), expected=\(cubeExpected)")
            let beforeChange = cache.rebuildCount
            dual.profileHueSatMap1 = grid(120)
            let changed = cache.cube(for: dual, kind: .hueSat, kelvin: 2850)
            c.expect(changed != low && cache.rebuildCount == beforeChange + 1,
                     "same-ID changed content invalidates cube, rebuilds=\(beforeChange)→\(cache.rebuildCount)")
        }
    }
    private static func dcp(camera: String, look: Bool) -> Data {
        func bytes(_ n: UInt32, _ count: Int = 4) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }
        }
        let matrix: [UInt32] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let model = Array((camera + "\0").utf8)
        var tags: [(UInt32, UInt32, UInt32, [UInt8])] = [
            (50708, 2, UInt32(model.count), model),
            (50721, 10, 9, matrix.flatMap { bytes($0) + bytes(1) })
        ]
        if look {
            tags += [(50981, 4, 3, bytes(1) + bytes(1) + bytes(1)),
                     (50982, 11, 3, [Float(30), 1, 1].flatMap { bytes($0.bitPattern) })]
        }
        var header: [UInt8] = [0x49, 0x49] + bytes(42, 2) + bytes(8) + bytes(UInt32(tags.count), 2)
        var payload: [UInt8] = []
        let start = 8 + 2 + tags.count * 12 + 4
        for (tag, type, count, data) in tags {
            header += bytes(tag, 2) + bytes(type, 2) + bytes(count) + bytes(UInt32(start + payload.count))
            payload += data
        }
        return Data(header + bytes(0) + payload)
    }

}
