import AppKit
import GilfoyleCore
import SwiftUI

/// One native text surface for the complete agent reply. A SwiftUI stack of
/// individually selectable `Text` views traps selection inside one paragraph;
/// NSTextView keeps Markdown styling while allowing a drag to cross paragraphs,
/// list items, code, tables, and wrapped lines.
struct MarkdownResponseView: View {
    let markdown: String

    var body: some View {
        SelectableMarkdownTextView(markdown: markdown)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SelectableMarkdownTextView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 1)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.setAccessibilityLabel("Agent response")
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard context.coordinator.renderedMarkdown != markdown else { return }
        let priorSelection = textView.selectedRange()
        textView.textStorage?.setAttributedString(
            MarkdownTextRenderer.render(markdown)
        )
        context.coordinator.renderedMarkdown = markdown

        if priorSelection.location != NSNotFound,
           NSMaxRange(priorSelection) <= textView.string.utf16.count {
            textView.setSelectedRange(priorSelection)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        // A vertically scrolling parent can make its first fitting proposal
        // without a width. Measuring at one point wraps every character and
        // leaves the actual reply far outside the visible callout viewport.
        // Use the view's established width, or a conservative callout width
        // for that first pass; SwiftUI proposes the exact width on the next.
        let width = max(
            320,
            proposal.width ?? max(320, textView.bounds.width)
        )
        textView.setFrameSize(
            NSSize(width: width, height: max(1, textView.frame.height))
        )
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else {
            return CGSize(width: width, height: 1)
        }
        textContainer.containerSize = NSSize(width: width, height: 1_000_000)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(
            width: width,
            height: max(1, ceil(used.height + textView.textContainerInset.height * 2))
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var renderedMarkdown: String?

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            let url: URL?
            if let value = link as? URL {
                url = value
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

private enum MarkdownTextRenderer {
    private static let bodyColor = NSColor.white.withAlphaComponent(0.66)
    private static let strongColor = NSColor.white.withAlphaComponent(0.90)
    private static let secondaryColor = NSColor.white.withAlphaComponent(0.62)
    private static let codeColor = NSColor.white.withAlphaComponent(0.74)
    private static let bodyFont = NSFont.systemFont(ofSize: 11.7)
    private static let monoFont = NSFont.monospacedSystemFont(
        ofSize: 10.5,
        weight: .regular
    )

    static func render(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let blocks = MarkdownBlockParser.parse(markdown)

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n\n"))
            }
            append(block, to: output)
        }
        return output
    }

    private static func append(
        _ block: MarkdownBlockParser.Block,
        to output: NSMutableAttributedString
    ) {
        switch block {
        case let .heading(level, value):
            let font = NSFont.systemFont(
                ofSize: level == 1 ? 14.5 : 12.5,
                weight: .semibold
            )
            let start = output.length
            output.append(inline(value, font: font, color: strongColor))
            applyParagraphStyle(
                to: output,
                range: NSRange(location: start, length: output.length - start),
                lineSpacing: 2
            )

        case let .text(value):
            let start = output.length
            output.append(inline(value, font: bodyFont, color: bodyColor))
            applyParagraphStyle(
                to: output,
                range: NSRange(location: start, length: output.length - start),
                lineSpacing: 2
            )

        case let .list(items, ordered, start):
            appendList(
                items: items,
                ordered: ordered,
                start: start,
                to: output
            )

        case let .code(value):
            let start = output.length
            output.append(
                NSAttributedString(
                    string: value,
                    attributes: [
                        .font: monoFont,
                        .foregroundColor: codeColor,
                        .backgroundColor: NSColor.white.withAlphaComponent(0.055)
                    ]
                )
            )
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.firstLineHeadIndent = 8
            style.headIndent = 8
            style.tailIndent = -8
            output.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: start, length: output.length - start)
            )

        case let .table(headers, rows):
            appendTable(headers: headers, rows: rows, to: output)

        case let .image(path, alt):
            appendImage(path: path, alt: alt, to: output)
        }
    }

