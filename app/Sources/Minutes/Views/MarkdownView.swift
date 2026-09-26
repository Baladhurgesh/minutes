import SwiftUI

/// Notes Markdown split into "## " sections. Keeps each item's line index so task checkboxes can be toggled in place.
struct NotesDocument {
    struct Item: Hashable {
        enum Kind: Hashable { case bullet, task(done: Bool), paragraph }
        let kind: Kind
        let text: String
        let line: Int
    }

    struct Section: Hashable {
        let title: String
        var items: [Item]
    }

    let title: String?
    let sections: [Section]

    init(markdown: String) {
        var title: String?
        var sections: [Section] = []
        for (i, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("# ") {
                title = String(line.dropFirst(2))
                continue
            }
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                sections.append(Section(title: line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), items: []))
                continue
            }
            if sections.isEmpty { sections.append(Section(title: "Notes", items: [])) }
            let item: Item
            if let t = Self.task(line) {
                item = Item(kind: .task(done: t.done), text: t.text, line: i)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                item = Item(kind: .bullet, text: String(line.dropFirst(2)), line: i)
            } else {
                item = Item(kind: .paragraph, text: line, line: i)
            }
            sections[sections.count - 1].items.append(item)
        }
        self.title = title
        self.sections = sections
    }

    private static func task(_ line: String) -> (done: Bool, text: String)? {
        for (prefix, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false)] where line.hasPrefix(prefix) {
            return (done, String(line.dropFirst(prefix.count)))
        }
        return nil
    }

    /// The markdown with the task on `line` checked or unchecked.
    static func toggling(_ markdown: String, line: Int) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return markdown }
        let l = lines[line]
        if l.contains("- [ ] ") {
            lines[line] = l.replacingOccurrences(of: "- [ ] ", with: "- [x] ")
        } else if l.contains("- [x] ") || l.contains("- [X] ") {
            lines[line] = l.replacingOccurrences(of: "- [x] ", with: "- [ ] ").replacingOccurrences(of: "- [X] ", with: "- [ ] ")
        }
        return lines.joined(separator: "\n")
    }
}

/// Plain rendering used while notes are still streaming in.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        let doc = NotesDocument(markdown: markdown)
        VStack(alignment: .leading, spacing: 6) {
            if let title = doc.title { Text(title).font(.title3.bold()) }
            ForEach(doc.sections, id: \.self) { section in
                Text(section.title).font(.headline).padding(.top, 6)
                ForEach(section.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if item.kind != .paragraph { Text("•").foregroundStyle(.secondary) }
                        inlineMarkdown(item.text)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
