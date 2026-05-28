import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @State private var isImporting = false
    @State private var isShowingSettings = false
    @State private var markdownPreview: MarkdownPreview?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("\(viewModel.jobs.count) 个文件", systemImage: "waveform")
                        Spacer()
                        if viewModel.isRunning {
                            ProgressView()
                        }
                    }

                    Toggle(isOn: organizeTogetherBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("合并整理")
                            Text(viewModel.config.organizeMode == .combined ? "多个音频转录后合并生成一个概要" : "每个音频分别生成概要")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(viewModel.isRunning)

                    if let combinedOutputURL = viewModel.combinedOutputURL {
                        HStack(spacing: 12) {
                            Button {
                                showMarkdownPreview(title: combinedOutputURL.lastPathComponent, markdown: nil, url: combinedOutputURL)
                            } label: {
                                Label("查看合并", systemImage: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.bordered)

                            ShareLink(item: combinedOutputURL) {
                                Label("分享合并", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    HStack {
                        Button {
                            isImporting = true
                        } label: {
                            Label("选择音频", systemImage: "folder")
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button {
                            Task { await viewModel.runAll() }
                        } label: {
                            Label(viewModel.isRunning ? "转写中" : "开始转写", systemImage: viewModel.isRunning ? "hourglass" : "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.jobs.isEmpty || viewModel.isRunning)
                    }
                }

                if viewModel.jobs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有音频")
                                .font(.headline)
                            Text("从「文件」App 或 iCloud Drive 选择录音。App 会直接上传到 OSS，再调用 DashScope ASR 完成转写。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section("任务") {
                        ForEach(viewModel.jobs) { job in
                            JobRow(job: job) {
                                showMarkdownPreview(title: job.fileName, markdown: job.markdown, url: job.outputURL)
                            } onDelete: {
                                viewModel.removeJob(job)
                            }
                        }
                        .onDelete(perform: viewModel.removeJobs)
                    }
                }
            }
            .navigationTitle("voice2text")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        viewModel.clearJobs()
                    } label: {
                        Label("清理", systemImage: "trash")
                    }
                    .disabled(viewModel.isRunning || viewModel.jobs.isEmpty)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.audio, .movie],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    viewModel.importFiles(urls)
                case .failure(let error):
                    viewModel.message = error.localizedDescription
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(viewModel: viewModel)
            }
            .sheet(item: $markdownPreview) { preview in
                MarkdownPreviewView(preview: preview)
            }
            .alert("提示", isPresented: messageBinding) {
                Button("好", role: .cancel) {
                    viewModel.message = nil
                }
            } message: {
                Text(viewModel.message ?? "")
            }
        }
    }

    private func showMarkdownPreview(title: String, markdown: String?, url: URL?) {
        if let markdown {
            markdownPreview = MarkdownPreview(title: title, content: markdown)
            return
        }

        guard let url else {
            viewModel.message = "还没有可查看的 Markdown"
            return
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            markdownPreview = MarkdownPreview(title: title, content: content)
        } catch {
            viewModel.message = "读取 Markdown 失败：\(error.localizedDescription)"
        }
    }

    private var organizeTogetherBinding: Binding<Bool> {
        Binding(
            get: { viewModel.config.organizeMode == .combined },
            set: { isCombined in
                viewModel.setOrganizeMode(isCombined ? .combined : .perFile)
            }
        )
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { viewModel.message != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.message = nil
                }
            }
        )
    }
}

private struct JobRow: View {
    let job: TranscriptJob
    let onPreview: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.fileName)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(job.status.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(statusColor)
            }

            Text(job.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let errorMessage = job.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if job.outputURL != nil || isRemovable {
                HStack(spacing: 16) {
                    if let outputURL = job.outputURL {
                        Button(action: onPreview) {
                            Label("查看", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline.weight(.semibold))

                        ShareLink(item: outputURL) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline.weight(.semibold))
                    }

                    Spacer(minLength: 24)

                    Menu {
                        Button(role: .destructive, action: onDelete) {
                            Label("删除任务", systemImage: "trash")
                        }
                    } label: {
                        Label("更多操作", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 36)
                    }
                    .disabled(!isRemovable)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private var isRemovable: Bool {
        switch job.status {
        case .uploading, .submitting, .transcribing, .organizing, .saving:
            return false
        case .queued, .succeeded, .failed:
            return true
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .queued:
            return .secondary
        default:
            return .blue
        }
    }
}

private struct MarkdownPreview: Identifiable {
    let id = UUID()
    let title: String
    let content: String
}

private struct MarkdownPreviewView: View {
    let preview: MarkdownPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(preview.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(preview.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppConfig

    init(viewModel: TranscriptionViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.config)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("DashScope") {
                    SecureField("API Key", text: $draft.dashScopeAPIKey)
                        .autocorrectionDisabled()
                    TextField("Base URL", text: $draft.dashScopeBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("ASR 模型", text: $draft.asrModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("转写后自动整理", isOn: $draft.shouldOrganize)
                    TextField("整理模型", text: $draft.llmModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!draft.shouldOrganize)
                }

                Section("OSS") {
                    TextField("Endpoint", text: $draft.ossEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Bucket", text: $draft.ossBucket)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("AccessKey ID", text: $draft.ossAccessKeyId)
                        .autocorrectionDisabled()
                    SecureField("AccessKey Secret", text: $draft.ossAccessKeySecret)
                        .autocorrectionDisabled()
                    SecureField("STS Security Token（可选）", text: $draft.ossSecurityToken)
                        .autocorrectionDisabled()
                    TextField("对象前缀", text: $draft.ossPrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("签名 URL 有效期：\(draft.signedURLTTLSeconds) 秒", value: $draft.signedURLTTLSeconds, in: 300...32400, step: 300)
                    Toggle("ASR 完成后删除 OSS 临时文件", isOn: $draft.deleteOSSObjectAfterASR)
                }

                Section {
                    Text("建议使用只允许访问指定 OSS 前缀的 RAM 用户或 STS 临时凭证。直接在手机端访问云服务时，密钥只保存在本机 Keychain，但仍需要按移动端凭证来管理风险。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("云服务设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.saveConfig(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}
