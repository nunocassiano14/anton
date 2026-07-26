import AppKit
import SwiftUI

/// A compact, native Markdown reader for the latest agent reply. It keeps
/// code and tables legible inside Anton's narrow board without a web view.
struct MarkdownResponseView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case let .heading(level, value):
            Text(attributed(value))
                .font(.system(size: level == 1 ? 14.5 : 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.90))
        case let .text(value):
            Text(attributed(value))
                .font(.system(size: 11.7))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: 11.7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(minWidth: ordered ? 18 : 8, alignment: .trailing)
                        Text(attributed(items[index]))
                            .font(.system(size: 11.7))
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .code(value):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.74))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
        case let .table(headers, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { column in
                            tableCell(headers[column], isHeader: true)
                        }
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(headers.indices, id: \.self) { column in
                                tableCell(column < rows[row].count ? rows[row][column] : "", isHeader: false)
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }
        case let .image(path, alt):
            if let image = localImage(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .accessibilityLabel(alt.isEmpty ? "Image from agent response" : alt)
            } else {
                Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func tableCell(_ value: String, isHeader: Bool) -> some View {
        Text(attributed(value))
            .font(.system(size: 10.5, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(.white.opacity(isHeader ? 0.80 : 0.60))
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(text)
    }

    private func localImage(at path: String) -> NSImage? {
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

private enum MarkdownBlocks {
    enum Block {
        case heading(Int, String)
        case text(String)
        case code(String)
        case table([String], [[String]])
        case image(String, String)
        case list([String], Bool)
    }

    static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var buffer: [String] = []
        var index = 0

        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            buffer.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                flush()
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                index += 1
                continue
            }
            if let heading = heading(line) {
                flush()
                blocks.append(.heading(heading.level, heading.value))
                index += 1
                continue
            }
            if let image = image(line) {
                flush()
                blocks.append(.image(image.path, image.alt))
                index += 1
                continue
            }
            if let firstListItem = listItem(line) {
                flush()
                var items: [String] = [firstListItem.value]
                let ordered = firstListItem.ordered
                index += 1
                while index < lines.count, let next = listItem(lines[index]), next.ordered == ordered {
                    items.append(next.value)
                    index += 1
                }
                blocks.append(.list(items, ordered))
                continue
            }
            if index + 1 < lines.count, isTableRow(line), isTableDivider(lines[index + 1]) {
                flush()
                let headers = tableCells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, isTableRow(lines[index]) {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(headers, rows))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                buffer.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, value: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let value = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (hashes.count, value)
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|")
    }

    private static func image(_ line: String) -> (path: String, alt: String)? {
        let pattern = #"^!\[([^\]]*)\]\(([^)]+)\)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let altRange = Range(match.range(at: 1), in: line),
              let pathRange = Range(match.range(at: 2), in: line)
        else { return nil }
        return (String(line[pathRange]), String(line[altRange]))
    }

    private static func listItem(_ line: String) -> (value: String, ordered: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (String(trimmed.dropFirst(2)), false)
        }
        let pattern = #"^\d+[.)]\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = expression.firstMatch(in: trimmed, range: range),
              let valueRange = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        return (String(trimmed[valueRange]), true)
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "|-: ")
        return line.unicodeScalars.allSatisfy { allowed.contains($0) } && line.contains("-")
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
