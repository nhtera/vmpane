import SwiftUI
import VMPaneCore
import VMPaneHost

/// Who is acting on the VM, at what level and what they just did, with Take Over (or Resume) and Stop: a pill at the
/// top of the VM's window while an AI agent works in it, and a thin tint around the screen while it acts.
public struct AgentHUD: View {
    @Bindable var model: HelperViewModel
    @State private var expanded = false
    /// Idle for a while: only a dot, so the pill does not cover the guest's screen.
    @State private var folded = false

    public init(model: HelperViewModel) {
        self.model = model
    }

    public var body: some View {
        if let activity = model.activity, activity.visible {
            let busy = activity.acting || activity.takenOver
            Group {
                if folded && !busy && !expanded {
                    Button {
                        withAnimation { folded = false }
                    } label: {
                        Image(systemName: "sparkles").padding(7)
                    }
                    .buttonStyle(.plain)
                    .vmGlass(cornerRadius: 14)
                    .help("AI agents used this VM: show what they did")
                    .accessibilityLabel("Show AI agent activity")
                } else {
                    pill(activity)
                }
            }
            .task(id: "\(busy) \(expanded) \(folded)") {
                guard !busy, !expanded else {
                    folded = false
                    return
                }
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { withAnimation { folded = true } }
            }
        }
    }

    private func pill(_ activity: AgentActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SectionIcon(activity.takenOver ? "hand.raised.fill" : "sparkles", color: activity.takenOver ? .orange : .blue, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(activity.client ?? "An AI agent") · \(activity.level.title)").font(.callout).bold().lineLimit(1)
                    Text(Self.status(activity)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                controls(activity)
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel(expanded ? "Hide recent actions" : "Show recent actions")
                .disabled(activity.recent.isEmpty)
            }
            if expanded {
                ForEach(activity.recent.prefix(3)) { action in
                    HStack(spacing: 6) {
                        Image(systemName: action.ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(action.ok ? .green : .red)
                        Text(action.what.prefix(1).uppercased() + action.what.dropFirst())
                        Spacer()
                        Text(action.when, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .vmGlass(cornerRadius: 16)
        .opacity(activity.acting || activity.takenOver || expanded ? 1 : 0.75)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI agent activity")
    }

    /// Take Over (Resume once taken over) and Stop.
    @ViewBuilder private func controls(_ activity: AgentActivity) -> some View {
        if activity.takenOver {
            Button("Resume") { Task { await model.resumeAgents() } }
                .vmCapsule(prominent: true, large: false)
                .help("Let AI agents act on this VM again")
        } else {
            Button("Take Over") { Task { await model.takeOver() } }
                .vmCapsule(large: false)
                .help("Stop AI agents from changing this VM until you resume (typing or clicking in the VM does it too)")
        }
        Button("Stop", role: .destructive) { Task { await model.stopAgents() } }
            .vmCapsule(prominent: true, large: false)
            .tint(.red)  // a tint shows on a prominent button only (macOS 15)
            .help("End what AI agents are doing in this VM: their commands, apps and transfers")
    }

    static func status(_ activity: AgentActivity) -> String {
        if activity.stopped { return "Stopped by VMPane's kill switch" }
        if activity.takenOver { return "You took over: agents wait until you resume" }
        if activity.acting { return "\(activity.current ?? "working")…" }
        return activity.recent.first.map { "Idle · last: \($0.what)" } ?? "Idle"
    }
}

/// The tint around the VM's screen: blue while an agent acts on it (it pulses, or stays still with Reduce Motion),
/// orange and still while the person has taken over.
public struct AgentEdgeTint: View {
    let acting: Bool
    let takenOver: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var pulsing: Bool { acting && !takenOver && !reduceMotion }

    public init(acting: Bool, takenOver: Bool = false) {
        self.acting = acting
        self.takenOver = takenOver
    }

    public var body: some View {
        Rectangle()
            .strokeBorder(takenOver ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint), lineWidth: 2)
            .opacity(takenOver ? 0.8 : acting ? (pulsing ? (pulse ? 0.9 : 0.35) : 0.8) : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(pulsing ? .easeInOut(duration: 1.2).repeatForever() : .default, value: pulse)
            .id(pulsing)  // a new view when the pulse starts or ends: the endless animation goes with the old one
            .onChange(of: pulsing, initial: true) { pulse = pulsing }
    }
}

/// An agent's request for the person's yes, in the VM's window: what exactly it wants to do, Deny (the default, and
/// Return) or Allow Once. No answer within the helper's minute is a no.
public struct ApprovalSheet: View {
    let question: ConfirmationRequest
    let answer: (Bool) -> Void

    public init(question: ConfirmationRequest, answer: @escaping (Bool) -> Void) {
        self.question = question
        self.answer = answer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SectionIcon("exclamationmark.shield.fill", color: .orange, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.title).font(.headline)
                    Text("Allow it this once? Check what it does first. No answer within a minute is a no.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(question.detail)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 60, maxHeight: 180)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Spacer()
                Button("Allow Once") { answer(true) }.vmCapsule(large: false)
                Button("Deny") { answer(false) }.keyboardShortcut(.defaultAction).vmCapsule(prominent: true, large: false)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
