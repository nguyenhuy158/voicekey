import SwiftUI
import AVFoundation

/// Live mic level, fed from the recording tap.
final class Meter: ObservableObject {
    static let shared = Meter()
    static let bars = 26

    @Published private(set) var samples = [Float](repeating: 0, count: Meter.bars)

    func push(_ rms: Float) {
        // rms of speech sits around 0.02–0.2; scale it into 0…1 and keep some floor
        let v = min(1, max(0.06, rms * 9))
        var s = samples
        s.removeFirst()
        s.append(v)
        samples = s
    }

    func reset() { samples = [Float](repeating: 0, count: Meter.bars) }
}

enum HUDState { case idle, listening, transcribing }

struct HUDView: View {
    let state: HUDState
    let lang: String
    @ObservedObject var meter = Meter.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state == .listening ? Color(red: 0.29, green: 0.55, blue: 1)
                      : (state == .idle ? Color.white.opacity(0.35) : .orange))
                .frame(width: 9, height: 9)

            if state != .idle {
                Text(lang.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

            if state == .idle {
                Text("\(T("Hold")) \(Settings.shared.cfg.keyName) \(T("or")) \(Settings.shared.cfg.keyName2)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(height: 18)
            } else if state == .listening {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(Array(meter.samples.enumerated()), id: \.offset) { _, v in
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(width: 2.5, height: max(3, CGFloat(v) * 26))
                    }
                }
                .frame(height: 26)
                .animation(.linear(duration: 0.06), value: meter.samples)
            } else {
                Text(T("Transcribing…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(height: 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(Color.black.opacity(0.82))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(8)   // room for the shadow inside the panel
    }
}

final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?

    func show(_ state: HUDState, lang: String) {
        let view = NSHostingView(rootView: HUDView(state: state, lang: lang))
        view.frame.size = view.fittingSize

        let p = panel ?? makePanel()
        panel = p
        p.contentView = view
        p.setContentSize(view.fittingSize)
        position(p, state)
        p.orderFrontRegardless()
    }

    /// "Hidden" means back to the floating bar when it's enabled, otherwise gone.
    func hide() {
        Meter.shared.reset()
        if Settings.shared.cfg.floatingBar { show(.idle, lang: "") }
        else { panel?.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true       // must never steal focus — we paste into the focused app
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }

    /// Idle bar sits at the bottom; the active HUD sits under the menu bar.
    private func position(_ p: NSPanel, _ state: HUDState) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = p.frame.size
        let y = state == .idle ? vf.minY + 10 : vf.maxY - size.height - 6
        p.setFrameOrigin(CGPoint(x: vf.midX - size.width / 2, y: y))
    }
}
