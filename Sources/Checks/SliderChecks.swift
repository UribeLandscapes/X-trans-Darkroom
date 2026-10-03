import Foundation
import EditModel
import StudioTheme

@MainActor
enum SliderChecks {
    static func run(_ c: Checks) {
        c.suite("Slider input and fresh-open defaults") { c in
            let cases: [(String, Double?)] = [
                ("+0.8", 0.8), ("-0,8", -0.8), (",8", 0.8), ("0,8", 0.8),
                (" 1.5 ", 1.5), ("abc", nil), ("999", 5), ("", nil),
                ("nan", nil), ("inf", nil), ("-999", -5)
            ]
            for (text, expected) in cases {
                c.expect(SliderValueParser.parse(text, range: -5...5) == expected, "parse/clamp: '\(text)'")
            }
            c.expect(EditStack.freshOpenDefault(for: URL(fileURLWithPath: "/photo.RAF")).detail.colorNR == 25,
                     "RAF opens with color NR 25")
            c.expect(EditStack.freshOpenDefault(for: URL(fileURLWithPath: "/photo.dng")).detail.colorNR == 25,
                     "DNG opens with color NR 25")
            c.expect(EditStack.freshOpenDefault(for: URL(fileURLWithPath: "/photo.jpg")) == EditStack(),
                     "JPEG opens with neutral stack")
            c.expect(SliderValueFormat.signedDecimal(2).string(0) == "0.00", "neutral exposure format")
            c.expect(SliderValueFormat.integer.string(0) == "0", "neutral integer format")
        }
    }
}
