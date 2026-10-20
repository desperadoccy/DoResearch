import CryptoKit
import Foundation

/// A failed operation. `code` is stable and shared by every transport; the HTTP API maps it to a status code and the
/// assistant receives the same JSON (`{"error": {"code", "message", ...details}}`) as its tool result.
struct OperationError: Error {
    let code: String
    let message: String
    var details: [String: Any] = [:]

    var json: [String: Any] {
        var body = details
        body["code"] = code
        body["message"] = message
        return ["error": body]
    }

    var httpStatus: Int {
        switch code {
        case "bad_request": 400
        case "unauthorized": 401
        case "item_not_found", "task_not_found", "project_not_found", "unknown_operation", "not_found": 404
        case "method_not_allowed": 405
        case "revision_conflict", "idempotency_conflict", "project_exists": 409
        case "payload_too_large": 413
        case "headers_too_large": 431
        case "storage_error": 500
        default: 422
        }
    }

    static func invalidField(_ field: String, _ message: String, allowed: [String]? = nil) -> OperationError {
        var details: [String: Any] = ["field": field]
        if let allowed { details["allowed"] = allowed }
        return OperationError(code: "invalid_field", message: message, details: details)
    }
    static func itemNotFound(_ id: String) -> OperationError {
        OperationError(code: "item_not_found", message: "No item with id \(id). Use list_items to find ids.", details: ["item_id": id])
    }
    static func projectNotFound(_ id: String) -> OperationError {
        OperationError(code: "project_not_found", message: "No project with id \(id). Use list_projects to find ids.", details: ["project_id": id])
    }
    static func badRequest(_ message: String) -> OperationError {
        OperationError(code: "bad_request", message: message)
    }
    static func storage(_ error: Error) -> OperationError {
        OperationError(code: "storage_error", message: "The change could not be saved, and nothing was changed: \(error.localizedDescription)")
    }
}

/// Who is calling and with what guarantees. Set by the transport, never by operation arguments, so an external
/// caller can't act as the assistant or the user.
struct OperationContext {
    /// `.agent` for the built-in assistant, `.api` for the local HTTP API.
    var author: Author
    var sourceChatID: String?
    var idempotencyKey: String?
    var expectedRevision: Int?
}

// MARK: - Canonical values

/// The one set of item statuses, with the experiment labels the HTTP API used first as aliases.
enum StatusName {
    static let values = ItemStatus.allCases.map(\.rawValue)
    /// "Running" → in_progress, and so on. Matched case-insensitively, like the canonical values.
    static let aliases: [String: ItemStatus] = Dictionary(uniqueKeysWithValues: ItemStatus.allCases.map { ($0.label(for: .experiment), $0) })

    static func parse(_ s: String) -> ItemStatus? {
        let key = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let status = ItemStatus.allCases.first(where: { $0.rawValue == key }) { return status }
        return aliases.first { $0.key.lowercased() == key }?.value
    }

    static func invalid(_ field: String, _ value: String) -> OperationError {
        .invalidField(field, "Unknown status “\(value)”. Use one of \(values.joined(separator: ", ")) (or an alias such as Running). "
                          + "A chat's own execution state (running, completed, failed) is not an item status; record it with add_log.",
                      allowed: values)
    }
}

// MARK: - Arguments

enum DateArg {
    case absent, clear, set(Date)
}

/// Typed access to operation arguments. Every accessor throws `invalid_field` naming the argument.
/// `null` counts as absent, so clients that send every optional key as null change nothing.
struct Args {
    let raw: [String: Any]

    private func present(_ key: String) -> Any? {
        guard let v = raw[key], !(v is NSNull) else { return nil }
        return v
    }

    func has(_ key: String) -> Bool { present(key) != nil }

    func string(_ key: String) throws -> String? {
        guard let v = present(key) else { return nil }
        guard let s = v as? String else { throw OperationError.invalidField(key, "\(key) must be a string.") }
        return s
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = try string(key) else { throw OperationError.invalidField(key, "\(key) is required.") }
        return s
    }

    /// A required string that must not be empty after trimming; returned trimmed.
    func requiredText(_ key: String) throws -> String {
        let s = try requiredString(key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw OperationError.invalidField(key, "\(key) must not be empty.") }
        return s
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = present(key) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw OperationError.invalidField(key, "\(key) must be a boolean.")
        }
        return n.boolValue
    }

    /// Whole numbers only: booleans and fractions are rejected rather than coerced.
    func int(_ key: String) throws -> Int? {
        guard let v = present(key) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.rounded() == n.doubleValue, abs(n.doubleValue) < 1e15 else {
            throw OperationError.invalidField(key, "\(key) must be an integer.")
        }
        return n.intValue
    }

    func stringArray(_ key: String) throws -> [String]? {
        guard let v = present(key) else { return nil }
        guard let a = v as? [Any], a.allSatisfy({ $0 is String }) else {
            throw OperationError.invalidField(key, "\(key) must be an array of strings.")
        }
        return a as? [String]
    }

    func enumValue<E: RawRepresentable & CaseIterable>(_ key: String, _ type: E.Type) throws -> E? where E.RawValue == String {
        guard let s = try string(key) else { return nil }
        guard let e = E(rawValue: s) else {
            throw OperationError.invalidField(key, "Invalid \(key) “\(s)”.", allowed: E.allCases.map(\.rawValue))
        }
        return e
    }

    /// YYYY-MM-DD, ISO 8601, or "now"; an empty string clears.
    func date(_ key: String) throws -> DateArg {
        guard let s = try string(key)?.trimmingCharacters(in: .whitespaces) else { return .absent }
        if s.isEmpty { return .clear }
        if s.lowercased() == "now" { return .set(Date()) }
        if let d = Wire.day(s) { return .set(d) }
        for f in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = f
            if let d = iso.date(from: s) { return .set(d) }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: s) { return .set(d) }
        }
        throw OperationError.invalidField(key, "\(key) must be YYYY-MM-DD or ISO 8601, got “\(s)”.")
    }
}

// MARK: - Wire formats

enum Wire {
    /// Calendar days (due dates, deadlines) in the user's time zone, as the app shows them.
    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func day(_ s: String) -> Date? {
        guard s.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else { return nil }
        return dayFormatter().date(from: s)
    }

    static func day(_ d: Date) -> String { dayFormatter().string(from: d) }

    /// Timestamps in ISO 8601 with the local UTC offset, e.g. 2026-10-20T09:41:07+08:00.
    static func time(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func data(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func string(_ value: Any) -> String { String(data: data(value), encoding: .utf8) ?? "{}" }

    /// Identifies a request's content for idempotency: the operation, its arguments, and the source chat.
    static func fingerprint(operation: String, arguments: [String: Any], sourceChatID: String?) -> String {
        let canonical = data(["operation": operation, "arguments": arguments, "source_chat_id": sourceChatID ?? NSNull()])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}
