import AppKit
import Foundation

/// Materialises pasted screenshots as local PNG files so the selected coding
/// agent can inspect the exact same file path Anton sends in the reply.
enum ScreenshotAttachmentStore {
    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Anton/Attachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Screenshot-\(UUID().uuidString.prefix(8)).png")
            try png.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
