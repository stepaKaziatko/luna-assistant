import Foundation

// MARK: - Разбор потока `claude -p --output-format stream-json --include-partial-messages`
//
// Только Foundation. Каждая строка вывода — JSON-объект. Нужны четыре вида событий:
//   stream_event / content_block_delta (text_delta)  — куски ответа;
//   assistant (с полем error)                        — «не вошёл» (authentication_failed);
//   rate_limit_event                                 — статус лимита подписки и время сброса;
//   result                                           — итог: is_error, текст, api_error_status, errors.
// Остальное (init, status, usage) пропускается. Битая строка и пустой вывод разбор не роняют.

enum ClaudeCLIError: Error, Equatable {
    case notFound                       // бинаря нет
    case notLoggedIn                    // CLI не вошёл
    case rateLimited(resetsAt: Date?)   // лимит подписки исчерпан
    case api(String)                    // ошибка, которую вернул сам CLI
    case timeout                        // нет вывода дольше таймаута
    case failed(status: Int32, tail: String)   // процесс упал; хвост stderr ≤ 400 символов
    case empty                          // завершился без текста
    case cancelled                      // «Новый разговор» или выход из Luna
    case unavailable                    // сборка без запуска процессов
    case projectFolderMissing(String)   // папки проекта нет: `claude` не запускался
    case projectFolderNoAccess(String)  // macOS не дала доступ к папке проекта
    case sessionNotFound                // `--resume` сессии, которой у Claude Code нет (LUNA-76)
}

struct ClaudeStreamParser {
    private var buffer = Data()
    private var pendingSeparator = false

    /// Видимый текст ответа: все текстовые блоки подряд (между блоками — пустая строка).
    private(set) var text = ""
    private(set) var sessionID: String?
    private(set) var rateLimitStatus: String?
    private(set) var rateLimitResetsAt: Date?
    private(set) var assistantError: String?
    private(set) var resultSeen = false
    private(set) var resultIsError = false
    private(set) var resultText: String?
    private(set) var resultAPIStatus: Int?
    /// `errors` итога: у `--resume` несуществующей сессии — «No conversation found with session ID: …».
    private(set) var resultErrors: [String] = []
    /// Текст из полных `assistant`-сообщений: запасной путь, если кусков не было.
    private var assistantText = ""
    private var sawDelta = false

    var rateLimited: Bool {
        guard let status = rateLimitStatus else { return false }
        return !status.hasPrefix("allowed")
    }

    /// Скармливает очередную порцию вывода; true — видимый текст изменился.
    @discardableResult
    mutating func feed(_ data: Data) -> Bool {
        buffer.append(data)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if handle(line: line) { changed = true }
        }
        return changed
    }

    /// Конец вывода: последняя строка могла прийти без перевода строки.
    @discardableResult
    mutating func finish() -> Bool {
        guard !buffer.isEmpty else { return false }
        let line = buffer
        buffer.removeAll()
        return handle(line: line)
    }

    private mutating func handle(line: Data) -> Bool {
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { return false }
        if let id = object["session_id"] as? String { sessionID = id }
        switch type {
        case "stream_event":
            return handleStreamEvent(object["event"] as? [String: Any] ?? [:])
        case "assistant":
            if let error = object["error"] as? String { assistantError = error }
            if let message = object["message"] as? [String: Any],
               let blocks = message["content"] as? [[String: Any]] {
                let joined = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n\n")
                if !joined.isEmpty { assistantText += (assistantText.isEmpty ? "" : "\n\n") + joined }
            }
            return false
        case "rate_limit_event":
            if let info = object["rate_limit_info"] as? [String: Any] {
                rateLimitStatus = info["status"] as? String
                if let seconds = (info["resetsAt"] as? NSNumber)?.doubleValue {
                    rateLimitResetsAt = Date(timeIntervalSince1970: seconds)
                }
            }
            return false
        case "result":
            resultSeen = true
            resultIsError = object["is_error"] as? Bool ?? false
            resultText = object["result"] as? String
            resultAPIStatus = (object["api_error_status"] as? NSNumber)?.intValue
            resultErrors = (object["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
            return false
        default:
            return false
        }
    }

    private mutating func handleStreamEvent(_ event: [String: Any]) -> Bool {
        switch event["type"] as? String {
        case "content_block_start":
            // Новый текстовый блок после предыдущего (например, после поиска в сети).
            if let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "text", !text.isEmpty {
                pendingSeparator = true
            }
            return false
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let piece = delta["text"] as? String, !piece.isEmpty else { return false }
            if pendingSeparator {
                if !text.hasSuffix("\n") { text += "\n\n" }
                pendingSeparator = false
            }
            text += piece
            sawDelta = true
            return true
        default:
            return false
        }
    }

    /// Так `claude` (2.1.x) сообщает, что сессии для `--resume` нет: в `errors` итога и в stderr.
    static let sessionNotFoundMarker = "No conversation found with session ID"

    /// Итог по тому, что разобрано, и коду выхода. `stderrTail` — хвост stderr для сообщения о сбое.
    func outcome(exitStatus: Int32, stderrTail: String = "") -> Result<String, ClaudeCLIError> {
        let reply = (sawDelta ? text : assistantText).trimmingCharacters(in: .whitespacesAndNewlines)
        if assistantError == "authentication_failed"
            || (resultIsError && (resultText ?? "").localizedCaseInsensitiveContains("not logged in")) {
            return .failure(.notLoggedIn)
        }
        if !sawDelta, assistantText.isEmpty, resultIsError || exitStatus != 0,
           (resultErrors + [resultText ?? "", stderrTail]).contains(where: {
               $0.localizedCaseInsensitiveContains(Self.sessionNotFoundMarker)
           }) {
            return .failure(.sessionNotFound)
        }
        if rateLimited, assistantError != nil || resultIsError {
            return .failure(.rateLimited(resetsAt: rateLimitResetsAt))
        }
        if assistantError == "rate_limit" || (resultIsError && resultAPIStatus == 429) {
            return .failure(.rateLimited(resetsAt: rateLimitResetsAt))
        }
        if resultIsError || assistantError != nil {
            let message = (resultText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.api(message.isEmpty ? (assistantError ?? "error") : message))
        }
        if exitStatus != 0 {
            return .failure(.failed(status: exitStatus, tail: stderrTail))
        }
        if reply.isEmpty {
            let fallback = (resultText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? .failure(.empty) : .success(fallback)
        }
        return .success(reply)
    }
}
