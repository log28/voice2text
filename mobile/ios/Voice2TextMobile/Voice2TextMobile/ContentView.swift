import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @State private var isImporting = false
    @State private var isShowingSettings = false

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
            .alert("提示", isPresented: messageBinding) {
                Button("好", role: .cancel) {
                    viewModel.message = nil
                }
            } message: {
                Text(viewModel.message ?? "")
            }
        }
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
                        ShareLink(item: outputURL) {
                            Label("分享 Markdown", systemImage: "square.and.arrow.up")
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
