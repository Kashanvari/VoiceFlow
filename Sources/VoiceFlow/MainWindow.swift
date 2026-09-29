import AppKit
import SwiftUI
import VoiceFlowCore

/// The app window: a sidebar with Home (stats and history), Dictionary and Settings.
@MainActor
final class MainWindow {
    private var window: NSWindow?
    private let state: AppState

    init(state: AppState) { self.state = state }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "VoiceFlow"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 520)
            let host = NSHostingView(rootView: RootView().environmentObject(state))
            host.sizingOptions = [.minSize]  // the window keeps its size; pages scroll instead of stretching it
            w.contentView = host
            w.center()
            w.setFrameAutosaveName("VoiceFlowMainWindow")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Look

private enum Brand {
    static let blue = Color(red: 0.16, green: 0.42, blue: 0.98)
    static let violet = Color(red: 0.52, green: 0.25, blue: 0.93)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private enum Page: String, CaseIterable, Identifiable {
    case home = "Home", dictionary = "Dictionary", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

private struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var page: Page = .home

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 7).fill(Brand.gradient).frame(width: 26, height: 26)
                        .overlay(Image(systemName: "waveform").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                    Text("VoiceFlow").font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
            }
            .safeAreaInset(edge: .bottom) {
                StatusBadge().padding(12)
            }
        } detail: {
            switch page {
            case .home: HomeView()
            case .dictionary: DictionaryView()
            case .settings: SettingsView()
            }
        }
        .tint(Brand.blue)
    }
}

/// "Ready · hold fn" / "Loading…" / "Needs permission" in the sidebar corner.
private struct StatusBadge: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let (color, text) = describe()
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func describe() -> (Color, String) {
        if state.missingPermissions, state.status == .ready { return (.orange, "Needs permission, see Settings") }
        switch state.status {
        case .loading: return (.yellow, "Loading speech model…")
        case .downloading: return (.yellow, "Downloading speech model (450 MB)…")
        case .ready: return (.green, "Ready · hold \(state.dictationKey.short) to talk")
        case .recording: return (.red, "Listening…")
        case .working: return (Brand.blue, "Writing…")
        case .failed(let message): return (.red, message)
        }
    }
}

// MARK: - Home

private struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting).font(.system(size: 26, weight: .bold))
                    Text("Hold **\(state.dictationKey.short)** anywhere and speak. Let go, and your words appear where your cursor is.")
                        .foregroundStyle(.secondary)
                }

                if state.missingPermissions { PermissionBanner() }
                if state.activeMicrophone?.isVirtual ?? true { NoMicrophoneBanner() }

                HStack(spacing: 12) {
                    StatCard(value: state.wordsToday.formatted(), label: "Words today", icon: "text.word.spacing")
                    StatCard(value: state.totalWords.formatted(), label: "Words in total", icon: "sum")
                    StatCard(value: state.speakingSpeed > 0 ? "\(state.speakingSpeed)" : "—", label: "Words per minute",
                             icon: "speedometer")
                    StatCard(value: timeSaved, label: "Saved vs typing", icon: "clock.arrow.circlepath")
                }

                HStack {
                    Text("History").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }

                if filtered.isEmpty {
                    EmptyHistory(searching: !search.isEmpty, keyName: state.dictationKey.short)
                } else {
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(dayTitle(day)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                .textCase(.uppercase).padding(.bottom, 8)
                            VStack(spacing: 0) {
                                let entries = filtered.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                                ForEach(entries) { entry in
                                    HistoryRow(entry: entry)
                                    if entry != entries.last { Divider().padding(.leading, 76) }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private var greeting: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return first.isEmpty ? part : "\(part), \(first)"
    }

    private var timeSaved: String {
        let m = state.minutesSaved
        return m < 60 ? "\(m) min" : String(format: "%.1f h", Double(m) / 60)
    }

    private var filtered: [History.Entry] {
        guard !search.isEmpty else { return state.history }
        return state.history.filter { $0.text.localizedCaseInsensitiveContains(search) || $0.app.localizedCaseInsensitiveContains(search) }
    }

    private var days: [Date] {
        Array(Set(filtered.map { Calendar.current.startOfDay(for: $0.date) })).sorted(by: >)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.gradient)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct HistoryRow: View {
    let entry: History.Entry
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(entry.app).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if hovering || copied {
                HStack(spacing: 4) {
                    Button { copy(entry.text) } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy")
                    if entry.raw != entry.text {
                        Menu {
                            Button("Copy without clean-up") { copy(entry.raw) }
                        } label: { Image(systemName: "ellipsis") }
                        .menuIndicator(.hidden).fixedSize()
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func copy(_ text: String) {
        Paster.copy(text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

private struct EmptyHistory: View {
    let searching: Bool
    var keyName = "fn"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: searching ? "magnifyingglass" : "waveform")
                .font(.system(size: 28, weight: .medium)).foregroundStyle(Brand.gradient)
            Text(searching ? "Nothing matches your search" : "Your dictations will appear here")
                .font(.system(size: 14, weight: .medium))
            if !searching {
                Text("Click into any text box, hold \(keyName), and start talking.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [5])))
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("VoiceFlow needs permission to work").font(.system(size: 13, weight: .semibold))
                Text(!state.accessibilityAllowed
                     ? "Accessibility lets it see the dictation key and paste your words. If VoiceFlow is already listed, switch it off and on."
                     : "Microphone access lets it hear you.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(!state.accessibilityAllowed ? "Open Accessibility" : "Allow Microphone") {
                !state.accessibilityAllowed ? state.openAccessibilitySettings() : state.requestMicrophone()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
    }
}

private struct NoMicrophoneBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("No microphone connected").font(.system(size: 13, weight: .semibold))
                Text("Connect AirPods, a headset or a USB microphone, and VoiceFlow picks it up automatically. Mac minis and Mac Studios have no built-in mic.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
    }
}

// MARK: - Dictionary

private struct DictionaryView: View {
    @EnvironmentObject var state: AppState
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictionary").font(.system(size: 26, weight: .bold))
                    Text("Teach VoiceFlow names it gets wrong, or make shortcuts. Whole words only, upper or lower case. A shortcut fires every time you say its words, so pick words you wouldn't say by accident (e.g. “insert my email”).")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    TextField("When VoiceFlow hears…  (e.g. git hub)", text: $from)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Write instead…  (e.g. GitHub)", text: $to).onSubmit(add)
                    Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(!canAdd)
                }
                .textFieldStyle(.roundedBorder)

                if state.replacements.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ideas to start with").font(.system(size: 13, weight: .semibold))
                        ForEach([("git hub", "GitHub"), ("open ai", "OpenAI"), ("chat gpt", "ChatGPT")], id: \.0) { pair in
                            Button { state.replacements.append(Replacement(from: pair.0, to: pair.1)) } label: {
                                HStack { Text(pair.0); Image(systemName: "arrow.right"); Text(pair.1); Image(systemName: "plus.circle") }
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("VoiceFlow hears").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Writes").frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(width: 24)
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        Divider()
                        ForEach($state.replacements) { $r in
                            HStack {
                                TextField("", text: $r.from).textFieldStyle(.plain).frame(maxWidth: .infinity)
                                TextField("", text: $r.to).textFieldStyle(.plain).frame(maxWidth: .infinity)
                                Button { state.replacements.removeAll { $0.id == r.id } } label: {
                                    Image(systemName: "trash").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless).help("Remove").frame(width: 24)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            if r.id != state.replacements.last?.id { Divider() }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                }

                Text("Changes apply to your next dictation, before the AI clean-up.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private var canAdd: Bool {
        !from.trimmingCharacters(in: .whitespaces).isEmpty && !to.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        state.replacements.append(Replacement(from: from.trimmingCharacters(in: .whitespaces),
                                              to: to.trimmingCharacters(in: .whitespaces)))
        from = ""
        to = ""
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Dictation") {
                Picker(selection: $state.dictationKey) {
                    ForEach(DictationKey.allCases) { key in Text(key.menuTitle).tag(key) }
                } label: {
                    Text("Dictation key")
                    Text("Hold to talk · double-tap for hands-free · Esc to cancel")
                }
                if state.dictationKey == .fn {
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, or fn also opens the emoji picker.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $state.aiCleanup) {
                    Text("AI clean-up")
                    Text("Removes filler words, fixes “Thursday, no, Friday”, and handles “new paragraph”, emails and lists.")
                }
                Toggle("Sounds when recording starts and stops", isOn: $state.sounds)
            }

            Section("Microphone") {
                Picker("Microphone", selection: Binding(get: { state.microphoneChoice ?? "" },
                                                        set: { state.microphoneChoice = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic" + (state.microphoneChoice == nil ? " (\(state.activeMicrophone?.name ?? "none"))" : ""))
                        .tag("")
                    ForEach(state.microphones) { mic in
                        Text(mic.name + (mic.isVirtual ? " (virtual, no voice)" : "")).tag(mic.id)
                    }
                    if let choice = state.microphoneChoice, !state.microphones.contains(where: { $0.id == choice }) {
                        Text("Saved microphone (not connected)").tag(choice)
                    }
                }
                Toggle(isOn: $state.keepMicReady) {
                    Text("Keep the microphone ready for 30 seconds after dictating")
                    Text("The next dictation starts instantly. Bluetooth mics such as AirPods take 1–3 s to wake up otherwise, but while ready they stay in call mode, so music sounds like a phone call.")
                }
                if let mic = state.activeMicrophone, !mic.isVirtual {
                    Text("Automatic skips virtual devices like Microsoft Teams Audio, which carry no voice.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("No real microphone is connected. Connect AirPods, a headset or a USB microphone (Mac minis and Mac Studios have no built-in mic).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", detail: "To hear you", ok: state.micAllowed) { state.requestMicrophone() }
                PermissionRow(title: "Accessibility", detail: "To see the dictation key and paste your words", ok: state.accessibilityAllowed) {
                    state.openAccessibilitySettings()
                }
                if !state.accessibilityAllowed {
                    Text("Already switched on but still not working? Switch VoiceFlow off and on again. macOS forgets it after each rebuild.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Open VoiceFlow when you log in", isOn: Binding(get: { state.openAtLogin },
                                                                       set: { state.setOpenAtLogin($0) }))
            }

            Section("Your data") {
                LabeledContent("History", value: "\(state.history.count) dictations, saved only on this Mac")
                HStack {
                    Button("Open VoiceFlow Folder") { state.openProjectFolder() }
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(state.history.isEmpty)
                }
            }

            Section("About") {
                LabeledContent("Speech to text", value: "Parakeet TDT 0.6b v2 · on this Mac")
                LabeledContent("Clean-up", value: state.cleanerRunning ? "SpeakoFlow Mini 0.8B · on this Mac" : "Not running (rules only)")
                LabeledContent("Privacy", value: "Nothing leaves your Mac")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .confirmationDialog("Clear all \(state.history.count) dictations?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { state.clearHistory() }
        } message: {
            Text("This deletes your saved history. It can't be undone.")
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ok {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Allow…", action: action)
            }
        }
    }
}
