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

    /// Like `resolve`, but a failing sidecar fails only that photo, so a batch (paste) can
    /// count failures per photo. Cancellation still throws for the whole batch.
    public static func resolveEach(urls: [URL], current: (url: URL, stack: EditStack)?,
                                   profiles: ProfileLibrary) throws -> [Swift.Result<EditStack, Error>] {
        try urls.map { url in
            try Task.checkCancellation()
            if let current, current.url == url { return .success(current.stack) }
            do {
                if let saved = try Sidecar.load(forImageAt: url) { return .success(saved) }
            } catch { return .failure(error) }
            return .success(unopened(url, profiles: profiles))
        }
    }

    /// Stack a paste merges into, decided at save time (not resolve time). Priority: the live
    /// editor stack for the open photo, then the sidecar as it is on disk now, and only then the
    /// stack resolved earlier (first-open treatment), so edits made while resolving survive.
    public static func pasteBase(resolved: Swift.Result<EditStack, Error>, live: EditStack?,
                                 saved: EditStack?) throws -> EditStack {
        if let live { return live }
        if let saved { return saved }
        return try resolved.get()
    }

    /// Live editor stack a paste may merge into: only for the open photo, and never while its
    /// sidecar is locked by a load failure (the caller then falls back to `load`, which fails).
    public static func liveStack(for url: URL, openURL: URL?, stack: EditStack, locked: Bool) -> EditStack? {
        guard !locked, let openURL, openURL.standardizedFileURL == url.standardizedFileURL else { return nil }
        return stack
    }

    /// Saves clipboard sections onto each destination. Stops with zero further writes once
    /// `isCancelled` is true, checked before every photo. Returns the stacks written and the failure count.
    public static func applyPaste(urls: [URL], resolved: [Swift.Result<EditStack, Error>],
                                  source: EditStack, sections: EditStackSections,
                                  live: (URL) -> EditStack?, load: (URL) throws -> EditStack?,
                                  save: (URL, EditStack) throws -> EditStack,
                                  isCancelled: () -> Bool) -> (written: [(url: URL, stack: EditStack)], failures: Int) {
        var written: [(url: URL, stack: EditStack)] = [], failures = 0
        for (url, result) in zip(urls, resolved) {
            if isCancelled() { break }
            do {
                let liveStack = live(url)
                let base = try pasteBase(resolved: result, live: liveStack, saved: liveStack == nil ? try load(url) : nil)
                written.append((url, try save(url, base.merging(source, sections: sections))))
            } catch { failures += 1 }
        }
        return (written, failures)
    }

    /// Only Fujifilm RAFs need a decode (for as-shot settings); others are cheap.
    public static func unopened(_ url: URL, profiles: ProfileLibrary) -> EditStack {
        let meta = CoreImageRawDecoder.readMetadata(url)
        guard meta.cameraSource.isFujifilmRAF,
              let frame = try? CoreImageRawDecoder().decode(url, scale: .atLeast(pixels: 512))
        else { return EditStack.freshOpenDefault(for: url) }
        return FirstOpenStack.resolve(frame: frame, for: url, profiles: profiles).stack
    }
}

public extension FirstOpenStack {
    /// First-open treatment from an already decoded frame, so callers that hold the frame
    /// (thumbnails) never decode twice. Non-Fuji frames carry no as-shot data and stay plain.
    static func resolve(frame: DecodedFrame, for url: URL, profiles: ProfileLibrary) -> Result {
        resolve(for: url, asShot: frame.asShotSettings, isFujifilmRAF: frame.asShotSettings != nil, profiles: profiles,
                context: .init(asShotTemperature: frame.metadata.asShotTemperature, asShotTint: frame.metadata.asShotTint),
                cameraModel: frame.metadata.cameraModel)
    }
}

/// Cache identity for Library thumbnails of photos that have no sidecar.
public enum ThumbnailEditKey {
    /// Bump when first-open resolution changes what an unedited photo looks like.
    static let firstOpenVersion = "firstopen-v1"

    /// A RAF without a sidecar renders with its as-shot first-open stack, which is only known
    /// after decoding, so the key cannot hash that stack. It hashes the plain default plus a
    /// versioned marker instead: stable for a given file (the as-shot data is a function of the
    /// file, whose fingerprint is already in the cache key) and different from the old
    /// plain-default key, so stale thumbnails are never reused.
    public static func editHash(sidecar: EditStack?, url: URL) -> String {
        if let sidecar { return sidecar.settingsHash }
        let plain = EditStack.freshOpenDefault(for: url).settingsHash
        return url.pathExtension.lowercased() == "raf" ? plain + "|" + firstOpenVersion : plain
    }
}
