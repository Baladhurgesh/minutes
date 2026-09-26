import SwiftUI

struct MeetingDetailView: View {
    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }

    /// Below this detail width, notes and transcript become tabs instead of side-by-side panes.
    static let splitMinWidth: CGFloat = 820

    let meetingID: UUID
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var pipeline: MeetingPipeline
    @StateObject private var player = AudioPlayer()
    @State private var transcript: Transcript?
    @State private var notes: String?
    @State private var tab: Tab = .notes

    private var meeting: Meeting? { store.meeting(meetingID) }

    var body: some View {
        if let meeting {
            if meeting.status == .recording {
                RecordingLiveView()
            } else {
                content(meeting)
                    .task(id: "\(meeting.status.rawValue)|\(meeting.title)") { reload(meeting) }
                    .onReceive(store.objectWillChange) { _ in
                        DispatchQueue.main.async { reloadContent() }
                    }
                    .onDisappear { player.stop() }
            }
        }
    }

    private func content(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            MeetingHeader(meeting: meeting, speakerCount: transcript?.speakers.count)
            Divider()
            GeometryReader { geo in
                if geo.size.width >= Self.splitMinWidth {
                    HStack(spacing: 0) {
                        transcriptPane(meeting)
                        Divider()
                        notesPane(meeting, showsHeader: true)
                            .frame(width: min(max(geo.size.width * 0.4, 340), 500))
                    }
                } else {
                    VStack(spacing: 0) {
                        ZStack {
                            Picker("View", selection: $tab) {
                                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 240)
                            if tab == .notes {
                                HStack {
                                    Spacer()
                                    NotesActions(meeting: meeting, notes: notes, liveNotes: pipeline.liveNotes[meetingID])
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        Divider()
                        if tab == .notes { notesPane(meeting, showsHeader: false) } else { transcriptPane(meeting) }
                    }
                }
            }
            if player.duration > 0 {
                Divider()
                PlayerBar(player: player, turns: transcript?.turns ?? [])
            }
        }
    }

    private func transcriptPane(_ meeting: Meeting) -> some View {
        TranscriptView(meeting: meeting, transcript: transcript, player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notesPane(_ meeting: Meeting, showsHeader: Bool) -> some View {
        NotesPane(meeting: meeting, notes: notes, liveNotes: pipeline.liveNotes[meetingID], showsHeader: showsHeader)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func reload(_ meeting: Meeting) {
        reloadContent()
        if player.duration == 0, FileManager.default.fileExists(atPath: store.audioURL(meetingID).path) {
            player.load(store.audioURL(meetingID))
        }
    }

    private func reloadContent() {
        guard let m = meeting, m.status != .recording else { return }
        transcript = store.transcript(meetingID)
        notes = store.notes(meetingID)
    }
}

struct MeetingHeader: View {
    let meeting: Meeting
    let speakerCount: Int?
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var model: AppModel
    @State private var title = ""
    @State private var editing = false
    @State private var hovering = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editing {
                TextField("Untitled meeting", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onExitCommand { title = meeting.title; editing = false }
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                    .onAppear { titleFocused = true }
            } else {
                Text(meeting.title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 22)
                    .overlay(alignment: .topTrailing) {
                        Button { beginEditing() } label: { Image(systemName: "pencil").font(.callout) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                            .opacity(hovering ? 1 : 0)
                            .help("Rename meeting")
                    }
                    .onHover { hovering = $0 }
                    .onTapGesture(count: 2, perform: beginEditing)
                    .help("Double-click to rename")
            }
            FlowLayout(spacing: 6) {
                MetaChip(systemImage: "calendar", text: meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                if meeting.duration > 0 { MetaChip(systemImage: "clock", text: DurationFormat.short(meeting.duration)) }
                if let n = speakerCount, n > 0 { MetaChip(systemImage: "person.2", text: n == 1 ? "1 speaker" : "\(n) speakers") }
                MetaChip(systemImage: meeting.source == "recording" ? "mic" : "doc",
                         text: meeting.source == "recording" ? "Recorded" : meeting.source)
                if let p = meeting.profile { MetaChip(systemImage: "cpu", text: p) }
            }
            StatusBanner(meeting: meeting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func beginEditing() {
        title = meeting.title
        editing = true
    }

    private func commitTitle() {
        guard editing else { return }
        editing = false
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != meeting.title else { return }
        store.update(meeting.id) { $0.title = t; $0.autoTitle = false }
    }
}

struct StatusBanner: View {
    let meeting: Meeting
    @EnvironmentObject var model: AppModel
    @State private var showWarnings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if meeting.status.isWorking {
                banner(tint: .accentColor) {
                    if let p = meeting.progress { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                    Text(meeting.stageDetail ?? meeting.status.label).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Cancel") { model.pipeline.cancel(meeting.id) }.controlSize(.small)
                }
            } else if meeting.status == .failed {
                banner(tint: .orange) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(meeting.error ?? "Processing failed").lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Try Again") { model.retry(meeting.id) }.controlSize(.small)
                }
            }
            if !meeting.warnings.isEmpty {
                DisclosureGroup(isExpanded: $showWarnings) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(meeting.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.top, 4)
                } label: {
                    Label(meeting.warnings.count == 1 ? "1 note about this meeting" : "\(meeting.warnings.count) notes about this meeting",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func banner<C: View>(tint: Color, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct TranscriptView: View {
    let meeting: Meeting
    let transcript: Transcript?
    @ObservedObject var player: AudioPlayer
    @State private var query = ""

    private var currentTurn: Int? {
        guard player.isPlaying || player.currentTime > 0, let turns = transcript?.turns else { return nil }
        return turns.lastIndex { $0.start <= player.currentTime + 0.05 }
    }

    private var visibleTurns: [(Int, Turn)] {
        let all = Array((transcript?.turns ?? []).enumerated())
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.1.text.localizedCaseInsensitiveContains(q) || meeting.speakerName($0.1.speaker).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        if let transcript, !transcript.turns.isEmpty {
            VStack(spacing: 0) {
                toolbar(transcript)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(visibleTurns, id: \.0) { i, turn in
                                TurnRow(turn: turn, name: meeting.speakerName(turn.speaker), isCurrent: i == currentTurn, query: query)
                                    .id(i)
                            }
                            if visibleTurns.isEmpty {
                                Text("No matches for “\(query)”").foregroundStyle(.secondary).padding()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "minutes-seek", let t = Double(url.host ?? "") else { return .systemAction }
                        player.seek(t)
                        return .handled
                    })
                    .onChange(of: currentTurn) { _, turn in
                        if let turn, player.isPlaying, query.isEmpty { withAnimation { proxy.scrollTo(turn, anchor: .center) } }
                    }
                }
            }
        } else if meeting.status.isWorking {
            ScrollView { PipelineProgressView(meeting: meeting).padding(16) }
        } else {
            ContentUnavailableView(meeting.status == .done ? "No speech found" : "No transcript", systemImage: "text.bubble",
                                   description: Text(meeting.status == .done ? "This recording seems to be silent." : ""))
        }
    }

    private func toolbar(_ transcript: Transcript) -> some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(transcript.speakers, id: \.self) { s in
                        SpeakerChip(meetingID: meeting.id, speaker: s, name: meeting.speakerName(s))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcript", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(width: 190, height: 26)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

struct TurnRow: View {
    let turn: Turn
    let name: String
    let isCurrent: Bool
    var query: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SpeakerAvatar(name: name, speaker: turn.speaker)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name).font(.callout.weight(.semibold)).foregroundStyle(SpeakerColors.color(turn.speaker))
                    Link(TimeFormat.clock(turn.start), destination: URL(string: "minutes-seek://\(turn.start)")!)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Play from here")
                }
                Text(attributed)
                    .tint(.primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isCurrent ? SpeakerColors.color(turn.speaker).opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Each word links to its start time so clicking it seeks the player; search matches are highlighted.
    private var attributed: AttributedString {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !turn.words.isEmpty else { return AttributedString(turn.text) }
        var out = AttributedString()
        for (i, w) in turn.words.enumerated() {
            var piece = AttributedString(w.text)
            piece.link = URL(string: "minutes-seek://\(w.start)")
            if !q.isEmpty, w.text.lowercased().contains(q) { piece.backgroundColor = .yellow.opacity(0.45) }
            out += piece
            if i < turn.words.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}

struct SpeakerChip: View {
    let meetingID: UUID
    let speaker: Int
    let name: String
    @EnvironmentObject var store: MeetingStore
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = name.hasPrefix("Speaker ") ? "" : name
            editing = true
        } label: {
            HStack(spacing: 5) {
                SpeakerAvatar(name: name, speaker: speaker, size: 18)
                Text(name).lineLimit(1)
            }
            .font(.callout)
            .padding(.leading, 3)
            .padding(.trailing, 9)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Rename this speaker")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Who is Speaker \(speaker + 1)?").font(.headline)
                TextField("Name", text: $draft).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(save)
                Text("Regenerate notes afterwards to use the name in action items.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func save() {
        let n = draft.trimmingCharacters(in: .whitespaces)
        store.update(meetingID) { $0.speakerNames[String(speaker)] = n.isEmpty ? nil : n }
        editing = false
    }
}

struct RecordingLiveView: View {
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var model: AppModel
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Color.red.opacity(0.12)).frame(width: 150, height: 150).scaleEffect(pulse ? 1.12 : 0.88)
                Circle().fill(Color.red.opacity(0.2)).frame(width: 104, height: 104)
                Circle().fill(Color.red.gradient).frame(width: 68, height: 68)
                Image(systemName: "mic.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            }
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }

            Text(TimeFormat.clock(recorder.elapsed))
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(recorder.capturingSystemAudio ? "Recording your microphone and system audio" : "Recording your microphone")
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                meterRow("Microphone", "mic.fill", recorder.micLevel)
                if recorder.capturingSystemAudio { meterRow("System audio", "speaker.wave.2.fill", recorder.systemLevel) }
            }
            .frame(maxWidth: 340)
            .padding(14)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop and Transcribe", systemImage: "stop.fill").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [.command])
            Spacer()
            Label("Audio stays on this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func meterRow(_ title: String, _ icon: String, _ level: Float) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.callout).frame(width: 96, alignment: .leading)
            LevelMeter(level: level)
        }
    }
}
