import Foundation
import Observation

/// Drives the in-app assistant: a manual tool-use loop over whichever provider is active.
/// The transcript is provider-neutral and append-only, so switching providers mid-conversation keeps the context,
/// and turns an Anthropic model produced are echoed back to it unchanged (thinking blocks included).
@Observable
@MainActor
final class AgentSession {
    struct Entry: Identifiable {
        enum Role { case user, assistant, tool, error, notice }
        let id = UUID()
        let role: Role
        let text: String
        var isError = false
    }

    private(set) var entries: [Entry] = []
    private(set) var isRunning = false
    /// Supplies a short description of what the user is looking at, attached to each message.
    @ObservationIgnored var contextProvider: (() -> String?)?

    @ObservationIgnored private var transcript: [ChatTurn] = []
    @ObservationIgnored private var lastProviderID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: Store
    let providers: ProviderStore
    private let maxIterations = 25
    private let maxTokens = 16000

    init(store: Store, providers: ProviderStore) {
        self.store = store
        self.providers = providers
    }

    /// Why the active provider can't be used yet, if it can't.
    var setupProblem: String? {
        guard let p = providers.active else { return "Add a model provider in Settings → Providers." }
        if p.model.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a model for \(p.name) in Settings → Providers." }
        if p.host == "api.anthropic.com", p.apiKey == nil { return "Add an API key for \(p.name) in Settings → Providers." }
        return nil
    }

    /// Softer hint: hosted OpenAI-compatible services need a key, but we still let the server say so.
    var missingKeyHint: Bool {
        guard let p = providers.active else { return false }
        return p.requiresKey && p.apiKey == nil
    }

    func reset() {
        task?.cancel()
        task = nil
        transcript = []
        entries = []
        lastProviderID = nil
        isRunning = false
    }

    func cancel() {
        task?.cancel()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        if let problem = setupProblem {
            entries.append(Entry(role: .error, text: problem, isError: true))
            return
        }
        let provider = providers.active!

        if let last = lastProviderID, last != provider.id, !transcript.isEmpty {
            entries.append(Entry(role: .notice, text: "Switched to \(provider.name) · \(provider.model). The conversation continues."))
        }
        entries.append(Entry(role: .user, text: trimmed))
        var parts: [String] = []
        if let context = contextProvider?() { parts.append("<app_context>\n\(context)\n</app_context>") }
        parts.append(trimmed)
        transcript.append(.user(parts))

        let client = makeClient(for: provider)
        isRunning = true
        task = Task { [weak self] in
            await self?.runLoop(client, provider: provider)
            self?.isRunning = false
            self?.task = nil
        }
    }

    private func runLoop(_ client: ModelClient, provider: ProviderConfig) async {
        let tools = AgentTools(store: store)
        let specs = ToolSpec.from(anthropic: AgentTools.definitions)
        for _ in 0..<maxIterations {
            let reply: ModelReply
            do {
                reply = try await client.send(system: systemPrompt(), turns: transcript, tools: specs, maxTokens: maxTokens)
            } catch is CancellationError {
                dropUnansweredUserTurn()
                entries.append(Entry(role: .notice, text: "Stopped."))
                return
            } catch {
                dropUnansweredUserTurn()
                entries.append(Entry(role: .error, text: error.localizedDescription, isError: true))
                return
            }

            if case .refusal(let explanation) = reply.stop {
                handleRefusal(explanation)
                return
            }

            transcript.append(.assistant(reply.turn))
            lastProviderID = provider.id
            if provider.kind == .anthropic, reply.model != provider.model {
                entries.append(Entry(role: .notice, text: "Answered by \(reply.model) (fallback model)."))
            }
            if !reply.turn.text.isEmpty { entries.append(Entry(role: .assistant, text: reply.turn.text)) }

            let calls = reply.turn.toolCalls
            if calls.isEmpty {
                if reply.stop == .maxTokens {
                    entries.append(Entry(role: .notice, text: "The reply hit the length limit and was cut off."))
                }
                return
            }

            // Run every requested tool and return all results together.
            var results: [ToolResult] = []
            for call in calls {
                guard reply.stop != .maxTokens, let input = call.input else {
                    let why = reply.stop == .maxTokens ? "the tool input was cut off" : "the arguments weren't a valid JSON object"
                    entries.append(Entry(role: .tool, text: "\(call.name) skipped: \(why)", isError: true))
                    results.append(ToolResult(callID: call.id, content: "Not executed: \(why). Try again.", isError: true))
                    continue
                }
                let outcome = tools.run(name: call.name, input: input)
                entries.append(Entry(role: .tool, text: outcome.summary, isError: outcome.isError))
                results.append(ToolResult(callID: call.id, content: outcome.result, isError: outcome.isError))
            }
            transcript.append(.toolResults(results))

            if Task.isCancelled {
                entries.append(Entry(role: .notice, text: "Stopped."))
                return
            }
        }
        entries.append(Entry(role: .notice, text: "Stopped after \(maxIterations) steps. Send a message to continue."))
    }

    /// Removes a trailing user message that got no answer, so a retry doesn't send it twice.
    @discardableResult
    private func dropUnansweredUserTurn() -> Bool {
        guard case .user = transcript.last else { return false }
        transcript.removeLast()
        return true
    }

