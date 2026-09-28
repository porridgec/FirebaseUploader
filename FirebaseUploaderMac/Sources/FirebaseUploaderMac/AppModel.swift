import AppKit
import SwiftUI

struct AlertPayload: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 当前正在执行的 CLI 操作，用于按钮禁用与各区块的局部 spinner。
enum Activity: Equatable {
    case none
    case version
    case login
    case projects
    case apps
    case groups
    case distribute

    var label: String {
        switch self {
        case .none: return ""
        case .version: return "检测版本中"
        case .login: return "登录中"
        case .projects: return "刷新 Projects 中"
        case .apps: return "刷新 Apps 中"
        case .groups: return "刷新 Groups 中"
        case .distribute: return "上传分发中"
        }
    }
}

enum LogLineKind {
    case command
    case error
    case output
}

/// 登录流程状态（对应 firebase login 的两段式非交互流程）。
enum LoginPhase: Equatable {
    case idle
    /// 正在查询登录态（firebase login:list）
    case checking
    /// 正在生成授权链接（第一阶段命令执行中）
    case starting
    /// 已拿到授权链接，等用户从网页复制授权码
    case waitingCode(url: String)
    /// 正在用授权码完成登录（第二阶段）
    case submitting
    /// 登录成功（附带账号 email，可能为 nil）
    case success(email: String?)
    /// 已登录；others 为可切换的其他已授权账号
    case alreadyLoggedIn(current: String, others: [String])
    /// 正在切换账号（firebase login:use）
    case switching
    case failed(String)
}

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let kind: LogLineKind
}

@MainActor
final class AppModel: ObservableObject {
    static let logLineLimit = 3000
    static let recentUploaderLimit = 5

    // MARK: - 发布状态

    // 选择状态（下拉框的值为 "id  附加信息"，id 在第一个 token，与 Python 版缓存格式一致）
    @Published var projectChoices: [String] = []
    @Published var selectedProject = "" {
        didSet { cache.set("selected_project", selectedProject.trimmingCharacters(in: .whitespaces)) }
    }
    @Published var appChoices: [String] = []
    @Published var selectedApp = "" {
        didSet { cache.set("selected_app", selectedApp.trimmingCharacters(in: .whitespaces)) }
    }

    // Groups：aliases 与 labels 平行数组（同 Python 版 self.groups + Listbox 文案）
    @Published private(set) var groupAliases: [String] = []
    @Published private(set) var groupLabels: [String] = []
    @Published var selectedGroupAliases: Set<String> = []
    @Published var groupSearchText = ""

    // 文件与发布信息
    @Published var ipaPath = ""
    @Published var dsymPath = ""
    @Published var isDropTargeted = false
    @Published var releaseMark = "" {
        didSet {
            guard oldValue != releaseMark else { return }
            cache.set("last_release_mark", releaseMark)
        }
    }
    @Published var uploader: String
    @Published private(set) var recentUploaders: [String] = []

    // 历史 / 日志 / 状态
    @Published var history: [HistoryEntry] = []
    @Published var logLines: [LogLine] = []
    @Published var autoScroll = true
    @Published var activity: Activity = .none
    @Published var alert: AlertPayload?
    @Published var showNoGroupsConfirm = false
    // 登录
    @Published var showLoginSheet = false
    @Published var loginPhase: LoginPhase = .idle
    @Published var loginCode = ""
    /// 当前登录账号（工具栏展示用；以每次 login:list 的结果为准）
    @Published var loggedInEmail: String?
    @Published var firebaseVersion: String?
    /// 上传进度（0-100）；nil 表示暂无百分比信息
    @Published var progressPercent: Double?

    private var plainLog = ""
    private var pendingDistributeArgs: [String]?

    private let cli = FirebaseCLI.shared
    private let cache = CacheStore.shared

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    init() {
        let recents = CacheStore.shared.stringArray("recent_uploaders")
        recentUploaders = recents
        uploader = recents.first ?? ""
        restoreFromCache()
    }

