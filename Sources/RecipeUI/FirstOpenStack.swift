import Foundation
import RawDecode
import Recipes
import EditModel
import Profiles

/// The edit stack an unedited photo starts with. Develop open, Library export and
/// anything else that needs "what would opening this photo give me" share this one rule.
public enum FirstOpenStack {
    public struct Result {
        public let stack: EditStack
        /// Set when camera settings could not be resolved (e.g. profile missing); the
        /// stack is then the plain fresh-open default.
        public let error: Error?
    }

    public static func resolve(for url: URL, asShot: AsShotSettings?, isFujifilmRAF: Bool,
                               profiles: ProfileLibrary, context: RecipeApplication.Context,
                               cameraModel: String) -> Result {
        let base = EditStack.freshOpenDefault(for: url)
        guard isFujifilmRAF, let asShot else { return Result(stack: base, error: nil) }
        let panel = CameraPanelState(asShot: asShot, saved: nil)
        do {
            let stack = try panel.resolved(on: base, profiles: profiles, context: context,
                cameraModel: cameraModel, allowUnresolvedSimulation: true)
            return Result(stack: stack, error: nil)
        } catch { return Result(stack: base, error: error) }
    }
}

/// Builds the per-photo stacks for a Library export without touching the main actor.
/// Pure and synchronous so a detached task can run it; checks cancellation between photos.
public enum LibraryExportStacks {
    /// `current` is the photo already loaded in Develop: its live stack wins and nothing is
    /// read or decoded for it. Others use their sidecar, else the first-open treatment.
    /// A sidecar that fails to load throws, exactly as before.
    public static func resolve(urls: [URL], current: (url: URL, stack: EditStack)?,
                               profiles: ProfileLibrary) throws -> [EditStack] {
        try urls.map { url in
            try Task.checkCancellation()
            if let current, current.url == url { return current.stack }
            if let saved = try Sidecar.load(forImageAt: url) { return saved }
            return unopened(url, profiles: profiles)
        }
    }

    /// Only Fujifilm RAFs need a decode (for as-shot settings); others are cheap.
    public static func unopened(_ url: URL, profiles: ProfileLibrary) -> EditStack {
        let meta = CoreImageRawDecoder.readMetadata(url)
        guard meta.cameraSource.isFujifilmRAF,
              let frame = try? CoreImageRawDecoder().decode(url, scale: .atLeast(pixels: 512))
        else { return EditStack.freshOpenDefault(for: url) }
        return FirstOpenStack.resolve(for: url, asShot: frame.asShotSettings, isFujifilmRAF: true,
            profiles: profiles,
            context: .init(asShotTemperature: frame.metadata.asShotTemperature, asShotTint: frame.metadata.asShotTint),
            cameraModel: frame.metadata.cameraModel).stack
    }
}
