import Foundation
import Network
import Observation
import Security

/// Serves `TaskAPI` over HTTP/1.1 on 127.0.0.1 while the app runs. One request per connection (`Connection: close`).
/// The bearer token and base URL are kept in a connection file next to the database (mode 0600), where local clients
/// such as Codex can read them.
@Observable
@MainActor
final class APIServer {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    static let defaultPort = 7428
    nonisolated static let maxBodyBytes = 1 << 20
    private nonisolated static let maxHeaderBytes = 16 << 10

    private(set) var state: State = .stopped
    private(set) var enabled: Bool
    private(set) var port: Int
    private(set) var token = ""

    let connectionFileURL: URL
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "DoResearch.api")

    private enum Keys {
        static let enabled = "api.enabled"
        static let port = "api.port"
    }

    init(store: Store, defaults: UserDefaults = .standard,
         connectionFileURL: URL = Database.defaultURL.deletingLastPathComponent().appendingPathComponent("api.json")) {
        self.store = store
        self.defaults = defaults
        self.connectionFileURL = connectionFileURL
        enabled = defaults.bool(forKey: Keys.enabled)
        let saved = defaults.integer(forKey: Keys.port)
        port = (1024...65535).contains(saved) ? saved : Self.defaultPort
        token = readToken() ?? ""
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Keys.enabled)
        on ? start() : stop()
    }

    func setPort(_ newPort: Int) {
        guard (1024...65535).contains(newPort), newPort != port else { return }
        port = newPort
        defaults.set(newPort, forKey: Keys.port)
        writeConnectionFile()
        if enabled {
            stop()
            start()
        }
    }

    /// Issues a new token; clients holding the old one get `unauthorized` from then on.
    func regenerateToken() {
        token = Self.makeToken()
        writeConnectionFile()
    }

    // MARK: Lifecycle

    func start() {
        stop()
        if token.isEmpty { token = Self.makeToken() }
        writeConnectionFile()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in self?.listenerChanged(newState, listener) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            state = .starting
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func listenerChanged(_ newState: NWListener.State, _ source: NWListener) {
        guard source === listener else { return }
        switch newState {
        case .ready: state = .running
        case .failed(let error):
            if case .posix(.EADDRINUSE) = error {
                state = .failed("Port \(port) is already in use.")
            } else {
                state = .failed(error.localizedDescription)
            }
            listener?.cancel()
            listener = nil
        default: break
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Drop clients that never finish sending a request.
        queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        let api = TaskAPI(store: store, token: token)
        Self.receive(connection, buffer: Data()) { request in
            await MainActor.run { api.handle(request) }
        }
    }

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data,
                                            handle: @escaping @Sendable (APIRequest) async -> APIResponse) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive(connection, buffer: buffer, handle: handle)
                }
            case .failed(let apiError):
                send(apiError.response, on: connection)
            case .request(let request):
                Task {
                    let response = await handle(request)
                    send(response, on: connection)
                }
            }
        }
    }

    private enum Parsed {
        case incomplete
        case failed(APIError)
        case request(APIRequest)
    }

    private nonisolated static func parse(_ buffer: Data) -> Parsed {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .failed(APIError(status: 431, code: "headers_too_large", message: "Request headers are too large.")) : .incomplete
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .failed(.badRequest("Request headers are not UTF-8."))
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return .failed(.badRequest("Malformed request line.")) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .failed(.badRequest("Chunked bodies are not supported; send Content-Length."))
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .failed(.badRequest("Invalid Content-Length.")) }
        guard length <= maxBodyBytes else {
            return .failed(APIError(status: 413, code: "payload_too_large", message: "Request bodies are limited to \(maxBodyBytes) bytes."))
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for q in components?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        return .request(APIRequest(method: String(requestLine[0]).uppercased(),
                                   path: components?.percentEncodedPath ?? target,
                                   query: query, headers: headers,
                                   body: Data(buffer[bodyStart..<(bodyStart + length)])))
    }

    private nonisolated static func send(_ response: APIResponse, on connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Token and connection file

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "dr_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func readToken() -> String? {
        guard let data = try? Data(contentsOf: connectionFileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    private func writeConnectionFile() {
        guard !token.isEmpty else { return }
        let info: [String: Any] = [
            "base_url": baseURL,
            "token": token,
            "auth": "Authorization: Bearer <token>",
            "api_version": TaskAPI.version,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: connectionFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Owner-only: the file holds the token.
        fm.createFile(atPath: connectionFileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connectionFileURL.path)
    }
}
