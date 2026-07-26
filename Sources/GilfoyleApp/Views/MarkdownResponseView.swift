import AppKit
import GilfoyleCore
import SwiftUI

/// A compact, native Markdown reader for the latest agent reply. It keeps
/// code and tables legible inside Anton's narrow board without a web view.
struct MarkdownResponseView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlockParser.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlockParser.Block) -> some View {
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
        case let .list(items, ordered, start):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(start + index)." : "•")
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
