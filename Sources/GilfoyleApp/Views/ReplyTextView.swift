import AppKit
import SwiftUI

struct ReplyTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var autoFocus: Bool = false
    var onBeginEditing: () -> Void = {}
    var onPasteImage: (NSImage) -> Void = { _ in }
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = CommandTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.font = .systemFont(ofSize: 12.5)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        textView.onSubmit = { [weak coordinator = context.coordinator] value in
            coordinator?.parent.onSubmit(value)
        }
        textView.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCancel()
        }
        textView.onBeginEditing = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onBeginEditing()
        }
        textView.onPasteImage = { [weak coordinator = context.coordinator] image in
            coordinator?.parent.onPasteImage(image)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        if autoFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CommandTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.setAccessibilityPlaceholderValue(placeholder)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReplyTextView
        fileprivate weak var textView: CommandTextView?

        init(parent: ReplyTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            parent.text = textView?.string ?? ""
        }
    }
}

fileprivate final class CommandTextView: NSTextView {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onPasteImage: ((NSImage) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBeginEditing?()
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first
            ?? NSImage(pasteboard: pasteboard) {
            onPasteImage?(image)
            return
        }
        if let fileURL = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first,
           let image = NSImage(contentsOf: fileURL) {
            onPasteImage?(image)
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "v",
           modifiers.contains(.command) || modifiers.contains(.control) {
            paste(nil)
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                onSubmit?(string)
            }
            return
        }
        super.keyDown(with: event)
    }
}
