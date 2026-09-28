import Foundation

enum FirebaseCLIError: LocalizedError {
    case firebaseNotFound
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .firebaseNotFound:
            return "找不到 firebase 命令。请先安装：npm i -g firebase-tools，并确保 PATH 可用。"
        case .launchFailed(let reason):
            return "启动命令失败: \(reason)"
        }
    }
}

struct CommandOutput {
    var exitCode: Int32
    var output: String
}

/// 封装 firebase CLI：定位可执行文件、流式执行命令（stdout+stderr 合并、逐行回调）。
final class FirebaseCLI {
    static let shared = FirebaseCLI()

    private var cachedFirebasePath: String?
    private let lock = NSLock()

    private init() {}

    /// firebase 可能所在的搜索目录：当前 PATH 优先，再补常见安装位置。
    /// GUI 方式启动的进程不继承 shell 的 PATH（不含 homebrew/nvm 等），需要额外兜底。
    static func searchDirectories() -> [String] {
        var dirs: [String] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        dirs += pathEnv.split(separator: ":").map(String.init)

        dirs += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.volta/bin",
            home + "/.local/bin",
        ]

        // nvm: ~/.nvm/versions/node/*/bin
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            dirs += versions.map { nvmRoot + "/" + $0 + "/bin" }
        }
        // fnm: ~/.fnm/node-versions/*/installation/bin
        let fnmRoot = home + "/.fnm/node-versions"
        if let versions = try? fm.contentsOfDirectory(atPath: fnmRoot) {
            dirs += versions.map { fnmRoot + "/" + $0 + "/installation/bin" }
        }
        return dirs
    }

    func firebaseExecutablePath() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedFirebasePath {
            return cached
        }
        let fm = FileManager.default
        for dir in Self.searchDirectories() {
            let candidate = dir + "/firebase"
            if fm.isExecutableFile(atPath: candidate) {
                cachedFirebasePath = candidate
                return candidate
            }
        }
        throw FirebaseCLIError.firebaseNotFound
    }

    /// 流式执行 firebase 子命令，语义与 app.py 的 run_cmd 一致。
    func run(_ args: [String], onLine: ((String) -> Void)? = nil) async throws -> CommandOutput {
        let firebasePath = try firebaseExecutablePath()

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: firebasePath)
                process.arguments = args

                // firebase CLI 启动时会把 firebase-debug.log 写到工作目录（或 FIREBASE_DEBUG_PATH）。
                // 从 Finder/open 启动的 .app 工作目录是 /（不可写），会直接崩溃
                // （"Unable to obtain permissions for firebase-debug.log"），
                // 因此固定用一个专属可写目录（沙盒下 homeDirectory 是容器目录，同样可写）。
                let workDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".firebase-uploader")
                try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                process.currentDirectoryURL = workDir

                // firebase 的 bin 用 `#!/usr/bin/env node`，子进程 PATH 需包含 node 所在目录
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = Self.searchDirectories().joined(separator: ":") + ":" + (env["PATH"] ?? "")
                env["FIREBASE_DEBUG_PATH"] = workDir.path
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: FirebaseCLIError.launchFailed(error.localizedDescription))
                    return
                }

                let collector = LineCollector(onLine: onLine)
                let handle = pipe.fileHandleForReading
                let readerDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        collector.feed(chunk)
                    }
                    collector.flush()
                    readerDone.signal()
                }

                process.waitUntilExit()
                readerDone.wait()

                cont.resume(returning: CommandOutput(exitCode: process.terminationStatus, output: collector.output))
            }
        }
    }

    /// 展示用命令行字符串（等价 app.py 的 shlex.join）。
    static func displayCommand(_ args: [String]) -> String {
        (["firebase"] + args.map(quoteIfNeeded)).joined(separator: " ")
    }

    private static let shellSafeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:=+,%@")

    private static func quoteIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.allSatisfy({ shellSafeCharacters.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 按行拆分流式输出。feed/flush 只在读取线程调用；output 在读取线程结束后调用。
final class LineCollector {
    private let onLine: ((String) -> Void)?
    private let lock = NSLock()
    private var buffer = Data()
    private var collected = ""

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            let line = (String(data: lineData, encoding: .utf8) ?? "") + "\n"
            collected += line
            lines.append(line)
        }
        lock.unlock()
        for line in lines {
            onLine?(line)
        }
    }

    /// EOF 后输出不含换行的残余内容（Python 按行迭代也会产出最后一行）。
    func flush() {
        lock.lock()
        var trailing = ""
        if !buffer.isEmpty {
            trailing = String(data: buffer, encoding: .utf8) ?? ""
            collected += trailing
            buffer.removeAll()
        }
        lock.unlock()
        if !trailing.isEmpty {
            onLine?(trailing)
        }
    }
}
