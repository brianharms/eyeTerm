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
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            proc.terminationHandler = { p in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    let output = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } else {
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "Exit code \(p.terminationStatus)"
                    continuation.resume(throwing: NSError(
                        domain: "MediaPipeSetup",
                        code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: errMsg]
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
