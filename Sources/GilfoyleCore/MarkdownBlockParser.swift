import Foundation

/// Small native Markdown block parser shared by Anton's UI and its
/// deterministic tests. In particular, indented continuation paragraphs stay
/// attached to their numbered item so a `1.`-style Markdown list is rendered
/// as 1, 2, 3 rather than several unrelated one-item lists.
public enum MarkdownBlockParser {
    public enum Block: Equatable, Sendable {
        case heading(Int, String)
        case text(String)
        case code(String)
        case table([String], [[String]])
        case image(String, String)
        case list([String], ordered: Bool, start: Int)
    }

    public static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var buffer: [String] = []
        var index = 0

        func flush() {
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
                let ordered = firstListItem.ordered
                let start = firstListItem.number ?? 1
                var items: [String] = []
                var currentItem = firstListItem.value
                index += 1

                while index < lines.count {
                    if let next = listItem(lines[index]) {
                        guard next.ordered == ordered else { break }
                        items.append(
                            currentItem.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        currentItem = next.value
                        index += 1
                        continue
                    }

                    let continuation = lines[index]
                    if continuation.trimmingCharacters(in: .whitespaces).isEmpty {
                        var nextContent = index
                        while nextContent < lines.count,
                              lines[nextContent].trimmingCharacters(in: .whitespaces).isEmpty
                        {
                            nextContent += 1
                        }
                        if nextContent < lines.count,
                           let next = listItem(lines[nextContent]),
                           next.ordered == ordered
                        {
                            index = nextContent
                            continue
                        }
                        if nextContent < lines.count,
                           isIndentedContinuation(lines[nextContent])
                        {
                            if !currentItem.hasSuffix("\n\n") {
                                currentItem += "\n\n"
                            }
                            index = nextContent
                            continue
                        }
                        break
                    }

                    guard isIndentedContinuation(continuation) else { break }
                    let value = continuation.trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        if !currentItem.hasSuffix("\n") { currentItem += "\n" }
                        currentItem += value
                    }
                    index += 1
                }

                items.append(
                    currentItem.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                blocks.append(.list(items, ordered: ordered, start: start))
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

    private static func listItem(
        _ line: String
    ) -> (value: String, ordered: Bool, number: Int?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (String(trimmed.dropFirst(2)), false, nil)
        }
        let pattern = #"^(\d+)[.)]\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = expression.firstMatch(in: trimmed, range: range),
              let numberRange = Range(match.range(at: 1), in: trimmed),
              let valueRange = Range(match.range(at: 2), in: trimmed)
        else { return nil }
        return (
            String(trimmed[valueRange]),
            true,
            Int(trimmed[numberRange])
        )
    }

    private static func isIndentedContinuation(_ line: String) -> Bool {
        line.hasPrefix("  ") || line.hasPrefix("\t")
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
