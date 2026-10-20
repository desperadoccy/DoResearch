import Foundation

struct ToolOutcome {
    let result: String
    let summary: String
    let isError: Bool
}

/// The assistant's tools: the shared operations of `OperationRegistry`, run through `OperationService` as the
/// assistant (`author: .agent`), so they are the same operations, arguments, and results the local API offers.
@MainActor
struct AgentTools {
    let store: Store

    static var definitions: [[String: Any]] { OperationRegistry.all.map(\.toolDefinition) }

    /// `expectedRevision` and `idempotencyKey` come from the app, never from the model's arguments, like the
    /// envelope fields of an API request.
    func run(name: String, input: [String: Any], expectedRevision: Int? = nil, idempotencyKey: String? = nil) -> ToolOutcome {
        let context = OperationContext(author: .agent, idempotencyKey: idempotencyKey, expectedRevision: expectedRevision)
        let response = OperationService(store: store).invoke(name, input, context: context)
        return ToolOutcome(result: Wire.string(response.body), summary: response.summary, isError: response.error != nil)
    }
}
