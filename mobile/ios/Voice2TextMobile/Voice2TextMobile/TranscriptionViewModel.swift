import Foundation

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var config: AppConfig
    @Published var jobs: [TranscriptJob] = []
    @Published var isRunning = false
    @Published var message: String?
    @Published var combinedOutputURL: URL?

    init(config: AppConfig = ConfigStore.load()) {
        self.config = config
    }

    func saveConfig(_ newConfig: AppConfig) {
        do {
            try ConfigStore.save(newConfig)
            config = newConfig
            message = "设置已保存"
        } catch {
            message = error.localizedDescription
        }
    }

    func setOrganizeMode(_ mode: OrganizeMode) {
        guard config.organizeMode != mode else {
            return
        }

        var newConfig = config
        newConfig.organizeMode = mode
        do {
            try ConfigStore.save(newConfig)
            config = newConfig
            combinedOutputURL = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func importFiles(_ urls: [URL]) {
        do {
            var existingKeys = Set(jobs.map(\.originalFileKey))
            var importedJobs: [TranscriptJob] = []
            var skippedCount = 0

            for url in urls {
                let fileKey = originalFileKey(for: url)
                guard !existingKeys.contains(fileKey) else {
                    skippedCount += 1
                    continue
                }

                let copied = try copyIntoImportedAudio(url)
                importedJobs.append(TranscriptJob(sourceURL: copied, originalFileKey: fileKey, fileName: url.lastPathComponent))
                existingKeys.insert(fileKey)
            }

            jobs.append(contentsOf: importedJobs)
            if !importedJobs.isEmpty {
                combinedOutputURL = nil
            }
            if skippedCount > 0 {
                message = "已跳过 \(skippedCount) 个重复音频"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func importSharedFile(_ url: URL) {
        importSharedFiles([url])
    }

    func importSharedFiles(_ urls: [URL]) {
        let beforeCount = jobs.count
        importFiles(urls)
        let addedCount = jobs.count - beforeCount
        if addedCount == 1, let url = urls.first {
            message = "已从分享菜单添加音频：\(url.lastPathComponent)"
        } else if addedCount > 1 {
            message = "已从分享菜单添加 \(addedCount) 个音频"
        } else if message == nil {
            message = "没有新增音频"
        }
    }

    func importSharedBatch(from url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let batchID = components.queryItems?.first(where: { $0.name == "batch" })?.value,
            !batchID.isEmpty
        else {
            message = "分享导入失败：缺少批次信息"
            return
        }

        guard
            let groupIdentifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
            let sharedRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        else {
            message = "分享导入失败：未配置 App Group"
            return
        }

        let batchDirectory = sharedRoot
            .appendingPathComponent("SharedImports", isDirectory: true)
            .appendingPathComponent(batchID, isDirectory: true)

        importSharedBatchDirectory(batchDirectory, showNoNewAudioMessage: true)
    }

    func importPendingSharedBatches() {
        guard
            let groupIdentifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
            let sharedRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        else {
            return
        }

        let importsDirectory = sharedRoot.appendingPathComponent("SharedImports", isDirectory: true)
        guard FileManager.default.fileExists(atPath: importsDirectory.path) else {
            return
        }

        do {
            let batchDirectories = try FileManager.default.contentsOfDirectory(
                at: importsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for batchDirectory in batchDirectories {
                importSharedBatchDirectory(batchDirectory, showNoNewAudioMessage: false)
            }
        } catch {
            message = "分享导入失败：\(error.localizedDescription)"
        }
    }

    private func importSharedBatchDirectory(_ batchDirectory: URL, showNoNewAudioMessage: Bool) {
        let readyMarkerURL = batchDirectory.appendingPathComponent(".ready")
        guard FileManager.default.fileExists(atPath: readyMarkerURL.path) else {
            return
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: batchDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let audioURLs = urls.filter { $0.lastPathComponent != ".ready" }
            let beforeCount = jobs.count
            importFiles(audioURLs)
            try? FileManager.default.removeItem(at: batchDirectory)
            let addedCount = jobs.count - beforeCount
            if addedCount > 0 {
                message = "已从分享菜单添加 \(addedCount) 个音频"
            } else if showNoNewAudioMessage, message == nil {
                message = "没有新增音频"
            }
        } catch {
            message = "分享导入失败：\(error.localizedDescription)"
        }
    }

    func clearJobs() {
        for job in jobs where job.status != .uploading && job.status != .submitting && job.status != .transcribing && job.status != .organizing && job.status != .saving {
            removeLocalSourceIfNeeded(job.sourceURL)
        }
        jobs.removeAll { $0.status != .uploading && $0.status != .submitting && $0.status != .transcribing && $0.status != .organizing && $0.status != .saving }
        if jobs.isEmpty {
            combinedOutputURL = nil
        }
    }

    func removeJobs(at offsets: IndexSet) {
        var removableJobs: [TranscriptJob] = []
        for offset in offsets {
            let job = jobs[offset]
            if isRemovable(job) {
                removableJobs.append(job)
            }
        }

        for job in removableJobs {
            removeLocalSourceIfNeeded(job.sourceURL)
        }
        let removableIDs = Set(removableJobs.map { $0.id })
        jobs.removeAll { removableIDs.contains($0.id) }
        combinedOutputURL = nil
    }

    func removeJob(_ job: TranscriptJob) {
        guard isRemovable(job) else {
            return
        }
        removeLocalSourceIfNeeded(job.sourceURL)
        jobs.removeAll { $0.id == job.id }
        combinedOutputURL = nil
    }

    private func isRemovable(_ job: TranscriptJob) -> Bool {
        switch job.status {
        case .uploading, .submitting, .transcribing, .organizing, .saving:
            return false
        case .queued, .succeeded, .failed:
            return true
        }
    }

    func runAll() async {
        guard !isRunning else {
            return
        }

        do {
            try config.validate()
        } catch {
            message = error.localizedDescription
            return
        }

        isRunning = true
        defer { isRunning = false }
        combinedOutputURL = nil

        let targetIDs = jobs
            .filter { $0.status != .succeeded }
            .map(\.id)

        for id in targetIDs {
            await processJob(id, shouldOrganizeIndividually: config.organizeMode == .perFile)
        }

        if config.organizeMode == .combined {
            await organizeCombinedTranscript()
        }
    }

    private func processJob(_ id: UUID, shouldOrganizeIndividually: Bool) async {
        let oss = OSSClient(config: config)
        let dashScope = DashScopeClient(config: config)
        var uploadedObjectKey: String?

        do {
            guard let job = jobs.first(where: { $0.id == id }) else {
                return
            }

            let objectKey = buildObjectKey(for: job)
            uploadedObjectKey = objectKey
            updateJob(id, status: .uploading, detail: "上传到 \(config.ossBucket)", objectKey: objectKey, clearErrorMessage: true)

            let signedGETURL = try await oss.upload(fileURL: job.sourceURL, objectKey: objectKey)

            updateJob(id, status: .submitting, detail: "提交 DashScope ASR")
            let result = try await dashScope.transcribe(fileURL: signedGETURL) { [weak self] detail in
                self?.updateJob(id, status: .transcribing, detail: detail)
            }

            let markdown: String
            if shouldOrganizeIndividually {
                updateJob(id, status: .organizing, detail: config.shouldOrganize ? "调用 Qwen 整理文本" : "生成 Markdown")
                let organized = await dashScope.organize(transcript: result.transcript)
                markdown = organized.markdown
            } else {
                markdown = rawTranscriptMarkdown(fileName: job.fileName, transcript: result.transcript)
            }

            updateJob(id, status: .saving, detail: "保存到手机本地")
            let outputURL = try saveMarkdown(markdown, for: job.fileName)

            updateJob(
                id,
                status: .succeeded,
                detail: shouldOrganizeIndividually ? "已保存 \(outputURL.lastPathComponent)" : "已转录 \(outputURL.lastPathComponent)",
                taskID: result.taskID,
                transcript: result.transcript,
                markdown: markdown,
                outputURL: outputURL,
                clearErrorMessage: true
            )

            removeLocalSourceIfNeeded(job.sourceURL)

            if config.deleteOSSObjectAfterASR {
                await oss.delete(objectKey: objectKey)
            }
        } catch {
            if let objectKey = uploadedObjectKey, config.deleteOSSObjectAfterASR {
                await oss.delete(objectKey: objectKey)
            }
            updateJob(id, status: .failed, detail: "处理失败", errorMessage: error.localizedDescription)
        }
    }

    private func organizeCombinedTranscript() async {
        let dashScope = DashScopeClient(config: config)
        let sections = jobs.compactMap { job -> String? in
            guard job.status == .succeeded, let transcript = job.transcript else {
                return nil
            }
            return "## \(job.fileName)\n\n\(transcript)"
        }

        guard !sections.isEmpty else {
            return
        }

        do {
            for job in jobs where job.status == .succeeded {
                updateJob(job.id, status: .organizing, detail: "等待合并整理")
            }

            let combinedTranscript = sections.joined(separator: "\n\n---\n\n")
            let organized = await dashScope.organize(transcript: combinedTranscript)
            let outputURL = try saveMarkdown(organized.markdown, for: "合并整理.md")
            combinedOutputURL = outputURL

            for job in jobs where job.status == .organizing {
                updateJob(job.id, status: .succeeded, detail: "已加入合并整理")
            }
            message = "已保存合并整理：\(outputURL.lastPathComponent)"
        } catch {
            message = "合并整理失败：\(error.localizedDescription)"
            for job in jobs where job.status == .organizing {
                updateJob(job.id, status: .succeeded, detail: "已转录，合并整理失败")
            }
        }
    }

    private func updateJob(
        _ id: UUID,
        status: JobStatus? = nil,
        detail: String? = nil,
        taskID: String? = nil,
        objectKey: String? = nil,
        transcript: String? = nil,
        markdown: String? = nil,
        outputURL: URL? = nil,
        errorMessage: String? = nil,
        clearErrorMessage: Bool = false
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let status {
            jobs[index].status = status
        }
        if let detail {
            jobs[index].detail = detail
        }
        if let taskID {
            jobs[index].taskID = taskID
        }
        if let objectKey {
            jobs[index].objectKey = objectKey
        }
        if let transcript {
            jobs[index].transcript = transcript
        }
        if let markdown {
            jobs[index].markdown = markdown
        }
        if let outputURL {
            jobs[index].outputURL = outputURL
        }
        if clearErrorMessage {
            jobs[index].errorMessage = nil
        }
        if let errorMessage {
            jobs[index].errorMessage = errorMessage
        }
    }

    private func copyIntoImportedAudio(_ url: URL) throws -> URL {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let directory = try appSupportDirectory(named: "ImportedAudio")
        let destination = directory.appendingPathComponent(uniqueFileName(basedOn: url.lastPathComponent, in: directory))

        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            throw AppError.fileSystem("复制音频到 App 沙盒失败：\(error.localizedDescription)")
        }
    }

    private func originalFileKey(for url: URL) -> String {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        let resourceValues = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = resourceValues?.fileSize.map(String.init) ?? "unknown-size"
        let modifiedAt = resourceValues?.contentModificationDate?.timeIntervalSince1970.description ?? "unknown-date"
        return "\(path)|\(size)|\(modifiedAt)"
    }

    private func removeLocalSourceIfNeeded(_ url: URL) {
        guard url.isFileURL else {
            return
        }
        let importedAudioDirectory = try? appSupportDirectory(named: "ImportedAudio")
        guard let importedAudioDirectory, url.path.hasPrefix(importedAudioDirectory.path) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func saveMarkdown(_ markdown: String, for sourceFileName: String) throws -> URL {
        let directory = try documentsDirectory(named: "Voice2Text Results")
        let stem = (sourceFileName as NSString).deletingPathExtension
        let fileName = uniqueFileName(basedOn: "\(dateFilePrefix())_\(stem).md", in: directory)
        let destination = directory.appendingPathComponent(fileName)

        do {
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        } catch {
            throw AppError.fileSystem("保存 Markdown 失败：\(error.localizedDescription)")
        }
    }

    private func dateFilePrefix() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        return dateFormatter.string(from: Date())
    }

    private func rawTranscriptMarkdown(fileName: String, transcript: String) -> String {
        """
        # 原始转录

        - **文件**: \(fileName)

        ## 语音文本

        \(transcript)
        """
    }

    private func appSupportDirectory(named name: String) throws -> URL {
        try makeDirectory(searchPath: .applicationSupportDirectory, name: name)
    }

    private func documentsDirectory(named name: String) throws -> URL {
        try makeDirectory(searchPath: .documentDirectory, name: name)
    }

    private func makeDirectory(searchPath: FileManager.SearchPathDirectory, name: String) throws -> URL {
        let baseURL = try FileManager.default.url(
            for: searchPath,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func uniqueFileName(basedOn fileName: String, in directory: URL) -> String {
        let cleaned = fileName.replacingOccurrences(of: "/", with: "_")
        let name = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var candidate = cleaned
        var index = 2

        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(name)-\(index)" : "\(name)-\(index).\(ext)"
            index += 1
        }
        return candidate
    }

    private func buildObjectKey(for job: TranscriptJob) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let day = dateFormatter.string(from: Date())
        let ext = (job.fileName as NSString).pathExtension
        let prefix = config.trimmedPrefix
        let fileName = ext.isEmpty ? job.id.uuidString : "\(job.id.uuidString).\(ext)"
        let suffix = "\(day)/\(fileName)"
        return prefix.isEmpty ? suffix : "\(prefix)/\(suffix)"
    }

}
