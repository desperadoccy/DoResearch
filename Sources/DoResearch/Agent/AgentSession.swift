import Foundation
import Observation

/// Drives the in-app assistant: a manual tool-use loop over the Messages API.
/// History is append-only (assistant content is echoed back unchanged, including thinking blocks).
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

    @ObservationIgnored private var messages: [[String: Any]] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: Store
    private let maxIterations = 25

    init(store: Store) {
        self.store = store
    }

    var hasAPIKey: Bool { Keychain.resolveAPIKey() != nil }

    var model: String { UserDefaults.standard.string(forKey: "agentModel") ?? ClaudeClient.defaultModel }
    var effort: String { UserDefaults.standard.string(forKey: "agentEffort") ?? ClaudeClient.defaultEffort }

    func reset() {
        task?.cancel()
        task = nil
        messages = []
        entries = []
        isRunning = false
    }

    func cancel() {
        task?.cancel()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        guard let key = Keychain.resolveAPIKey() else {
            entries.append(Entry(role: .error, text: "Add your Anthropic API key in Settings (⌘,) to use the assistant.", isError: true))
            return
        }

        entries.append(Entry(role: .user, text: trimmed))
        var content: [[String: Any]] = []
        if let context = contextProvider?() {
            content.append(["type": "text", "text": "<app_context>\n\(context)\n</app_context>"])
        }
        content.append(["type": "text", "text": trimmed])
        appendUser(content)

        let client = ClaudeClient(apiKey: key, model: model, effort: effort)
        isRunning = true
        task = Task { [weak self] in
            await self?.runLoop(client)
            self?.isRunning = false
            self?.task = nil
        }
    }

    /// Consecutive user turns are merged so the history always alternates.
    private func appendUser(_ content: [[String: Any]]) {
        if var last = messages.last, last["role"] as? String == "user", var existing = last["content"] as? [[String: Any]] {
            existing.append(contentsOf: content)
            last["content"] = existing
            messages[messages.count - 1] = last
        } else {
            messages.append(["role": "user", "content": content])
        }
    }

    private func runLoop(_ client: ClaudeClient) async {
        let tools = AgentTools(store: store)
        for _ in 0..<maxIterations {
            let response: [String: Any]
            do {
                response = try await client.createMessage(system: systemPrompt(), messages: messages, tools: AgentTools.definitions)
            } catch is CancellationError {
                dropUnansweredUserTurn()
                entries.append(Entry(role: .notice, text: "Stopped."))
                return
            } catch let error as URLError where error.code == .cancelled {
                dropUnansweredUserTurn()
                entries.append(Entry(role: .notice, text: "Stopped."))
                return
            } catch {
                dropUnansweredUserTurn()
                entries.append(Entry(role: .error, text: error.localizedDescription, isError: true))
                return
            }

            let stopReason = response["stop_reason"] as? String
            let content = response["content"] as? [[String: Any]] ?? []

            if stopReason == "refusal" {
                handleRefusal()
                return
            }

            messages.append(["role": "assistant", "content": content])

            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { entries.append(Entry(role: .assistant, text: text)) }

            let toolUses = content.filter { $0["type"] as? String == "tool_use" }
            if toolUses.isEmpty {
                if stopReason == "max_tokens" {
                    entries.append(Entry(role: .notice, text: "The reply hit the length limit and was cut off."))
                }
                return
            }

            // Run every requested tool and return all results in one user message.
            var results: [[String: Any]] = []
            for use in toolUses {
                let id = use["id"] as? String ?? ""
                let name = use["name"] as? String ?? ""
                guard stopReason != "max_tokens", let input = use["input"] as? [String: Any] else {
                    results.append(["type": "tool_result", "tool_use_id": id, "is_error": true,
                                    "content": "Not executed: the tool input was incomplete. Try again with a smaller request."])
                    continue
                }
                let outcome = tools.run(name: name, input: input)
                entries.append(Entry(role: .tool, text: outcome.summary, isError: outcome.isError))
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": outcome.result]
                if outcome.isError { block["is_error"] = true }
                results.append(block)
            }
            appendUser(results)

            if Task.isCancelled {
                entries.append(Entry(role: .notice, text: "Stopped."))
                return
            }
        }
        entries.append(Entry(role: .notice, text: "Stopped after \(maxIterations) steps. Send a message to continue."))
    }

    /// Removes a trailing user turn that only holds the user's text (no tool results), so a retry doesn't send it twice.
    @discardableResult
    private func dropUnansweredUserTurn() -> Bool {
        guard messages.last?["role"] as? String == "user",
              let content = messages.last?["content"] as? [[String: Any]],
              content.allSatisfy({ $0["type"] as? String == "text" }) else { return false }
        messages.removeLast()
        return true
    }

    /// A declined turn has no usable content. Drop the unanswered user turn when it is plain text;
    /// mid-tool-loop the history can't be repaired append-only, so start over.
    private func handleRefusal() {
        if dropUnansweredUserTurn() {
            entries.append(Entry(role: .notice, text: "The model declined this request. Try rephrasing it."))
        } else {
            messages = []
            entries.append(Entry(role: .notice, text: "The model declined to continue. The conversation was reset; earlier messages are no longer in its context."))
        }
    }

    private func systemPrompt() -> [[String: Any]] {
        let today = Date().formatted(.dateTime.weekday(.wide).year().month(.wide).day())
        return [
            ["type": "text", "text": Self.instructions],
            ["type": "text", "text": "Today is \(today). Time zone: \(TimeZone.current.identifier)."],
        ]
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
    - Projects group items (for example one paper or research thread) and have an optional deadline.
    - Each message may include <app_context> describing what the user is looking at. "This" or "it" usually refers to that.

    Working rules:
    - Look before you write: list or get the relevant items and projects first, reuse existing projects, and don't create duplicates.
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
