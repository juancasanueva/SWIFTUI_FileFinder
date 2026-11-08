import AppKit
import SwiftUI

/// Colors for highlighted code, from the system palette so they follow light and dark mode.
nonisolated enum SyntaxColors {
    static func color(_ kind: SyntaxToken.Kind) -> Color {
        switch kind {
        case .keyword: Color(nsColor: .systemPink)
        case .string: Color(nsColor: .systemRed)
        case .number: Color(nsColor: .systemPurple)
        case .comment: Color(nsColor: .secondaryLabelColor)
        case .key: Color(nsColor: .systemBlue)
        }
    }

    static func highlighted(_ text: String, language: SyntaxLanguage) -> AttributedString {
        var result = AttributedString(text)
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            guard let stringRange = Range(token.range, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upper = AttributedString.Index(stringRange.upperBound, within: result)
            else { continue }
            result[lower..<upper].foregroundColor = color(token.kind)
        }
        return result
    }
}

/// The first lines of a code or config file, highlighted.
struct CodePreview: View {
    /// Lines shown, at most; the rest is one click away in an editor.
    static let lineLimit = 400

    let url: URL
    let language: SyntaxLanguage
    let fallback: AnyView
    @State private var content: CodeContent?
    @State private var failed = false

    struct CodeContent: Sendable {
        let text: AttributedString
        let isTruncated: Bool
    }

    var body: some View {
        Group {
            if let content {
                VStack(alignment: .leading, spacing: 6) {
                    CodeBox(text: content.text)
                    if content.isTruncated {
                        Text("Showing the first \(Self.lineLimit) lines")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if failed {
                fallback
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: url) {
            content = nil
            failed = false
            content = await Self.load(url, language: language)
            failed = content == nil
        }
    }

    /// `nil` for a file that isn't text.
    @concurrent private nonisolated static func load(_ url: URL, language: SyntaxLanguage) async -> CodeContent? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024), !data.prefix(8192).contains(0) else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(lineLimit).joined(separator: "\n")
        return CodeContent(
            text: SyntaxColors.highlighted(shown, language: language),
            isTruncated: lines.count > lineLimit || data.count == 256 * 1024)
    }
}

/// Monospaced text on a soft background, selectable.
private struct CodeBox: View {
    let text: AttributedString

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A Markdown file in the preview pane: rendered, or as text to edit (saved with ⌘S, and
/// when you move to another file).
struct MarkdownDocumentView: View {
    enum Mode: String { case preview, edit }

    let model: BrowserModel
    let url: URL
    let fallback: AnyView
    @AppStorage("markdownPreviewMode") private var mode: Mode = .preview
    @State private var failed = false

    var body: some View {
        Group {
            if let document = model.document, document.url == url.canonical {
                editor(document)
            } else if failed {
                fallback
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: url) {
            model.openDocument(url)
            failed = model.document?.url != url.canonical
        }
    }

    @ViewBuilder
    private func editor(_ document: TextDocument) -> some View {
        @Bindable var document = document
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Mode", selection: $mode) {
                    Text("Preview").tag(Mode.preview)
                    Text("Edit").tag(Mode.edit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if document.isDirty {
                    Button("Save") { model.saveDocument() }
                        .help("Save (⌘S). Edits are also saved when you select another file.")
                } else if mode == .edit {
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                }
            }
            if document.hasConflict {
                conflictBanner(document)
            }
            if let message = document.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            switch mode {
            case .preview:
                MarkdownView(text: document.text)
            case .edit:
                TextEditor(text: $document.text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .frame(height: 420)
            }
        }
    }

    private func conflictBanner(_ document: TextDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This file changed on disk after you opened it.", systemImage: "exclamationmark.triangle")
                .font(.caption)
            HStack {
                Button("Overwrite") { document.overwrite() }
                    .help("Save your version over the one on disk")
                Button("Reload") { document.reload() }
                    .help("Drop your edits and show the version on disk")
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Markdown drawn natively: headings, paragraphs, lists, quotes, code, rules and tables.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let text):
            Text(inline(text))
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                Text(inline(text))
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            Text(inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                }
        case .code(let language, let text):
            CodeBox(text: SyntaxColors.highlighted(text, language: Self.language(named: language)))
        case .rule:
            Divider()
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// A fenced block's language name (`swift`, `js`, `yaml`…) as a highlighter language.
    private static func language(named name: String?) -> SyntaxLanguage {
        guard let name, case .code(let language)? = TextPreviewKind(url: URL(filePath: "code.\(name.lowercased())"))
        else { return name.map { ["bash", "shell", "console", "zsh"].contains($0) ? .shell : .plain } ?? .plain }
        return language
    }
}
