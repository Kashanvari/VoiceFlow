import AppKit
import SwiftUI

/// The small floating pill at the bottom of the screen: listening (with a live level meter), working, or a
/// short message. It is a non-activating panel, so it never takes keyboard focus away from the app you type in.
@MainActor
final class Indicator {
    enum Mode: Equatable { case hidden, listening(handsFree: Bool), working, message(String) }

    private final class Model: ObservableObject {
        @Published var mode: Mode = .hidden
        @Published var levels: [Float] = Array(repeating: 0, count: 12)
        /// False while the microphone is still starting (grey dot), true once it hears you (red dot).
        @Published var live = false
        @Published var keyName = "fn"
        @Published var languageTag: String?
    }

    private let model = Model()
    /// "fn", "right ⌥"…, for the hands-free hint.
    var keyName: String {
        get { model.keyName }
        set { model.keyName = newValue }
    }
    /// "فا" while dictating in Farsi (nil for English), shown next to the dot.
    var languageTag: String? {
        get { model.languageTag }
        set { model.languageTag = newValue }
    }
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        // Wide enough for the longest message; the pill itself sizes to its content in the middle.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
    }

    func show(_ mode: Mode, hideAfter seconds: Double? = nil) {
        hideWork?.cancel()
        model.mode = mode
        if mode == .hidden {
            panel.orderOut(nil)
            return
        }
        switch mode {
        case .listening(handsFree: false):  // a new recording: empty meter, grey dot until the mic is on
            model.levels = Array(repeating: 0, count: model.levels.count)
            model.live = false
        case .listening(handsFree: true):   // same recording, switched to hands-free: keep meter and dot
            break
        default:
            model.live = false
        }
        position()
        panel.orderFrontRegardless()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    /// Nothing is showing, so a short message won't cover anything.
    var isFree: Bool { model.mode == .hidden }

    /// The microphone is on: the dot turns red.
    func setLive(_ on: Bool) {
        model.live = on
    }

    func level(_ value: Float) {
        guard case .listening = model.mode else { return }
        model.levels.removeFirst()
        model.levels.append(value)
    }

    /// Bottom centre of the screen the mouse is on, just above the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 18))
    }

    private struct PillView: View {
        @ObservedObject var model: Model

        var body: some View {
            HStack(spacing: 8) {
                switch model.mode {
                case .hidden:
                    EmptyView()
                case .listening(let handsFree):
                    Circle().fill(model.live ? Color.red : Color.gray).frame(width: 8, height: 8)
                        .animation(.easeOut(duration: 0.15), value: model.live)
                    if let tag = model.languageTag {
                        Text(tag).font(.system(size: 12, weight: .semibold))
                    }
                    if !model.live {
                        Text("Starting mic…").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(model.levels.indices, id: \.self) { i in
                            Capsule().fill(Color.white.opacity(0.9))
                                .frame(width: 3, height: 4 + CGFloat(model.levels[i]) * 18)
                        }
                    }
                    .frame(height: 22)
                    .animation(.linear(duration: 0.08), value: model.levels)
                    if handsFree {
                        Text("Hands-free · \(model.keyName) to stop").font(.system(size: 11, weight: .medium))
                    }
                case .working:
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Writing…").font(.system(size: 12, weight: .medium))
                case .message(let text):
                    Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Color.black.opacity(0.82)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
