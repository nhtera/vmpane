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
                Image(systemName: activity.takenOver ? "hand.raised.fill" : "sparkles")
                    .foregroundStyle(activity.takenOver ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(activity.client ?? "An AI agent") · \(activity.level.title)").font(.callout).bold().lineLimit(1)
                    Text(Self.status(activity)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if activity.takenOver {
                    Button("Resume") { Task { await model.resumeAgents() } }
                        .help("Let AI agents act on this VM again")
                } else {
                    Button("Take Over") { Task { await model.takeOver() } }
                        .help("Stop AI agents from changing this VM until you resume (typing or clicking in the VM does it too)")
                }
                Button("Stop", role: .destructive) { Task { await model.stopAgents() } }
                    .help("End what AI agents are doing in this VM: their commands, apps and transfers")
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
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
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .vmGlass(cornerRadius: 16)
        .opacity(activity.acting || activity.takenOver || expanded ? 1 : 0.75)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI agent activity")
    }

    static func status(_ activity: AgentActivity) -> String {
        if activity.stopped { return "Stopped by VMPane's kill switch" }
        if activity.takenOver { return "You took over: agents wait until you resume" }
        if activity.acting { return "\(activity.current ?? "working")…" }
        return activity.recent.first.map { "Idle · last: \($0.what)" } ?? "Idle"
    }
}

/// The tint around the VM's screen while an agent acts on it: it pulses, or stays still with Reduce Motion.
public struct AgentEdgeTint: View {
    let acting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(acting: Bool) {
        self.acting = acting
    }

    public var body: some View {
        Rectangle()
            .strokeBorder(.tint, lineWidth: 2)
            .opacity(acting ? (reduceMotion ? 0.8 : (pulse ? 0.9 : 0.35)) : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(acting && !reduceMotion ? .easeInOut(duration: 1.2).repeatForever() : .default, value: pulse)
            .onChange(of: acting, initial: true) { pulse = acting }
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
            Label(question.title, systemImage: "exclamationmark.shield.fill").font(.headline)
            Text("Allow it this once? Check what it does first.").foregroundStyle(.secondary)
            ScrollView {
                Text(question.detail)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 60, maxHeight: 180)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack {
                Spacer()
                Button("Allow Once") { answer(true) }
                Button("Deny") { answer(false) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
