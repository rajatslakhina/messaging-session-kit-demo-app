import SwiftUI
import MessagingSession

// MARK: - App entry point

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            SessionConsoleView()
        }
    }
}

// MARK: - View model

/// Drives a live `MessageSession` against the package's fault-injecting in-memory server and
/// republishes its state for SwiftUI.
///
/// The session is an actor and the UI is main-actor-isolated, so the boundary is crossed exactly
/// once per frame by pulling a `SessionSnapshot` — a single `Sendable` value taken atomically
/// inside the actor. That is deliberate: reading half a dozen individual properties across
/// suspension points is how a UI ends up rendering a state that never actually existed, such as
/// `.active` next to an in-flight list from before the reconnect.
@MainActor
@Observable
final class SessionConsoleModel {

    // Published UI state
    private(set) var snapshot: SessionSnapshot?
    private(set) var log: [LogLine] = []
    private(set) var lossyAcks = false
    private(set) var lossyStream = false
    private(set) var refuseDials = false
    private(set) var isRunning = false

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case normal, good, warn, bad }
    }

    private let conversations = [
        ConversationID("general"),
        ConversationID("random")
    ]
    private var messageCounter = 0

    private let transport = InMemoryTransport(faults: .perfect)
    private let session: MessageSession
    private var pumpTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init() {
        session = MessageSession(
            configuration: .demo,
            transport: transport,
            clock: MonotonicClock(),
            jitter: RandomJitter()
        )
    }

    // MARK: Lifecycle

    func begin() {
        guard !isRunning else { return }
        isRunning = true

        // A fresh stream per subscription. Cancelling a shared AsyncStream finishes it for good,
        // so with one shared property this view going away once would silence the event feed for
        // the rest of the app's life.
        let events = session.makeEventStream()
        pumpTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.append(event)
            }
        }

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.session.tick()
                let latest = await self.session.snapshot()
                self.snapshot = latest
                // ~10 Hz. Time is pushed into the session rather than pulled from an internal
                // timer, which is what makes the same code path testable with a ManualClock.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        Task { await session.start() }
    }

    func end() {
        pumpTask?.cancel()
        tickTask?.cancel()
        pumpTask = nil
        tickTask = nil
        isRunning = false
        // Stop the session too, not just the observers. Leaving it connected and then calling
        // `start()` again on the next `onAppear` would be an illegal transition — which the session
        // correctly ignores and counts, but it would inflate the very `illegal events` metric this
        // demo presents as a production signal. A counter you pollute yourself is worthless.
        Task { await session.stop() }
    }

    // MARK: Controls

    func sendBurst(_ count: Int = 6) {
        // Clamped: a negative or absurd count from a future UI change must not produce a
        // negative range (which traps) or a multi-second stall.
        let safeCount = min(max(count, 1), 24)
        Task {
            for index in 0..<safeCount {
                messageCounter += 1
                // Bounds-safe by construction rather than by `%`: an empty `conversations` would
                // make `index % count` a division by zero, which traps.
                guard let conversation = conversations.isEmpty
                    ? nil
                    : conversations[index % conversations.count]
                else { return }
                await session.send("message #\(messageCounter)", to: conversation)
            }
        }
    }

    func dropSocket() {
        note("simulated socket drop", kind: .warn)
        Task { await transport.injectDisconnect() }
    }

    func toggleLossyAcks() {
        lossyAcks.toggle()
        note(lossyAcks ? "acks now dropped every 2nd message" : "acks restored", kind: .warn)
        applyFaults()
    }

    func toggleLossyStream() {
        lossyStream.toggle()
        note(lossyStream ? "every 3rd server broadcast will be skipped" : "broadcast stream restored",
             kind: .warn)
        applyFaults()
    }

    func toggleRefuseDials() {
        refuseDials.toggle()
        note(refuseDials ? "the server will now refuse every dial" : "dials accepted again", kind: .warn)
        applyFaults()
    }

    /// Replays the server's buffered history on the live connection — the case the second dedup
    /// layer exists for, and the only thing that moves `dupes killed`.
    func replayHistory() {
        note("server replaying buffered history", kind: .warn)
        Task { await transport.replayHistory() }
    }

    /// Every toggle feeds one plan — flipping one must not silently clear the others.
    private func applyFaults() {
        let plan = FaultPlan(
            dropAckEveryNth: lossyAcks ? 2 : 0,
            // Enough refusals to exhaust the demo backoff budget and reach `parked`, which is what
            // makes Revive a legal transition rather than an ignored one.
            failNextOpens: refuseDials ? 99 : 0,
            skipSequenceEveryNth: lossyStream ? 3 : 0
        )
        Task { await transport.configure(plan) }
    }

    func peerMessage() {
        // `conversations` is a non-empty constant literal, so `first` is always present; the
        // fallback keeps this total rather than force-unwrapping.
        let conversation = conversations.first ?? ConversationID("general")
        Task { await transport.deliverFromPeer(conversation: conversation, body: "hey there", author: "Priya") }
    }

    func restart() {
        Task {
            await session.stop()
            await session.start()
        }
    }

    func revive() {
        Task { await session.revive() }
    }

    // MARK: Event log

    private func append(_ event: SessionEvent) {
        switch event {
        case let .stateChanged(from, to):
            note("\(from.rawValue) → \(to.rawValue)", kind: to == .active ? .good : .normal)
        case let .messageSent(id, attempt):
            note("sent \(id.shortDescription)\(attempt > 1 ? " (retry \(attempt))" : "")",
                 kind: attempt > 1 ? .warn : .normal)
        case let .messageDelivered(id, attempts):
            note("acked \(id.shortDescription) after \(attempts) attempt(s)", kind: .good)
        case let .messageDeadLettered(id, reason):
            note("dead-lettered \(id.shortDescription): \(reason.rawValue)", kind: .bad)
        case let .redeliveryScheduled(count):
            note("requeued \(count) in-flight message(s)", kind: .warn)
        case let .messageReceived(message):
            note("received seq \(message.sequence) in \(message.conversation)", kind: .normal)
        case let .duplicateSuppressed(id):
            note("suppressed duplicate \(id.shortDescription)", kind: .good)
        case let .staleSuppressed(conversation, sequence, highWater):
            note("stale seq \(sequence) in \(conversation) (at \(highWater))", kind: .good)
        case let .gapDetected(conversation, missing):
            note("gap in \(conversation): \(missing) missing", kind: .bad)
        case let .backoffScheduled(delay, attempt):
            note(String(format: "backoff %.1fs (attempt %d)", delay, attempt), kind: .warn)
        case let .parked(reason):
            note("PARKED — \(reason)", kind: .bad)
        case let .coldStartRequired(reason):
            note("cold start: \(reason)", kind: .bad)
        case let .resumeCompleted(conversations):
            note("resumed \(conversations) conversation(s)", kind: .good)
        case let .messageRejected(id, reason):
            note("rejected \(id.shortDescription): \(reason)", kind: .bad)
        case let .illegalTransition(description):
            note("ignored illegal event — \(description)", kind: .warn)
        case let .messageEnqueued(id):
            note("queued \(id.shortDescription)", kind: .normal)
        }
    }

    private func note(_ text: String, kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
        // Bounded: an unbounded log in a long-lived demo is a memory leak with a slow fuse.
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

// MARK: - View

struct SessionConsoleView: View {
    @State private var model = SessionConsoleModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stateHeader
                    metricsGrid
                    controls
                    queueSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("Session Console")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { model.begin() }
        .onDisappear { model.end() }
    }

    // MARK: Header

    private var stateHeader: some View {
        let state = model.snapshot?.state
        return HStack(spacing: 12) {
            Circle()
                .fill(color(for: state))
                .frame(width: 14, height: 14)
            Text(state?.rawValue ?? "starting")
                .font(.title2.weight(.semibold))
                .monospaced()
            Spacer()
            if let retry = model.snapshot?.retryIn, retry > 0 {
                Text(String(format: "retry in %.1fs", retry))
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func color(for state: ConnectionState?) -> Color {
        switch state {
        case .active: return .green
        case .connecting, .authenticating, .resuming: return .yellow
        case .backingOff: return .orange
        case .parked: return .red
        case .idle, .none: return .gray
        }
    }

    // MARK: Metrics

    private var metricsGrid: some View {
        let metrics = model.snapshot?.metrics ?? SessionMetrics()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            metric("sent", metrics.sent)
            metric("acked", metrics.acked, tint: .green)
            metric("redelivered", metrics.redelivered, tint: .orange)
            metric("received", metrics.inboundAccepted)
            metric("dupes killed", metrics.inboundDuplicates, tint: .green)
            metric("gaps", metrics.gapsDetected, tint: .red)
            metric("dead letters", metrics.deadLettered, tint: .red)
            metric("connects", metrics.connectAttempts)
            metric("illegal events", metrics.illegalTransitions, tint: .orange)
        }
    }

    private func metric(_ label: String, _ value: Int, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button("Send 6") { model.sendBurst() }
                    .buttonStyle(.borderedProminent)
                Button("Peer msg") { model.peerMessage() }
                    .buttonStyle(.bordered)
                Button("Replay") { model.replayHistory() }
                    .buttonStyle(.bordered)
                Button("Drop socket") { model.dropSocket() }
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }
            HStack(spacing: 10) {
                Button(model.lossyAcks ? "Acks: lossy" : "Acks: reliable") { model.toggleLossyAcks() }
                    .buttonStyle(.bordered)
                    .tint(model.lossyAcks ? .red : .green)
                Button(model.lossyStream ? "Stream: lossy" : "Stream: clean") { model.toggleLossyStream() }
                    .buttonStyle(.bordered)
                    .tint(model.lossyStream ? .red : .green)
                Button(model.refuseDials ? "Dials: refused" : "Dials: open") { model.toggleRefuseDials() }
                    .buttonStyle(.bordered)
                    .tint(model.refuseDials ? .red : .green)
                Button("Restart") { model.restart() }
                    .buttonStyle(.bordered)
                Button("Revive") { model.revive() }
                    .buttonStyle(.bordered)
                    .tint(.purple)
            }
        }
        .font(.footnote)
    }

    // MARK: Queues

    private var queueSection: some View {
        let snapshot = model.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text("OUTBOX").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            queueRow("in flight", snapshot?.inFlight ?? [], tint: .blue)
            queueRow("pending", snapshot?.pending ?? [], tint: .secondary)
            queueRow("dead letters", snapshot?.deadLetters ?? [], tint: .red)
        }
    }

    private func queueRow(_ title: String, _ entries: [Outbox.Entry], tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.monospaced())
                .foregroundStyle(tint)
                .frame(width: 90, alignment: .leading)
            if entries.isEmpty {
                Text("—").font(.caption.monospaced()).foregroundStyle(.tertiary)
            } else {
                // `prefix` is safe on any count, including zero, and caps the row's width.
                Text(entries.prefix(8).map { "\($0.id.shortDescription)·\($0.attempts)" }
                    .joined(separator: "  "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(tint)
            }
            Spacer()
        }
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EVENT STREAM").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            if model.log.isEmpty {
                Text("waiting for events…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.log.suffix(24).reversed()) { line in
                    Text(line.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(tint(for: line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tint(for kind: SessionConsoleModel.LogLine.Kind) -> Color {
        switch kind {
        case .normal: return .primary
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }
}