    // MARK: - 派生状态

    var busy: Bool { activity != .none }

    var finalReleaseNotes: String {
        let mark = releaseMark.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = uploader.trimmingCharacters(in: .whitespacesAndNewlines)
        // uploader 为空时不加括号，release notes 只含 mark
        let notes = name.isEmpty ? mark : "\(mark) [\(name)]"
        return notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var selectedProjectId: String? {
        firstToken(of: selectedProject)
    }

    var selectedAppId: String? {
        firstToken(of: selectedApp)
    }

    var groupsSummary: String {
        "已选 \(selectedGroupAliases.count)/\(groupAliases.count)"
    }

    /// 搜索过滤后的 Groups 行（index 指向平行数组的下标）。
    var filteredGroupRows: [(index: Int, alias: String, label: String)] {
        if groupSearchText.isEmpty {
            return groupAliases.indices.map { ($0, groupAliases[$0], groupLabels[$0]) }
        }
        return groupAliases.indices.filter {
            groupLabels[$0].localizedCaseInsensitiveContains(groupSearchText)
                || groupAliases[$0].localizedCaseInsensitiveContains(groupSearchText)
        }
        .map { ($0, groupAliases[$0], groupLabels[$0]) }
    }

    private func firstToken(of value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        return v.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }

    // MARK: - 启动恢复

    private func restoreFromCache() {
        projectChoices = cache.stringArray("projects_choices")
        if let saved = cache.string("selected_project"), projectChoices.contains(saved) {
            selectedProject = saved
        } else if !projectChoices.isEmpty {
            selectedProject = projectChoices[0]
        }

        appChoices = cache.stringArray("apps_choices")
        if let saved = cache.string("selected_app"), appChoices.contains(saved) {
            selectedApp = saved
        } else if !appChoices.isEmpty {
            selectedApp = appChoices[0]
        }

        let aliases = cache.stringArray("groups_aliases")
        let labels = cache.stringArray("groups_labels")
        if aliases.count == labels.count {
            groupAliases = aliases
            groupLabels = labels
        }
        selectedGroupAliases = Set(cache.stringArray("selected_groups")).intersection(Set(groupAliases))

        releaseMark = cache.string("last_release_mark") ?? ""
        history = cache.history()
    }

    // MARK: - 基础动作

    func checkVersion() {
        guard !busy else { return }
        activity = .version
        Task {
            defer { activity = .none }
            guard let result = await runCommand(["--version"]) else { return }
            if result.exitCode != 0 {
                alert = AlertPayload(title: "命令失败", message: "Exit code: \(result.exitCode)\n请看日志")
                return
            }
            let first = result.output
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !first.isEmpty {
                firebaseVersion = first
            }
        }
    }

    // MARK: - 登录（两段式）

    /// 点"登录"先查登录态：已登录显示账号（可切换/可重新登录），未登录才走两段式授权。
    /// 注意：非交互的 `firebase login` 会跳过 "Already logged in" 检查直接生成新链接，
    /// 所以必须先用 `login:list` 探测，不能直接 login。
    func startLogin() {
        guard !busy else { return }
        activity = .login
        loginPhase = .checking
        loginCode = ""
        showLoginSheet = true
        clearLog()
        Task {
            defer { activity = .none }
            guard let result = await runCommand(["login:list"]) else {
                loginPhase = .failed("查询登录状态失败，详见日志")
                return
            }
            guard result.exitCode == 0 else {
                loginPhase = .failed("查询登录状态失败（Exit code: \(result.exitCode)），详见日志")
                return
            }
            if let current = Self.loginEmail(from: result.output) {
                loggedInEmail = current
                loginPhase = .alreadyLoggedIn(
                    current: current,
                    others: Self.otherAccounts(from: result.output, excluding: current)
                )
            } else {
                beginRemoteLogin()
            }
        }
    }

    /// 第一阶段：`firebase login`（GUI 非交互）会打印授权 URL 并退出，
    /// codeVerifier 已由 CLI 存入 configstore，等待第二阶段提交授权码。
    private func beginRemoteLogin() {
        activity = .login
        loginPhase = .starting
        loginCode = ""
        Task {
            defer { activity = .none }
            guard let result = await runCommand(["login"]) else {
                loginPhase = .failed("启动登录命令失败，详见日志")
                return
            }
            guard result.exitCode == 0 else {
                loginPhase = .failed("获取授权链接失败（Exit code: \(result.exitCode)），详见日志")
                return
            }
            if let url = Self.firstURL(in: result.output) {
                loginPhase = .waitingCode(url: url)
            } else if let email = Self.loginEmail(from: result.output) {
                loggedInEmail = email
                loginPhase = .success(email: email)
                scheduleLoginSheetAutoClose()
            } else {
                loginPhase = .failed("未能从输出中解析授权链接，详见日志")
            }
        }
    }

    /// 已登录时选择重新登录/切换账号，走两段式授权流程。
    func restartLogin() {
        beginRemoteLogin()
    }

    /// 切换到另一个已授权账号（firebase login:use）。
    func switchAccount(to email: String) {
        guard !busy else { return }
        activity = .login
        loginPhase = .switching
        Task {
            defer { activity = .none }
            guard let result = await runCommand(["login:use", email]) else {
                loginPhase = .failed("切换账号失败，详见日志")
                return
            }
            if result.exitCode == 0 {
                loggedInEmail = email
                loginPhase = .success(email: email)
                scheduleLoginSheetAutoClose()
            } else {
                loginPhase = .failed("切换账号失败（Exit code: \(result.exitCode)），详见日志")
            }
        }
    }

    /// 第二阶段：`firebase login <授权码>` 用网页拿到的 code 完成登录。
    func submitLoginCode() {
        guard case .waitingCode = loginPhase else { return }
        let code = loginCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        activity = .login
        loginPhase = .submitting
        Task {
            defer { activity = .none }
            guard let result = await runCommand(["login", code]) else {
                loginPhase = .failed("提交授权码失败，详见日志")
                return
            }
            if result.exitCode == 0 {
                let email = Self.loginEmail(from: result.output)
                loggedInEmail = email
                loginPhase = .success(email: email)
                scheduleLoginSheetAutoClose()
            } else {
                loginPhase = .failed("授权码校验失败（Exit code: \(result.exitCode)）。请确认授权码完整无误后重试。")
            }
        }
    }

    func cancelLogin() {
        showLoginSheet = false
        loginPhase = .idle
        loginCode = ""
    }

    func retryLogin() {
        loginPhase = .idle
        startLogin()
    }

    private func scheduleLoginSheetAutoClose() {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard case .success = loginPhase else { return }
            showLoginSheet = false
            loginPhase = .idle
            loginCode = ""
            refreshProjects()
        }
    }