    /// A declined turn has no usable content. Drop the unanswered user message when there is one;
    /// mid-tool-loop the history can't be repaired append-only, so start over.
    private func handleRefusal(_ explanation: String?) {
        let detail = explanation.map { " (\($0))" } ?? ""
        if dropUnansweredUserTurn() {
            entries.append(Entry(role: .notice, text: "The model declined this request\(detail). Try rephrasing it."))
        } else {
            transcript = []
            lastProviderID = nil
            entries.append(Entry(role: .notice, text: "The model declined to continue\(detail). The conversation was reset; earlier messages are no longer in its context."))
        }
    }

    private func systemPrompt() -> [String] {
        let today = Date().formatted(.dateTime.weekday(.wide).year().month(.wide).day())
        return [Self.instructions, "Today is \(today). Time zone: \(TimeZone.current.identifier)."]
    }

    // MARK: Connection test

    struct TestResult {
        enum Level { case ok, warning, failure }
        let level: Level
        let message: String
    }

    /// Sends one tiny request with a single tool, checking auth, the model name, and tool-calling support.
    static func test(_ provider: ProviderConfig) async -> TestResult {
        let ping = ToolSpec(name: "ping", description: "Connectivity check.", schema: [
            "type": "object", "properties": ["message": ["type": "string"]], "required": ["message"],
        ])
        do {
            let reply = try await makeClient(for: provider).send(
                system: ["You are a connectivity check."],
                turns: [.user(["Call the ping tool with message \"ok\"."])],
                tools: [ping], maxTokens: 2048
            )
            if case .refusal = reply.stop { return TestResult(level: .warning, message: "Connected, but the model declined the test request.") }
            if reply.turn.toolCalls.contains(where: { $0.name == "ping" }) {
                return TestResult(level: .ok, message: "Connected to \(reply.model). Tool calling works.")
            }
            return TestResult(level: .warning, message: "Connected to \(reply.model), but it answered without calling the tool. The assistant needs a model with tool (function) calling.")
        } catch {
            return TestResult(level: .failure, message: error.localizedDescription)
        }
    }

    private static let instructions = """
    You are the assistant built into DoResearch, a macOS app where a computer science researcher tracks their work: research, \
    paper writing, experiments, personal matters, and miscellaneous tasks. You read and change their data only through the \
    provided tools. Everything you change is recorded in the item's progress log as done by the assistant.

    How the data is organized:
    - Items have a kind: coding (implementation work: features, refactors, bug fixes, infrastructure), experiment (running, \
    measuring, evaluating, ablations), writing (paper or report text), reading (papers to read), task (other research work), \
    personal, and misc.
    - Statuses are shared but read differently per kind: for experiments, todo = Planned, in_progress = Running, \
    waiting = Analyzing, done = Concluded; for coding, in_progress = In Development, waiting = In Review, done = Merged. \
    inbox means not yet triaged; dropped replaces deletion.
    - Experiments carry hypothesis, setup, compute, run times, metrics, results, an outcome (pending/supported/refuted/\
    inconclusive/failed), and a conclusion. Coding items carry repo, branch, a PR/issue link, and a checklist of implementation steps.
    - Any item can track a measurable count toward a target (progress_target, progress_unit), e.g. "read 10 papers" is one \
    item at 0/10 papers. When the user reports progress on such work ("read two more"), use progress_add on the existing \
    item rather than creating new items. Reaching the target marks it done.
    - Projects group items and have a type. research projects are papers, research threads, or systems, and hold \
    coding, experiment, writing, reading, and task items. personal projects are areas or efforts in the user's life \
    (health, finances, a trip, a move) and hold personal items. misc projects group everything else (errands, admin, \
    reviewing duties) and hold misc items. Personal and misc projects are often ongoing; a deadline is optional.
    - Each message may include <app_context> describing what the user is looking at. "This" or "it" usually refers to that.

    Working rules:
    - Look before you write: list or get the relevant items and projects first, reuse existing projects, and don't create duplicates.
    - File items into a project of the matching type, and give them the kind that type holds. Don't put personal or \
    misc items into research projects or the reverse; if no fitting project exists, leave the item unassigned or offer \
    to create one of the right type.
    - Keep coding and experimental work separate. Building the thing is coding; running or evaluating it is an experiment. \
    When a request covers both, create one item of each and mention the relationship in their notes.
    - Turn loose descriptions into well-formed items: a concise title, the right kind and project, details in notes, and \
    concrete next steps in the checklist.
    - When progress is reported, update the status and fields, and add a short `log` entry describing what happened, so the \
    timeline stays accurate.
    - Record numbers, metrics, and results exactly as the user gives them. Never invent results, and don't mark an \
    experiment's outcome unless the user stated it or it follows directly from the numbers they gave.
    - Mark items dropped instead of deleting them. You cannot delete items.
    - If a request is ambiguous in a way that changes what you would create or modify, ask one short question instead of guessing.
    - When asked for a review, use review_summary and write a compact report grounded in the data: what moved, experiment \
    outcomes, coding status, what is blocked or stale, and two or three concrete suggestions for what to do next.

    Reply style: brief and direct. After making changes, state what you changed using item titles. Use Markdown sparingly \
    (bold and short lists are fine; no headings or tables).
    """
}
