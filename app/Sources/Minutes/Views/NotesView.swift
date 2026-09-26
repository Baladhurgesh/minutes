import AppKit
import SwiftUI

struct NotesPane: View {
    let meeting: Meeting
    let notes: String?
    let liveNotes: String?
    /// In tab mode the tab row already says "Notes" and hosts the actions, so the pane has no header.
    var showsHeader = true
    @EnvironmentObject var store: MeetingStore

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 6) {
                    Label("Notes", systemImage: "sparkles").font(.headline)
                    Spacer()
                    NotesActions(meeting: meeting, notes: notes, liveNotes: liveNotes)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                Divider()
            }
            ScrollView {
                content.padding(16)
            }
        }
    }
}

/// Writing indicator plus regenerate / copy / export buttons for a meeting's notes.
struct NotesActions: View {
    let meeting: Meeting
    let notes: String?
    let liveNotes: String?
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MeetingStore

    var body: some View {
        HStack(spacing: 6) {
            if liveNotes != nil {
                ProgressView().controlSize(.small)
                Text("Writing...").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                model.pipeline.regenerateNotes(meeting.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Write the notes again using the current speaker names")
            .disabled(meeting.status.isWorking || meeting.status == .recording || store.transcript(meeting.id) == nil)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notes ?? "", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy notes as Markdown")
            .disabled(notes == nil)
            Button {
                model.exportMarkdown(meeting.id)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export notes and transcript")
            .disabled(notes == nil)
        }
        .buttonStyle(.borderless)
    }
}

extension NotesPane {
    @ViewBuilder
    fileprivate var content: some View {
        if let liveNotes {
            MarkdownView(markdown: liveNotes)
        } else if let notes {
            NotesCards(markdown: notes) { line in
                try? store.saveNotes(NotesDocument.toggling(notes, line: line), for: meeting.id)
            }
        } else if meeting.status.isWorking {
            PipelineProgressView(meeting: meeting)
        } else {
            ContentUnavailableView("No notes yet", systemImage: "sparkles",
                                   description: Text(meeting.status == .failed ? "Processing did not finish." : ""))
        }
    }
}

struct NotesCards: View {
    let markdown: String
    let toggleTask: (Int) -> Void

    var body: some View {
        let doc = NotesDocument(markdown: markdown)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(doc.sections, id: \.self) { section in
                let style = Self.style(for: section.title)
                Card(title: section.title, systemImage: style.icon, tint: style.tint) {
                    SectionBody(section: section, toggleTask: toggleTask)
                }
            }
        }
        .textSelection(.enabled)
    }

    static func style(for title: String) -> (icon: String, tint: Color) {
        let t = title.lowercased()
        if t.contains("summary") { return ("text.alignleft", .blue) }
        if t.contains("key") { return ("star.fill", .yellow) }
        if t.contains("decision") { return ("checkmark.seal.fill", .green) }
        if t.contains("action") { return ("checklist", .orange) }
        if t.contains("question") { return ("questionmark.bubble.fill", .purple) }
        return ("note.text", .secondary)
    }
}

private struct SectionBody: View {
    let section: NotesDocument.Section
    let toggleTask: (Int) -> Void

    private var isEmpty: Bool {
        section.items.allSatisfy { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased() == "none" }
    }

    var body: some View {
        if isEmpty {
            Text("Nothing noted").font(.callout).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(section.items, id: \.self) { item in
                    switch item.kind {
                    case .paragraph:
                        inlineMarkdown(item.text).font(.callout).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .bullet:
                        inlineMarkdown(item.text).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 14)
                            .overlay(alignment: .topLeading) { Text("•").font(.callout).foregroundStyle(.secondary) }
                    case .task(let done):
                        inlineMarkdown(item.text)
                            .font(.callout)
                            .strikethrough(done)
                            .foregroundStyle(done ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 22)
                            .overlay(alignment: .topLeading) {
                                Button { toggleTask(item.line) } label: {
                                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                        .font(.callout)
                                        .foregroundStyle(done ? Color.green : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(done ? "Mark as not done" : "Mark as done")
                            }
                    }
                }
            }
        }
    }
}

/// Step list shown while a meeting is being processed.
struct PipelineProgressView: View {
    let meeting: Meeting

    private let steps: [(title: String, icon: String)] = [
        ("Prepare audio", "waveform"),
        ("Transcribe and identify speakers", "text.bubble"),
        ("Match words to speakers", "person.2"),
        ("Write notes", "sparkles"),
    ]

    private var current: Int {
        switch meeting.status {
        case .importing: return 0
        case .queued: return -1
        case .transcribing: return 1
        case .aligning: return 2
        case .summarizing: return 3
        default: return steps.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if current == -1 {
                Label("Waiting for another meeting to finish", systemImage: "hourglass").foregroundStyle(.secondary)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if i < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if i == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).foregroundStyle(i > current ? .secondary : .primary)
                            .fontWeight(i == current ? .semibold : .regular)
                        if i == current {
                            if let detail = meeting.stageDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            if let p = meeting.progress { ProgressView(value: p).frame(maxWidth: 220) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
