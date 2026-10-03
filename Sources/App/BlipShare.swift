import AppKit
import Export
import RawDecode

@MainActor
enum BlipShare {
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.blip.macos") != nil
    }

    static var symbol: String {
        NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: nil) != nil
            ? "iphone.and.arrow.forward" : "iphone"
    }

    nonisolated static func render(_ item: ExportItem) async throws -> URL {
        guard SupportedFormats.contains(item.source) else { throw RawDecodeError.unsupported(item.source) }
        return try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let folder = manager.temporaryDirectory.appendingPathComponent("XTransDarkroom-Blip", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let cutoff = Date().addingTimeInterval(-86_400)
            for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
                if let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date < cutoff { try? manager.removeItem(at: file) }
            }
            var request = ExportRequest(items: [item], destination: folder)
            request.options.jpegQuality = 95
            request.options.filename = .original
            request.options.collision = .overwrite
            // Default JPEG/sRGB/no resize and screen sharpening use the normal export path.
            let results = await ExportEngine().run(request)
            guard let output = results.first?.output else {
                throw ShareError.failed(results.first?.error ?? "Rendering produced no file")
            }
            return output
        }.value
    }

    static func handoff(_ file: URL) throws {
        if let service = NSSharingService.sharingServices(forItems: [file]).first(where: {
            $0.title.localizedCaseInsensitiveContains("Blip")
        }) {
            service.perform(withItems: [file])
            return
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([file as NSURL])
        guard NSPerformService("Blip…", pasteboard) else {
            throw ShareError.failed("Blip could not accept the file")
        }
    }

    private enum ShareError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): message }
        }
    }
}
