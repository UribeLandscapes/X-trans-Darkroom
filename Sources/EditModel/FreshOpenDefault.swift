import Foundation
import RawDecode

public extension EditStack {
    /// Keep the measurement-neutral stack separate from the initial RAW treatment.
    static func freshOpenDefault(for url: URL?) -> EditStack {
        var stack = EditStack()
        if let url, SupportedFormats.isRaw(url.pathExtension) {
            stack.detail.colorNR = 25
        }
        return stack
    }
}
