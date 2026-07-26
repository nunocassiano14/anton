import AppKit
import UniformTypeIdentifiers

/// A native open panel is used instead of SwiftUI's `fileImporter` because
/// Anton's notch is intentionally a non-activating panel. `fileImporter`
/// silently fails to present from that kind of window on some macOS versions.
enum AttachmentPicker {
    static func present(completion: @escaping ([URL]) -> Void) {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Attach files"
        panel.message = "Choose files for the selected agent. Anton sends their local paths."
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        panel.begin { response in
            let urls = response == .OK ? panel.urls : []
            DispatchQueue.main.async {
                completion(urls)
            }
        }
    }
}
