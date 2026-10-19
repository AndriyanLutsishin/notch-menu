import Foundation

/// Питає Codex (програму OpenAI для терміналу) через твою підписку ChatGPT.
/// Запуск у режимі «лише читання» в порожній тимчасовій папці — файлів він не змінить.
final class CodexRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    /// Натиснули «Зупинити» (навіть до запуску процесу).
    private var cancelled = false

    static func findExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func run(prompt: String) async throws -> String {
        guard let codex = Self.findExecutable() else {
            throw Failure(message: "Codex не знайдено на цьому Mac.")
        }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchMenu-codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = [
            "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
            "--ignore-user-config", "--color", "never",
            "-c", "model_reasoning_effort=\"low\"",
            "-C", workDir.path, "-",
        ]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.npm-global/bin", "/usr/bin", "/bin",
                       env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = workDir

        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors

        let fullPrompt = "Відповідай коротко, мовою запитання. Не запускай команд і не читай файлів — лише відповідь.\n\n" + prompt

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    if lock.withLock({ cancelled }) { cont.resume(throwing: CancellationError()); return }
                    do {
                        try p.run()
                    } catch {
                        cont.resume(throwing: Failure(message: "Не вдалося запустити Codex: \(error.localizedDescription)"))
                        return
                    }
                    lock.withLock {
                        process = p
                        if cancelled { p.terminate() }  // «Зупинити» натиснули саме в момент запуску
                    }
                    try? input.fileHandleForReading.close()  // цей кінець належить дочірньому процесу
                    // Пишемо питання окремо (не блокуємо читання відповіді); дуже довгі тексти обрізаємо.
                    let payload = Data(String(fullPrompt.prefix(100_000)).utf8)
                    DispatchQueue.global().async {
                        try? input.fileHandleForWriting.write(contentsOf: payload)
                        try? input.fileHandleForWriting.close()
                    }

                    var errData = Data()
                    let errQueue = DispatchGroup()
                    errQueue.enter()
                    DispatchQueue.global().async {
                        errData = errors.fileHandleForReading.readDataToEndOfFile()
                        errQueue.leave()
                    }
                    let outData = output.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    errQueue.wait()
                    lock.withLock { if process === p { process = nil } }

                    let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if p.terminationReason == .uncaughtSignal {
                        // Зупинили ми — це «скасовано»; інакше процес упав сам.
                        cont.resume(throwing: lock.withLock({ cancelled }) ? CancellationError()
                                    : CodexRunner.Failure(message: "Codex несподівано завершився. Спробуй ще раз."))
                    } else if p.terminationStatus == 0, !out.isEmpty {
                        cont.resume(returning: out)
                    } else {
                        let err = String(decoding: errData, as: UTF8.self)
                        cont.resume(throwing: Failure(message: Self.explain(stderr: err, status: p.terminationStatus)))
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

    static func explain(stderr: String, status: Int32) -> String {
        let lower = stderr.lowercased()
        if lower.contains("login") || lower.contains("not logged") || lower.contains("unauthorized") || lower.contains("401") {
            return "Codex не залогінений. Відкрий Термінал і виконай: codex login"
        }
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("429") {
            return "Codex: вичерпано ліміт підписки. Спробуй пізніше."
        }
        let lastLine = stderr.split(separator: "\n").last { !$0.contains("rmcp::") }.map(String.init) ?? ""
        return "Codex завершився з помилкою (\(status)). \(lastLine)"
    }
}
