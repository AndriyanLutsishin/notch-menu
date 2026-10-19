import Foundation
import NotchCore

/// Запускає вбудований Claude Code і передає відповідь шматочками (як друкується).
/// Порожня тимчасова папка, жодних інструментів — Claude лише відповідає текстом.
final class ClaudeCodeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    /// Натиснули «Зупинити» (навіть до запуску процесу).
    private var cancelled = false
    static let executable = ClaudeCode.findExecutable()

    func run(prompt: String, model: AskProvider, onEvent: @escaping @Sendable (ClaudeAPI.StreamEvent) -> Void) async throws {
        guard let executable = Self.executable else {
            throw CodexRunner.Failure(message: "Не знайшов Claude Code. Онови застосунок Claude desktop.")
        }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchMenu-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ClaudeCode.arguments(model: model)
        p.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")  // лише підписка
        p.environment = env

        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    if lock.withLock({ cancelled }) { cont.resume(throwing: CancellationError()); return }
                    do { try p.run() } catch {
                        cont.resume(throwing: CodexRunner.Failure(message: "Не вдалося запустити Claude: \(error.localizedDescription)"))
                        return
                    }
                    lock.withLock {
                        process = p
                        if cancelled { p.terminate() }  // «Зупинити» натиснули саме в момент запуску
                    }
                    try? input.fileHandleForReading.close()  // цей кінець належить дочірньому процесу
                    // Пишемо питання окремо (не блокуємо читання відповіді); дуже довгі тексти обрізаємо.
                    let payload = Data(String(prompt.prefix(100_000)).utf8)
                    DispatchQueue.global().async {
                        try? input.fileHandleForWriting.write(contentsOf: payload)
                        try? input.fileHandleForWriting.close()
                    }

                    var errData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errData = errors.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    // Читаємо рядок за рядком, щоб показувати текст одразу.
                    var buffer = Data()
                    var gotResult = false
                    let reader = output.fileHandleForReading
                    while true {
                        let chunk = reader.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[buffer.startIndex..<nl]
                            buffer.removeSubrange(buffer.startIndex...nl)
                            if let event = ClaudeCode.parseLine(String(decoding: lineData, as: UTF8.self)) {
                                if case .stop = event { gotResult = true }
                                if case .error = event { gotResult = true }
                                onEvent(event)
                            }
                        }
                    }
                    p.waitUntilExit()
                    group.wait()
                    lock.withLock { if process === p { process = nil } }

                    if p.terminationReason == .uncaughtSignal {
                        // Зупинили ми — це «скасовано»; інакше процес упав сам.
                        cont.resume(throwing: lock.withLock({ cancelled }) ? CancellationError()
                                    : CodexRunner.Failure(message: "Claude несподівано завершився. Спробуй ще раз."))
                    } else if !gotResult && p.terminationStatus != 0 {
                        let err = String(decoding: errData, as: UTF8.self)
                        cont.resume(throwing: CodexRunner.Failure(message: ClaudeCode.friendlyError(err.trimmingCharacters(in: .whitespacesAndNewlines))))
                    } else {
                        cont.resume()
                    }
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
    }
}
