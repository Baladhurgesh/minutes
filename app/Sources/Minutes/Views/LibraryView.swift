import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MeetingStore
    @State private var search = ""

    private var sections: [(title: String, meetings: [Meeting])] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let items = q.isEmpty ? store.meetings
            : store.meetings.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.source.localizedCaseInsensitiveContains(q) }
        let cal = Calendar.current
        let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))!
        var order: [String] = []
        var groups: [String: [Meeting]] = [:]
        for m in items {
            let key: String
            if cal.isDateInToday(m.createdAt) { key = "Today" }
            else if cal.isDateInYesterday(m.createdAt) { key = "Yesterday" }
            else if m.createdAt >= weekAgo { key = "Previous 7 Days" }
            else { key = m.createdAt.formatted(.dateTime.month(.wide).year()) }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(m)
        }
        return order.map { ($0, groups[$0]!) }
    }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.meetings) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(meeting.id)
                            .contextMenu { menu(for: meeting) }
                    }
                }
            }
        }
        .overlay {
            if store.meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                       description: Text("Recordings and imports appear here."))
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search meetings")
        .onDeleteCommand {
            if let id = model.selection { model.requestDelete(id) }
        }
        .safeAreaInset(edge: .bottom) { EngineStatusBar() }
    }

    @ViewBuilder
    private func menu(for meeting: Meeting) -> some View {
        if meeting.status == .failed || meeting.status == .done {
            Button(meeting.status == .failed ? "Try Again" : "Process Again") { model.retry(meeting.id) }
        }
        if meeting.status.isWorking {
            Button("Cancel Processing") { model.pipeline.cancel(meeting.id) }
        }
        Menu("Download") {
            DownloadMenuItems(meetingID: meeting.id)
        }
        Button("Show in Finder") { model.revealInFinder(meeting.id) }
        Divider()
        Button("Delete...", role: .destructive) { model.requestDelete(meeting.id) }
            .disabled(meeting.status == .recording)
    }
}

/// Recording (M4A / WAV) and notes downloads, shared by the header button and the context menu.
struct DownloadMenuItems: View {
    let meetingID: UUID
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MeetingStore

    var body: some View {
        ForEach(AppModel.RecordingFormat.allCases, id: \.self) { format in
            Button(format.label) { model.downloadRecording(meetingID, format: format) }
                .disabled(!model.hasRecording(meetingID))
        }
        Divider()
        Button("Notes and Transcript (Markdown)") { model.exportMarkdown(meetingID) }
            .disabled(store.notes(meetingID) == nil && store.transcript(meetingID) == nil)
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(meeting: meeting)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(meeting.createdAt, format: .dateTime.hour().minute())
                    if meeting.duration > 0 {
                        Text("·")
                        Text(DurationFormat.short(meeting.duration))
                    }
                    if meeting.status.isWorking || meeting.status == .failed || meeting.status == .recording {
                        Text("·")
                        Text(meeting.status.label).foregroundStyle(meeting.status == .failed ? .orange : .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RowIcon: View {
    let meeting: Meeting

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
            switch meeting.status {
            case .recording:
                Image(systemName: "record.circle.fill").foregroundStyle(.white)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            case _ where meeting.status.isWorking:
                if let p = meeting.progress {
                    ProgressView(value: p).progressViewStyle(.circular).controlSize(.small).tint(.white)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            default:
                Image(systemName: meeting.source == "recording" ? "mic.fill" : "doc.text.fill").foregroundStyle(.white)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 30, height: 30)
    }

    private var background: AnyShapeStyle {
        switch meeting.status {
        case .recording: return AnyShapeStyle(Color.red.gradient)
        case .failed: return AnyShapeStyle(Color.orange.gradient)
        default: return AnyShapeStyle(Brand.gradient)
        }
    }
}

struct EngineStatusBar: View {
    @EnvironmentObject var engine: EngineManager

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1).truncationMode(.tail)
            Spacer()
            if case .failed = engine.state {
                Button("Restart") { Task { await engine.restart() } }.controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .help(engine.state.label)
    }

    private var color: Color {
        switch engine.state {
        case .ready: return .green
        case .starting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    private var text: String {
        switch engine.state {
        case .ready: return "On-device models ready"
        case .starting: return "Starting on-device models..."
        case .stopped: return "Models idle"
        case .failed(let m): return m
        }
    }
}