    private static func loginEmail(from output: String) -> String? {
        let clean = stripANSI(output)
        guard let range = clean.range(of: #"Logged in as\s+(\S+@\S+)"#, options: .regularExpression) else {
            return nil
        }
        return String(clean[range]).replacingOccurrences(of: "Logged in as", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 解析 `login:list` 输出里 "Other available accounts" 段落中的其他账号。
    private static func otherAccounts(from output: String, excluding current: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*-\s+(\S+@\S+)"#) else { return [] }
        let clean = stripANSI(output)
        let ns = clean as NSString
        return regex.matches(in: clean, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: clean) else { return nil }
            let email = String(clean[range])
            return email == current ? nil : email
        }
    }

    // MARK: - 刷新

    func refreshProjects() {
        guard !busy else { return }
        activity = .projects
        clearLog()
        appendLog("获取 projects...\n")
        Task {
            defer { activity = .none }
            guard let result = await runCommand(["projects:list", "--json"]) else { return }
            guard result.exitCode == 0 else {
                alert = AlertPayload(title: "失败", message: result.output)
                return
            }
            let projects: [FirebaseProject]
            do {
                projects = try FirebaseParser.projects(from: result.output)
            } catch {
                print(error.localizedDescription)
                alert = AlertPayload(title: "解析失败", message: error.localizedDescription)
                return
            }

            projectChoices = projects.map(\.display)
            if !projectChoices.isEmpty {
                if let saved = cache.string("selected_project"), projectChoices.contains(saved) {
                    selectedProject = saved
                } else {
                    selectedProject = projectChoices[0]
                }
                cache.set("projects_choices", projectChoices)
                cache.set("selected_project", selectedProject)
            }
        }
    }

    /// 自动链式调用（选完 project/app 后由视图触发）与手动点击共用。
    /// 静默模式下缺少 project 不弹窗，直接返回。
    func refreshApps(auto: Bool = false) {
        guard !busy else { return }
        guard let projectId = selectedProjectId else {
            if !auto {
                alert = AlertPayload(title: "提示", message: "请先选择 Project。")
            }
            return
        }
        activity = .apps
        clearLog()
        appendLog("获取 apps (project=\(projectId))...\n")
        Task {
            defer { activity = .none }
            guard let result = await runCommand(["apps:list", "--project", projectId, "--json"]) else { return }
            guard result.exitCode == 0 else {
                alert = AlertPayload(title: "失败", message: result.output)
                return
            }
            let apps: [FirebaseApp]
            do {
                apps = try FirebaseParser.apps(from: result.output)
            } catch {
                print(error.localizedDescription)
                alert = AlertPayload(title: "解析失败", message: error.localizedDescription)
                return
            }

            appChoices = apps.map(\.display)
            if !appChoices.isEmpty {
                if let saved = cache.string("selected_app"), appChoices.contains(saved) {
                    selectedApp = saved
                } else {
                    selectedApp = appChoices[0]
                }
                cache.set("apps_choices", appChoices)
                cache.set("selected_app", selectedApp)
            }
        }
    }

    func refreshGroups(auto: Bool = false) {
        guard !busy else { return }
        guard let projectId = selectedProjectId else {
            if !auto {
                alert = AlertPayload(title: "提示", message: "请先选择 Project。")
            }
            return
        }
        activity = .groups
        clearLog()
        appendLog("获取 groups (project=\(projectId))...\n")
        Task {
            defer { activity = .none }
            guard let result = await runCommand([
                "appdistribution:groups:list", "--project", projectId, "--json",
            ]) else { return }
            guard result.exitCode == 0 else {
                alert = AlertPayload(title: "失败", message: result.output)
                return
            }
            let groups: [FirebaseGroup]
            do {
                groups = try FirebaseParser.groups(from: result.output)
            } catch {
                print(error.localizedDescription)
                alert = AlertPayload(title: "解析失败", message: error.localizedDescription)
                return
            }

            groupAliases = groups.map(\.alias)
            groupLabels = groups.map(\.display)
            selectedGroupAliases = selectedGroupAliases.intersection(Set(groupAliases))
            cache.set("groups_aliases", groupAliases)
            cache.set("groups_labels", groupLabels)
            persistSelectedGroups()
        }
    }

    // MARK: - 分发

    func distributeTapped() {
        guard !busy else { return }
        guard selectedProjectId != nil else {
            alert = AlertPayload(title: "提示", message: "请先选择 Project。")
            return
        }
        guard let appId = selectedAppId else {
            alert = AlertPayload(title: "提示", message: "请先选择 iOS App。")
            return
        }
        let ipa = ipaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ipa.isEmpty, FileManager.default.fileExists(atPath: ipa) else {
            alert = AlertPayload(title: "提示", message: "请选择有效的 IPA 文件。")
            return
        }

        let notes = finalReleaseNotes
        var args = ["appdistribution:distribute", ipa, "--app", appId]
        if !notes.isEmpty {
            args += ["--release-notes", notes]
        }
        let dsym = dsymPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dsym.isEmpty {
            guard FileManager.default.fileExists(atPath: dsym) else {
                alert = AlertPayload(title: "提示", message: "dSYM.zip 路径不存在。")
                return
            }
            args += ["--debug-symbols", dsym]
        }

        let selectedGroups = groupAliases.filter { selectedGroupAliases.contains($0) }
        // IMPORTANT: firebase-tools 的 --groups 期望逗号分隔的单个参数
        if !selectedGroups.isEmpty {
            args += ["--groups", selectedGroups.joined(separator: ",")]
        } else {
            pendingDistributeArgs = args
            showNoGroupsConfirm = true
            return
        }
        pushRecentUploader()
        runDistribute(args, notes: notes)
    }

    func confirmDistributeWithoutGroups() {
        guard let args = pendingDistributeArgs else { return }
        pendingDistributeArgs = nil
        pushRecentUploader()
        runDistribute(args, notes: finalReleaseNotes)
    }

    func cancelDistributeWithoutGroups() {
        pendingDistributeArgs = nil
    }

    private func runDistribute(_ args: [String], notes: String) {
        activity = .distribute
        progressPercent = nil
        clearLog()
        Task {
            defer {
                activity = .none
                progressPercent = nil
            }
            guard let result = await runCommand(args, rawLineHandler: { raw in
                self.updateProgress(from: raw)
            }) else { return }
            if result.exitCode != 0 {
                if result.output.contains("HTTP Error: 404") && result.output.contains(":distribute") {
                    alert = AlertPayload(
                        title: "分发失败(404)",
                        message: "分发 404 常见原因：\n1) group 名称不匹配/不存在（尤其包含空格/显示名 vs 实际名）\n2) 账号权限不足（有时表现为 404）\n建议：点击“刷新 Groups”重新选择，或先用 testers 分发验证权限。\n"
                    )
                } else {
                    alert = AlertPayload(title: "失败", message: "Exit code: \(result.exitCode)\n请看日志")
                }
                return
            }

            history = cache.insertHistoryEntry(note: notes, time: Self.timestampFormatter.string(from: Date()))
            if Self.firstURL(in: result.output) != nil {
                alert = AlertPayload(title: "成功", message: "上传/分发成功。\n\n关键链接已在日志中输出（可点击，或用日志区“复制链接”）。")
            }
        }
    }

    /// 从 CLI 输出解析最新百分比（firebase 的进度条行形如 `Uploading [...] 45%`，\r 分隔多次更新）。
    private func updateProgress(from raw: String) {
        let text = raw.replacingOccurrences(of: "\r", with: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3})%"#) else { return }
        let ns = text as NSString
        guard let match = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]), (0...100).contains(value) else { return }
        progressPercent = value
    }

    private func pushRecentUploader() {
        let name = uploader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var list = recentUploaders.filter { $0 != name }
        list.insert(name, at: 0)
        recentUploaders = Array(list.prefix(Self.recentUploaderLimit))
        cache.set("recent_uploaders", recentUploaders)
    }

    // MARK: - Groups 选择

    func toggleGroup(_ alias: String, isOn: Bool) {
        if isOn {
            selectedGroupAliases.insert(alias)
        } else {
            selectedGroupAliases.remove(alias)
        }
        persistSelectedGroups()
    }

    func selectAllFilteredGroups() {
        for row in filteredGroupRows {
            selectedGroupAliases.insert(row.alias)
        }
        persistSelectedGroups()
    }

    func clearAllGroupSelection() {
        selectedGroupAliases.removeAll()
        persistSelectedGroups()
    }

    private func persistSelectedGroups() {
        cache.set("selected_groups", Array(selectedGroupAliases))
    }

    // MARK: - 历史回填

    /// 把历史记录的 "mark [uploader]" 拆开回填到输入框。
    func reuseMark(from entry: HistoryEntry) {
        let note = entry.releaseNote
        if let regex = try? NSRegularExpression(pattern: #"\s*\[([^\]]*)\]\s*$"#),
           let match = regex.firstMatch(
               in: note, range: NSRange(location: 0, length: (note as NSString).length)
           ),
           let wholeRange = Range(match.range, in: note) {
            releaseMark = String(note[note.startIndex..<wholeRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if let nameRange = Range(match.range(at: 1), in: note) {
                let name = String(note[nameRange]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    uploader = name
                }
            }
        } else {
            releaseMark = note
        }
    }

    // MARK: - 文件选择

    func pickIPA() {
        if let url = chooseFile(title: "选择 IPA", preferredDirectoryName: "Downloads/ios-build-output") {
            ipaPath = url.path
        }
    }

    func pickDSYM() {
        if let url = chooseFile(title: "选择 dSYM.zip", preferredDirectoryName: nil) {
            dsymPath = url.path
        }
    }

    /// 拖拽落到 Files 区：.ipa → IPA，.zip → dSYM。
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" {
            ipaPath = url.path
            return true
        }
        if ext == "zip" {
            dsymPath = url.path
            return true
        }
        return false
    }

    private func chooseFile(title: String, preferredDirectoryName: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let relative = preferredDirectoryName {
            let preferred = home.appendingPathComponent(relative)
            panel.directoryURL = FileManager.default.fileExists(atPath: preferred.path)
                ? preferred
                : home.appendingPathComponent("Downloads")
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - 日志

    func clearLog() {
        logLines = []
        plainLog = ""
    }

    func appendLog(_ chunk: String) {
        plainLog += chunk
        var newLines: [LogLine] = []
        // firebase 的进度条用 \r 覆盖同一行，拆开成独立行展示
        for piece in chunk.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let text = String(piece)
            newLines.append(LogLine(text: text, kind: Self.classify(text)))
        }
        logLines.append(contentsOf: newLines)
        if logLines.count > Self.logLineLimit {
            logLines.removeFirst(logLines.count - Self.logLineLimit)
        }
    }

    func copyLogToPasteboard() {
        guard !plainLog.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainLog, forType: .string)
    }

    func copyLinksToPasteboard() {
        let urls = Self.allURLs(in: plainLog)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
    }

    private static func classify(_ text: String) -> LogLineKind {
        if text.hasPrefix("$ ") {
            return .command
        }
        let lowered = text.lowercased()
        if lowered.contains("error") || lowered.contains("failed") || lowered.contains("fatal") || text.contains("✖") {
            return .error
        }
        return .output
    }

    private static func allURLs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)https?://\S+"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            Range(match.range, in: text).map { stripANSI(String(text[$0])) }
        }
    }

    /// 去掉 CLI 输出中可能残留的 ANSI 颜色转义码。
    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{1B}\[[0-9;]*[a-zA-Z]"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func firstURL(in text: String) -> String? {
        allURLs(in: text).first
    }

    // MARK: - 命令执行

    /// 执行命令并把命令行回显写入日志；出错时弹出"错误"对话框并返回 nil。
    /// rawLineHandler 在主线程收到每一行原始输出（含 \r），供进度解析等使用。
    private func runCommand(
        _ args: [String],
        rawLineHandler: ((String) -> Void)? = nil
    ) async -> CommandOutput? {
        appendLog("\n$ \(FirebaseCLI.displayCommand(args))\n")
        do {
            return try await cli.run(args, onLine: { line in
                Task { @MainActor in
                    self.appendLog(line)
                    rawLineHandler?(line)
                }
            })
        } catch {
            alert = AlertPayload(title: "错误", message: error.localizedDescription)
            return nil
        }
    }
}
