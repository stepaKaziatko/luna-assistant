import Foundation

struct RpcFailure: LocalizedError {
    let code: Int
    let message: String

    var errorDescription: String? { message }
}

enum CoreClientError: LocalizedError {
    case notRunning

    var errorDescription: String? { "Ядро не запущено." }
}

/// Запускает ядро дочерним процессом и говорит с ним по JSON-RPC 2.0: одно сообщение — одна строка в stdio.
final class CoreClient: @unchecked Sendable {
    /// Любое уведомление task.* несёт полный снимок задачи.
    var onTaskEvent: (@MainActor (TaskInfo) -> Void)?
    var onExit: (@MainActor (Int32) -> Void)?

    private let launch: CoreLaunch
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    // Очередь защищает buffer, pending и nextId.
    private let queue = DispatchQueue(label: "luna.core-client")
    private var buffer = Data()
    private var pending: [Int: (Result<Data, Error>) -> Void] = [:]
    private var nextId = 1

    init(launch: CoreLaunch) {
        self.launch = launch
    }

    func start() throws {
        process.executableURL = launch.node
        process.arguments = [launch.entry.path]
        process.environment = launch.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                let waiting = self.pending.values
                self.pending.removeAll()
                waiting.forEach { $0(.failure(CoreClientError.notRunning)) }
            }
            let status = process.terminationStatus
            _Concurrency.Task { @MainActor in self.onExit?(status) }
        }
        try process.run()
    }

    /// Закрывает stdin: ядро по EOF отменяет задачи и завершается само.
    func stop() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    func request<R: Decodable>(_ method: String) async throws -> R {
        try await request(method, NoParams())
    }

    func request<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        let line: Data = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.process.isRunning else {
                    continuation.resume(throwing: CoreClientError.notRunning)
                    return
                }
                let id = self.nextId
                self.nextId += 1
                do {
                    var data = try JSONEncoder().encode(Request(id: id, method: method, params: params))
                    data.append(0x0A)
                    self.pending[id] = { continuation.resume(with: $0) }
                    try self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
                } catch {
                    if self.pending.removeValue(forKey: id) != nil { continuation.resume(throwing: error) }
                }
            }
        }
        return try JSONDecoder().decode(Response<R>.self, from: line).result
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { handle(line) }
        }
    }

    private func handle(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { return }

        if let method = envelope.method {
            guard method.hasPrefix("task."),
                  let event = try? JSONDecoder().decode(Notification<TaskEventParams>.self, from: line) else { return }
            _Concurrency.Task { @MainActor in self.onTaskEvent?(event.params.task) }
            return
        }

        guard let id = envelope.id, let complete = pending.removeValue(forKey: id) else { return }
        if let error = envelope.error {
            complete(.failure(RpcFailure(code: error.code, message: error.message)))
        } else {
            complete(.success(line))
        }
    }
}

private struct NoParams: Encodable {}

private struct Request<P: Encodable>: Encodable {
    var jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: P
}

private struct Envelope: Decodable {
    struct ErrorBody: Decodable {
        let code: Int
        let message: String
    }

    let id: Int?
    let method: String?
    let error: ErrorBody?
}

private struct Response<R: Decodable>: Decodable {
    let result: R
}

private struct Notification<P: Decodable>: Decodable {
    let params: P
}
