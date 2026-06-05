import Foundation
import Observation

enum MediaPipeSetupState {
    case checking
    case ready(pythonPath: String)
    case installing
    case failed(String)
}

@Observable
final class MediaPipeSetupManager {
    private(set) var state: MediaPipeSetupState = .checking
    private(set) var outputLines: [String] = []

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var pythonExecutablePath: String? {
        if case .ready(let path) = state { return path }
        return nil
    }

    private var supportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("eyeTerm")
    }

    private var venvDir: URL {
        supportDir.appendingPathComponent("venv")
    }

    private var venvPython: URL {
        venvDir.appendingPathComponent("bin/python3")
    }

    func checkOrInstall() {
        state = .checking
        Task {
            if await isMediaPipeReady() {
                let path = venvPython.path
                await MainActor.run {
                    state = .ready(pythonPath: path)
                }
            } else {
                await install()
            }
        }
    }

    func install() async {
        await MainActor.run {
            state = .installing
            outputLines = []
        }

        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

            await appendOutput("Creating Python virtual environment…")
            _ = try await runCommand("/usr/bin/python3", args: ["-m", "venv", venvDir.path])

            await appendOutput("Installing MediaPipe (this takes 1–2 minutes)…")
            let pipPath = venvDir.appendingPathComponent("bin/pip").path
            _ = try await runCommand(pipPath, args: ["install", "--quiet", "mediapipe"])

            await appendOutput("Verifying installation…")
            _ = try await runCommand(venvPython.path, args: ["-c", "import mediapipe"])

            let path = venvPython.path
            await MainActor.run {
                outputLines.append("✓ MediaPipe ready!")
                state = .ready(pythonPath: path)
            }
        } catch {
            let msg = error.localizedDescription
            await MainActor.run {
                outputLines.append("✗ Setup failed: \(msg)")
                state = .failed(msg)
            }
        }
    }

    private func isMediaPipeReady() async -> Bool {
        guard FileManager.default.fileExists(atPath: venvPython.path) else { return false }
        do {
            _ = try await runCommand(venvPython.path, args: ["-c", "import mediapipe"])
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private func appendOutput(_ line: String) {
        outputLines.append(line)
    }

    private func runCommand(_ executable: String, args: [String]) async throws -> String {
        // Wrap the process in a continuation, then race it against a 2-minute timeout.
        let result: String = try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // Use a flag so the continuation is resumed exactly once.
            var resumed = false
            let lock = NSLock()

            func resumeOnce(_ block: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                block()
            }

            // Declare timeout task before terminationHandler so both closures can capture it.
            var timeoutTask: DispatchWorkItem?
            let timeout = DispatchWorkItem {
                guard proc.isRunning else { return }
                proc.terminate()
                resumeOnce {
                    continuation.resume(throwing: NSError(
                        domain: "MediaPipeSetup",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Installation timed out after 2 minutes."]
                    ))
                }
            }
            timeoutTask = timeout

            proc.terminationHandler = { p in
                timeoutTask?.cancel()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    let output = String(data: outData, encoding: .utf8) ?? ""
                    resumeOnce { continuation.resume(returning: output) }
                } else {
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "Exit code \(p.terminationStatus)"
                    resumeOnce {
                        continuation.resume(throwing: NSError(
                            domain: "MediaPipeSetup",
                            code: Int(p.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: errMsg]
                        ))
                    }
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)

            do {
                try proc.run()
            } catch {
                timeoutTask?.cancel()
                resumeOnce { continuation.resume(throwing: error) }
            }
        }
        return result
    }
}
