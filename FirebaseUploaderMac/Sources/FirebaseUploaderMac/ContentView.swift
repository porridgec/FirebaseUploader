import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedHistoryID: HistoryEntry.ID?

    var body: some View {
        HSplitView {
            ScrollView {
                leftColumn
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 440, idealWidth: 520)

            rightColumn
                .padding(14)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 760)
        .toolbar {
            toolbarContent
        }
        // 链式自动刷新：选完 project 自动刷 apps，选完 app 自动刷 groups
        .onChange(of: model.selectedProject) { _, _ in
            model.refreshApps(auto: true)
        }
        .onChange(of: model.selectedApp) { _, _ in
            model.refreshGroups(auto: true)
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { payload in
            Text(payload.message)
        }
        .confirmationDialog(
            "未选择 Groups",
            isPresented: $model.showNoGroupsConfirm,
            titleVisibility: .visible
        ) {
            Button("继续（仅上传，不分发）") { model.confirmDistributeWithoutGroups() }
            Button("取消", role: .cancel) { model.cancelDistributeWithoutGroups() }
        } message: {
            Text("你没有选择任何 group。是否继续（仅上传，不分发）？")
        }
        .sheet(isPresented: $model.showLoginSheet) {
            LoginSheet()
                .environmentObject(model)
                .frame(width: 560)
                .padding(20)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.checkVersion()
            } label: {
                Label("检测版本", systemImage: "info.circle")
            }
            .disabled(model.busy)

            Button {
                model.startLogin()
            } label: {
                Label("登录", systemImage: "person.crop.circle")
            }
            .disabled(model.busy)

            Button {
                model.refreshProjects()
            } label: {
                Label("刷新 Projects", systemImage: "arrow.clockwise")
            }
            .disabled(model.busy)

            if let email = model.loggedInEmail {
                Label(email, systemImage: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            if let version = model.firebaseVersion {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            if model.busy {
                ProgressView()
                    .controlSize(.small)
                Text(model.activity.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 左栏（核心流程）

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            projectSection
            appSection
            groupsSection
            filesSection
            releaseSection
            distributeBar
        }
    }

    private var projectSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Project", selection: $model.selectedProject) {
                    ForEach(model.projectChoices, id: \.self) { choice in
                        Text(choice).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(model.selectedProjectId ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    sectionSpinner(.apps)
                    Button("刷新 Apps") { model.refreshApps() }
                        .disabled(model.busy)
                }
            }
            .padding(6)
        } label: {
            sectionLabel("Project", activity: .projects)
        }
    }

    private var appSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Picker("iOS App", selection: $model.selectedApp) {
                    ForEach(model.appChoices, id: \.self) { choice in
                        Text(choice).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(model.selectedAppId ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    sectionSpinner(.groups)
                    Button("刷新 Groups") { model.refreshGroups() }
                        .disabled(model.busy)
                }
            }
            .padding(6)
        } label: {
            sectionLabel("iOS App (Firebase App ID)", activity: .apps)
        }
    }

    private var groupsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    searchField
                    Text(model.groupsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("全选") { model.selectAllFilteredGroups() }
                        .disabled(model.groupAliases.isEmpty)
                    Button("清空") { model.clearAllGroupSelection() }
                        .disabled(model.selectedGroupAliases.isEmpty)
                }
                if model.groupAliases.isEmpty {
                    Text("尚未加载，点击“刷新 Groups”获取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.filteredGroupRows, id: \.index) { row in
                                Toggle(isOn: Binding(
                                    get: { model.selectedGroupAliases.contains(row.alias) },
                                    set: { model.toggleGroup(row.alias, isOn: $0) }
                                )) {
                                    Text(row.label)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .frame(height: 150)
                }
            }
            .padding(6)
        } label: {
            sectionLabel("Groups (多选)", activity: .groups)
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索 group", text: $model.groupSearchText)
                .textFieldStyle(.plain)
        }
        .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.4))
        )
        .frame(maxWidth: 220)
    }

    private var filesSection: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack {
                    Text("IPA:")
                        .frame(width: 110, alignment: .leading)
                    TextField("IPA 路径（可拖拽 .ipa 到此处）", text: $model.ipaPath)
                    Button("选择...") { model.pickIPA() }
                }
                HStack {
                    Text("dSYM.zip (可选):")
                        .frame(width: 110, alignment: .leading)
                    TextField("dSYM.zip 路径（可拖拽 .zip）", text: $model.dsymPath)
                    Button("选择...") { model.pickDSYM() }
                }
            }
            .padding(6)
        } label: {
            sectionLabel("Files", activity: nil)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDroppedURLs(urls)
        } isTargeted: { hovering in
            model.isDropTargeted = hovering
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    model.isDropTargeted ? Color.accentColor : .clear,
                    lineWidth: 2
                )
        )
    }

    private var releaseSection: some View {
        GroupBox("Release mark") {
            VStack(spacing: 8) {
                TextField("Release mark（可从右侧历史双击回填）", text: $model.releaseMark)
                HStack {
                    Text("Uploader:")
                        .frame(width: 110, alignment: .leading)
                    TextField("上传人姓名", text: $model.uploader)
                    if !model.recentUploaders.isEmpty {
                        Menu {
                            ForEach(model.recentUploaders, id: \.self) { name in
                                Button(name) { model.uploader = name }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Release notes 预览:")
                        .frame(width: 110, alignment: .leading)
                    Text(model.finalReleaseNotes.isEmpty ? " " : model.finalReleaseNotes)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary.opacity(0.4))
                        )
                }
            }
            .padding(6)
        }
    }

    private var distributeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    model.distributeTapped()
                } label: {
                    Text("上传并分发")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .disabled(model.busy)

                if model.activity == .distribute {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.activity.label)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let percent = model.progressPercent {
                ProgressView(value: percent, total: 100) {
                    Text("上传进度 \(Int(percent))%")
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - 右栏（历史 + 日志）

    private var rightColumn: some View {
        VStack(spacing: 14) {
            historySection
            logSection
        }
    }

    private var historySection: some View {
        GroupBox("Upload History") {
            VStack(alignment: .leading, spacing: 6) {
                if model.history.isEmpty {
                    ContentUnavailableView(
                        "暂无上传历史",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("上传成功后会记录在这里；双击某行可回填 Release mark 和 Uploader")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Table(model.history, selection: $selectedHistoryID) {
                        TableColumn("release note") { entry in
                            Text(entry.releaseNote)
                                .lineLimit(1)
                                .onTapGesture(count: 2) { model.reuseMark(from: entry) }
                                .contextMenu {
                                    Button("回填 Release mark") { model.reuseMark(from: entry) }
                                }
                        }
                        .width(min: 260)
                        TableColumn("时间") { entry in
                            Text(entry.uploadTime)
                                .onTapGesture(count: 2) { model.reuseMark(from: entry) }
                                .contextMenu {
                                    Button("回填 Release mark") { model.reuseMark(from: entry) }
                                }
                        }
                        .width(150)
                    }
                    .tableStyle(.inset)

                    if let id = selectedHistoryID,
                       let entry = model.history.first(where: { $0.id == id }) {
                        HStack {
                            Button("回填 Release mark") { model.reuseMark(from: entry) }
                            Spacer()
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var logSection: some View {
        GroupBox("Log") {
            VStack(spacing: 6) {
                HStack {
                    Toggle("自动滚动", isOn: $model.autoScroll)
                        .controlSize(.mini)
                    Spacer()
                    Button("复制链接") { model.copyLinksToPasteboard() }
                        .controlSize(.small)
                    Button("复制日志") { model.copyLogToPasteboard() }
                        .controlSize(.small)
                    Button("清空") { model.clearLog() }
                        .controlSize(.small)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.logLines) { line in
                                Text(Self.attributed(line))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
                    }
                    .background(.black.opacity(0.03))
                    .onChange(of: model.logLines.count) {
                        guard model.autoScroll, let last = model.logLines.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - 小部件

    private func sectionLabel(_ title: String, activity: Activity?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let activity, model.activity == activity {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func sectionSpinner(_ activity: Activity) -> some View {
        if model.activity == activity {
            ProgressView()
                .controlSize(.small)
        }
    }

    /// 日志行 → 带颜色与可点击链接的 AttributedString。
    private static func attributed(_ line: LogLine) -> AttributedString {
        var result = AttributedString()
        guard let regex = try? NSRegularExpression(pattern: #"(?i)https?://\S+"#) else {
            return plain(String(line.text), kind: line.kind)
        }
        let nsText = line.text as NSString
        var cursor = line.text.startIndex
        regex.enumerateMatches(in: line.text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match,
                  let swiftRange = Range(match.range, in: line.text),
                  swiftRange.lowerBound >= cursor else { return }
            result.append(plain(String(line.text[cursor..<swiftRange.lowerBound]), kind: line.kind))
            let urlText = String(line.text[swiftRange])
            var linkPart = AttributedString(urlText)
            linkPart.link = URL(string: urlText)
            result.append(linkPart)
            cursor = swiftRange.upperBound
        }
        result.append(plain(String(line.text[cursor...]), kind: line.kind))
        return result
    }

    private static func plain(_ text: String, kind: LogLineKind) -> AttributedString {
        var part = AttributedString(text.isEmpty ? " " : text)
        part.font = .system(size: 11, design: .monospaced)
        switch kind {
        case .command:
            part.foregroundColor = .accentColor
            part.font = .system(size: 11, weight: .semibold, design: .monospaced)
        case .error:
            part.foregroundColor = .red
        case .output:
            part.foregroundColor = .primary.opacity(0.85)
        }
        return part
    }
}

/// 登录引导面板：授权链接 → 粘贴授权码 → 完成登录。
private struct LoginSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登录 Firebase")
                .font(.headline)

            switch model.loginPhase {
            case .idle, .checking:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查登录状态...")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("取消") { model.cancelLogin() }
                }

            case .alreadyLoggedIn(let current, let others):
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已登录：\(current)")
                        .textSelection(.enabled)
                }
                if !others.isEmpty {
                    Text("其他已授权账号：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(others, id: \.self) { email in
                        HStack {
                            Text(email)
                                .textSelection(.enabled)
                            Spacer()
                            Button("切换") { model.switchAccount(to: email) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary.opacity(0.4))
                        )
                    }
                }
                Spacer()
                HStack {
                    Button("切换账号 / 重新登录") { model.restartLogin() }
                    Spacer()
                    Button("关闭") { model.cancelLogin() }
                }

            case .starting:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在生成授权链接...")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("取消") { model.cancelLogin() }
                }

            case .waitingCode(let url):
                stepRow(number: 1, text: "点击授权链接，在浏览器完成 Google 登录：")
                Link(destination: URL(string: url) ?? URL(fileURLWithPath: "/")) {
                    Text(url)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("复制链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    .controlSize(.small)
                    Spacer()
                }
                stepRow(number: 2, text: "授权后网页会显示授权码（authorization code），粘贴到下面：")
                TextField("粘贴授权码", text: $model.loginCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submitLoginCode() }
                HStack {
                    Button {
                        model.submitLoginCode()
                    } label: {
                        Text("完成登录")
                            .frame(minWidth: 90)
                    }
                    .controlSize(.large)
                    .disabled(model.loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("取消") { model.cancelLogin() }
                }

            case .submitting:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在校验授权码...")
                        .foregroundStyle(.secondary)
                }
                Spacer()

            case .switching:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在切换账号...")
                        .foregroundStyle(.secondary)
                }
                Spacer()

            case .success(let email):
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(email.map { "登录成功：\($0)" } ?? "登录成功")
                }
                Spacer()

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack {
                    Button("重试") { model.retryLogin() }
                    Spacer()
                    Button("关闭") { model.cancelLogin() }
                }
            }
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }
}
