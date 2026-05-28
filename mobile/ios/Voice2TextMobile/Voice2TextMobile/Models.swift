import Foundation

struct AppConfig: Equatable {
    var dashScopeAPIKey = ""
    var dashScopeBaseURL = "https://dashscope.aliyuncs.com/api/v1"
    var asrModel = "fun-asr"
    var llmModel = "qwen-plus"
    var shouldOrganize = true
    var organizeMode: OrganizeMode = .perFile

    var ossEndpoint = "https://oss-cn-beijing.aliyuncs.com"
    var ossBucket = ""
    var ossAccessKeyId = ""
    var ossAccessKeySecret = ""
    var ossSecurityToken = ""
    var ossPrefix = "voice2text/mobile"
    var signedURLTTLSeconds = 3600
    var deleteOSSObjectAfterASR = true

    var trimmedPrefix: String {
        ossPrefix.split(separator: "/").joined(separator: "/")
    }

    func validate() throws {
        let required: [(String, String)] = [
            ("DashScope API Key", dashScopeAPIKey),
            ("OSS Endpoint", ossEndpoint),
            ("OSS Bucket", ossBucket),
            ("OSS AccessKey ID", ossAccessKeyId),
            ("OSS AccessKey Secret", ossAccessKeySecret),
        ]

        for item in required where item.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.validation("请先在设置里填写 \(item.0)")
        }
    }
}

enum OrganizeMode: String, CaseIterable, Identifiable {
    case perFile = "per_file"
    case combined = "combined"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perFile:
            return "分别整理"
        case .combined:
            return "合并整理"
        }
    }
}

enum JobStatus: String, CaseIterable {
    case queued = "待处理"
    case uploading = "上传 OSS"
    case submitting = "提交 ASR"
    case transcribing = "云端转写"
    case organizing = "整理文本"
    case saving = "保存结果"
    case succeeded = "完成"
    case failed = "失败"
}

struct TranscriptJob: Identifiable, Equatable {
    let id: UUID
    var sourceURL: URL
    var originalFileKey: String
    var fileName: String
    var status: JobStatus
    var detail: String
    var taskID: String?
    var objectKey: String?
    var transcript: String?
    var markdown: String?
    var outputURL: URL?
    var errorMessage: String?

    init(sourceURL: URL, originalFileKey: String, fileName: String) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.originalFileKey = originalFileKey
        self.fileName = fileName
        self.status = .queued
        self.detail = "等待开始"
    }
}

struct OrganizedTranscript {
    var time: String
    var scene: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var tags: [String]
    var transcript: String

    var markdown: String {
        let keyPointText = keyPoints.isEmpty ? "- （暂无）" : keyPoints.map { "- \($0)" }.joined(separator: "\n")
        let actionText = actionItems.isEmpty ? "- （暂无）" : actionItems.map { "- \($0)" }.joined(separator: "\n")
        let tagText = tags.isEmpty ? "#未分类" : tags.joined(separator: " ")

        return """
        # 整理提炼

        - **时间**: \(time)
        - **场景**: \(scene)

        ## 摘要

        \(summary)

        ## 关键点

        \(keyPointText)

        ## 可执行事项

        \(actionText)

        ## 标签

        \(tagText)

        ## 语音文本

        \(transcript)
        """
    }
}

enum AppError: LocalizedError {
    case validation(String)
    case requestFailed(String)
    case invalidResponse(String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message), .requestFailed(let message), .invalidResponse(let message), .fileSystem(let message):
            return message
        }
    }
}
