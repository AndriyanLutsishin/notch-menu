import Foundation

/// Gemini CLI (програма Google для терміналу) — безкоштовно з входом через Google-акаунт.
/// Запускаємо в порожній тимчасовій папці: CLI лише відповідає текстом, файлів не бачить.
final class GeminiCLIRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    static let executable: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.npm-global/bin/gemini", "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini",
                "\(home)/.local/bin/gemini", "\(home)/.bun/bin/gemini"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func run(prompt: String) async throws -> String {
        guard let exe = Self.executable else {
            throw CodexRunner.Failure(message: "Gemini CLI не знайдено.")
        }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchMenu-gemini", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        let full = "Відповідай коротко, мовою запитання. Не запускай команд і не читай файлів — лише відповідь.\n\n"
            + String(prompt.prefix(100_000))
        p.arguments = ["-p", full]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.npm-global/bin", "/usr/bin", "/bin",
                       env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = workDir
        let output = Pipe(), errors = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError = errors

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    if lock.withLock({ cancelled }) { cont.resume(throwing: CancellationError()); return }
                    do { try p.run() } catch {
                        cont.resume(throwing: CodexRunner.Failure(message: "Не вдалося запустити Gemini: \(error.localizedDescription)"))
                        return
                    }
                    lock.withLock {
                        process = p
                        if cancelled { p.terminate() }
                    }
                    var errData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errData = errors.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = output.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    group.wait()
                    lock.withLock { if process === p { process = nil } }

                    let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: lock.withLock({ cancelled }) ? CancellationError()
                                    : CodexRunner.Failure(message: "Gemini несподівано завершився. Спробуй ще раз."))
                    } else if p.terminationStatus == 0, !out.isEmpty {
                        cont.resume(returning: out)
                    } else {
                        cont.resume(throwing: CodexRunner.Failure(message: Self.explain(String(decoding: errData, as: UTF8.self))))
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

    static func explain(_ stderr: String) -> String {
        let s = stderr.lowercased()
        if s.contains("auth") || s.contains("login") || s.contains("credential") {
            return "Gemini CLI не залогінений. Відкрий Термінал, набери gemini і увійди через Google."
        }
        if s.contains("quota") || s.contains("429") || s.contains("rate") {
            return "Вичерпано безкоштовний ліміт Gemini. Спробуй пізніше."
        }
        let last = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return last.isEmpty ? "Gemini не відповів." : "Gemini: \(last)"
    }
}
