import Foundation

public enum WhiteBalanceSolver {
    public struct Result: Sendable {
        public let temperature: Double
        public let tint: Double
    }
    /// Deterministic coarse search in log Kelvin/tint, then bounded pattern refinement.
    /// About 300 cheap evaluations; no image, GPU, or global state in the optimizer.
    public static func solve(evaluate: (Double, Double) -> SIMD3<Double>) -> Result {
        let lower = log(2000.0), upper = log(50000.0)
        var best = SIMD2<Double>(lower, 0), cost = Double.infinity
        func score(_ p: SIMD2<Double>) -> Double {
            let rgb = evaluate(exp(p.x), p.y)
            guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { return .infinity }
            let norm = max(1e-12, abs(rgb.x)+abs(rgb.y)+abs(rgb.z))
            return (pow((rgb.x-rgb.y)/norm, 2)+pow((rgb.z-rgb.y)/norm, 2))
        }
        func consider(_ p: SIMD2<Double>) {
            let bounded = SIMD2<Double>(min(upper, max(lower, p.x)), min(150, max(-150, p.y)))
            let value = score(bounded)
            if value < cost { best = bounded; cost = value }
        }
        for x in 0...10 { for y in 0...6 {
            consider(SIMD2(lower+(upper-lower)*Double(x)/10, -150+Double(y)*50))
        } }
        var step = SIMD2<Double>((upper-lower)/10, 50)
        for _ in 0..<28 {
            let origin = best
            for x in -1...1 { for y in -1...1 where x != 0 || y != 0 {
                consider(origin + SIMD2(Double(x)*step.x, Double(y)*step.y))
            } }
            if best == origin { step *= 0.5 }
        }
        return Result(temperature: min(50000, max(2000, exp(best.x))), tint: best.y)
    }
}