    private static func appendList(
        items: [String],
        ordered: Bool,
        start: Int,
        to output: NSMutableAttributedString
    ) {
        let markerFont = NSFont.monospacedSystemFont(
            ofSize: 11.7,
            weight: .semibold
        )
        for index in items.indices {
            if index > 0 {
                output.append(NSAttributedString(string: "\n"))
            }
            let rowStart = output.length
            let marker = ordered ? "\(start + index)." : "•"
            output.append(
                NSAttributedString(
                    string: "\(marker)\t",
                    attributes: [
                        .font: markerFont,
                        .foregroundColor: secondaryColor
                    ]
                )
            )
            output.append(inline(items[index], font: bodyFont, color: bodyColor))

            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = index == items.indices.last ? 0 : 5
            style.firstLineHeadIndent = 0
            style.headIndent = ordered ? 26 : 18
            style.tabStops = [
                NSTextTab(
                    textAlignment: .left,
                    location: ordered ? 26 : 18
                )
            ]
            output.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(
                    location: rowStart,
                    length: output.length - rowStart
                )
            )
        }
    }

    private static func appendTable(
        headers: [String],
        rows: [[String]],
        to output: NSMutableAttributedString
    ) {
        let columnCount = max(
            headers.count,
            rows.map(\.count).max() ?? 0
        )
        guard columnCount > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 5
        style.tabStops = (1..<columnCount).map {
            NSTextTab(textAlignment: .left, location: CGFloat($0) * 150)
        }

        func appendRow(_ cells: [String], isHeader: Bool) {
            let rowStart = output.length
            for column in 0..<columnCount {
                if column > 0 {
                    output.append(NSAttributedString(string: "\t"))
                }
                let value = column < cells.count ? cells[column] : ""
                output.append(
                    inline(
                        value,
                        font: NSFont.systemFont(
                            ofSize: 10.5,
                            weight: isHeader ? .semibold : .regular
                        ),
                        color: NSColor.white.withAlphaComponent(
                            isHeader ? 0.80 : 0.60
                        )
                    )
                )
            }
            output.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(
                    location: rowStart,
                    length: output.length - rowStart
                )
            )
        }

        appendRow(headers, isHeader: true)
        for row in rows {
            output.append(NSAttributedString(string: "\n"))
            appendRow(row, isHeader: false)
        }
    }

    private static func appendImage(
        path: String,
        alt: String,
        to output: NSMutableAttributedString
    ) {
        guard let image = localImage(at: path) else {
            let label = alt.isEmpty ? "Image unavailable" : alt
            output.append(
                NSAttributedString(
                    string: "▧ \(label)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10.5),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.45)
                    ]
                )
            )
            return
        }

        let maxWidth: CGFloat = 520
        let scale = min(1, maxWidth / max(1, image.size.width))
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: 0,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        output.append(NSAttributedString(attachment: attachment))
    }

    private static func inline(
        _ source: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let parsed: NSAttributedString
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            parsed = NSAttributedString(attributed)
        } else {
            parsed = NSAttributedString(string: source)
        }

        let result = NSMutableAttributedString(attributedString: parsed)
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes(
            [
                .font: font,
                .foregroundColor: color
            ],
            range: fullRange
        )

        let intentKey = NSAttributedString.Key("NSInlinePresentationIntent")
        result.enumerateAttribute(
            intentKey,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard let rawValue = value as? NSNumber else { return }
            let raw = rawValue.intValue
            var renderedFont = font
            if raw & 8 != 0 {
                renderedFont = NSFont.monospacedSystemFont(
                    ofSize: font.pointSize,
                    weight: .regular
                )
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.white.withAlphaComponent(0.06),
                    range: range
                )
            } else {
                if raw & 1 != 0 {
                    renderedFont = NSFontManager.shared.convert(
                        renderedFont,
                        toHaveTrait: .italicFontMask
                    )
                }
                if raw & 2 != 0 {
                    renderedFont = NSFontManager.shared.convert(
                        renderedFont,
                        toHaveTrait: .boldFontMask
                    )
                }
            }
            result.addAttribute(.font, value: renderedFont, range: range)
            if raw & 4 != 0 {
                result.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }

        result.enumerateAttribute(
            .link,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard value != nil else { return }
            result.addAttributes(
                [
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: range
            )
        }
        return result
    }

    private static func applyParagraphStyle(
        to output: NSMutableAttributedString,
        range: NSRange,
        lineSpacing: CGFloat
    ) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        output.addAttribute(.paragraphStyle, value: style, range: range)
    }

    private static func localImage(at path: String) -> NSImage? {
        let url: URL
        if path.hasPrefix("file://"), let fileURL = URL(string: path) {
            url = fileURL
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
