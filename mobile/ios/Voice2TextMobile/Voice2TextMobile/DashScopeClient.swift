import Foundation

struct DashScopeClient {
    let config: AppConfig

    func transcribe(fileURL: URL, progress: @escaping (String) async -> Void) async throws -> (taskID: String, transcript: String) {
        await progress("提交转写任务")
        let taskID = try await submitASRTask(fileURL: fileURL)

        await progress("等待云端转写")
        let taskPayload = try await waitForASRTask(taskID: taskID)
        let transcriptURLs = try extractTranscriptionURLs(from: taskPayload)

        await progress("下载转写结果")
        let transcript = try await downloadTranscript(from: transcriptURLs)
        return (taskID, transcript)
    }

    func organize(transcript: String, occurredAt: Date = Date()) async -> OrganizedTranscript {
        guard config.shouldOrganize else {
            return fallbackOrganization(transcript: transcript, occurredAt: occurredAt)
        }

        do {
            return try await callLLMOrganizer(transcript: transcript, occurredAt: occurredAt)
        } catch {
            return fallbackOrganization(transcript: transcript, occurredAt: occurredAt)
        }
    }

    private func submitASRTask(fileURL: URL) async throws -> String {
        let payload: [String: Any] = [
            "model": config.asrModel,
            "input": [
                "file_urls": [fileURL.absoluteString],
            ],
        ]

        var request = try dashScopeRequest(path: "/services/audio/asr/transcription", method: "POST")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let response = try await requestJSON(request)
        guard
            let output = response["output"] as? [String: Any],
            let taskID = output["task_id"] as? String,
            !taskID.isEmpty
        else {
            throw AppError.invalidResponse("ASR 提交成功但没有返回 task_id")
        }
        return taskID
    }

    private func waitForASRTask(taskID: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(15 * 60)

        while Date() < deadline {
            let request = try dashScopeRequest(path: "/tasks/\(taskID)", method: "GET")
            let response = try await requestJSON(request)

            guard let output = response["output"] as? [String: Any] else {
                throw AppError.invalidResponse("ASR 查询结果缺少 output")
            }

            let status = String(describing: output["task_status"] ?? "").uppercased()
            if status == "SUCCEEDED" {
                return response
            }
            if ["FAILED", "CANCELED"].contains(status) {
                throw AppError.requestFailed(describeASRFailure(output))
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        throw AppError.requestFailed("ASR 任务等待超时")
    }

    private func describeASRFailure(_ output: [String: Any]) -> String {
        if let results = output["results"] as? [[String: Any]], let first = results.first {
            let code = stringValue(first["code"], fallback: stringValue(output["code"], fallback: "UNKNOWN"))
            let message = stringValue(first["message"], fallback: stringValue(output["message"], fallback: "未知错误"))
            if code == "FILE_403_FORBIDDEN" {
                return "ASR 任务失败：DashScope 无法读取 OSS 临时文件（FILE_403_FORBIDDEN）。请重新转写；如果仍失败，请检查 OSS Bucket 权限、Endpoint 地域和 AccessKey 权限。"
            }
            return "ASR 任务失败：\(code) \(message)"
        }

        let code = stringValue(output["code"], fallback: "UNKNOWN")
        let message = stringValue(output["message"], fallback: "未知错误")
        return "ASR 任务失败：\(code) \(message)"
    }

    private func extractTranscriptionURLs(from payload: [String: Any]) throws -> [URL] {
        guard
            let output = payload["output"] as? [String: Any],
            let results = output["results"] as? [[String: Any]]
        else {
            throw AppError.invalidResponse("ASR 完成但没有 results")
        }

        let urls = results.compactMap { item -> URL? in
            guard
                String(describing: item["subtask_status"] ?? "SUCCEEDED").uppercased() == "SUCCEEDED",
                let rawURL = item["transcription_url"] as? String
            else {
                return nil
            }
            return secureURL(from: rawURL)
        }

        guard !urls.isEmpty else {
            throw AppError.invalidResponse("ASR 完成但没有可下载的转写结果")
        }
        return urls
    }

    private func downloadTranscript(from urls: [URL]) async throws -> String {
        var texts: [String] = []

        for url in urls {
            let secureURL = try secureURL(from: url)
            let (data, response) = try await URLSession.shared.data(from: secureURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw AppError.requestFailed("下载转写 JSON 失败")
            }
            let json = try JSONSerialization.jsonObject(with: data)
            texts.append(contentsOf: extractTexts(from: json))
        }

        let transcript = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw AppError.invalidResponse("转写结果为空")
        }
        return transcript
    }

    private func extractTexts(from value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var texts: [String] = []
            if let text = dictionary["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(text)
            }
            for key in ["transcripts", "sentences", "sentence_list", "paragraphs"] {
                if let items = dictionary[key] as? [Any] {
                    texts.append(contentsOf: items.flatMap { extractTexts(from: $0) })
                }
            }
            return texts
        }

        if let array = value as? [Any] {
            return array.flatMap { extractTexts(from: $0) }
        }

        return []
    }

    private func callLLMOrganizer(transcript: String, occurredAt: Date) async throws -> OrganizedTranscript {
        let isoTime = ISO8601DateFormatter().string(from: occurredAt)
        let systemPrompt = "你是专业的语音转写整理助手。请在不改动原始转写文本任何字词的前提下，生成结构化整理结果。场景仅能是：会议、灵感、日常。标签需带#前缀。必须返回 JSON 对象，字段：time, scene, summary, key_points, action_items, tags。其中 key_points/action_items/tags 必须是字符串数组，summary 控制在 1-2 句话。"
        let userPrompt = "发生时间：\(isoTime)\n请整理以下语音文本：\n\(transcript)"

        let payload: [String: Any] = [
            "model": config.llmModel,
            "input": [
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt],
                ],
            ],
            "parameters": [
                "result_format": "message",
                "temperature": 0.2,
            ],
        ]

        var request = try dashScopeRequest(path: "/services/aigc/text-generation/generation", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let response = try await requestJSON(request)
        guard
            let output = response["output"] as? [String: Any],
            let choices = output["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw AppError.invalidResponse("LLM 返回格式不完整")
        }

        let parsed = try parseJSONBlock(content)
        return OrganizedTranscript(
            time: stringValue(parsed["time"], fallback: isoTime),
            scene: normalizeScene(parsed["scene"]),
            summary: stringValue(parsed["summary"], fallback: "未生成摘要"),
            keyPoints: stringArray(parsed["key_points"]),
            actionItems: stringArray(parsed["action_items"]),
            tags: normalizeTags(stringArray(parsed["tags"])),
            transcript: transcript
        )
    }

    private func fallbackOrganization(transcript: String, occurredAt: Date) -> OrganizedTranscript {
        let preview = String(transcript.replacingOccurrences(of: "\n", with: " ").prefix(80))
        let summary = preview.isEmpty ? "该段语音内容较短，建议补充更多上下文。" : "该段语音主要提到：\(preview)"

        return OrganizedTranscript(
            time: ISO8601DateFormatter().string(from: occurredAt),
            scene: "日常",
            summary: summary,
            keyPoints: ["建议人工补充关键点（当前为降级结果）。"],
            actionItems: ["建议复核并补充可执行事项。"],
            tags: ["#语音整理"],
            transcript: transcript
        )
    }

    private func dashScopeRequest(path: String, method: String) throws -> URLRequest {
        let base = normalizedHTTPSBaseURL(config.dashScopeBaseURL)
        guard let url = URL(string: base + path) else {
            throw AppError.validation("DashScope Base URL 格式不正确")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.dashScopeAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func normalizedHTTPSBaseURL(_ rawBaseURL: String) -> String {
        var base = rawBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !base.contains("://") {
            base = "https://\(base)"
        }
        guard var components = URLComponents(string: base) else {
            return base
        }
        components.scheme = "https"
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? base
    }

    private func secureURL(from rawURL: String) -> URL? {
        guard let url = URL(string: rawURL) else {
            return nil
        }
        return try? secureURL(from: url)
    }

    private func secureURL(from url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AppError.validation("URL 格式不正确")
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard let secureURL = components.url else {
            throw AppError.validation("URL 格式不正确")
        }
        return secureURL
    }

    private func requestJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse("DashScope 没有返回 HTTP 状态")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AppError.requestFailed("DashScope 请求失败，HTTP \(http.statusCode)：\(detail)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalidResponse("DashScope 返回不是 JSON 对象")
        }
        return json
    }

    private func parseJSONBlock(_ content: String) throws -> [String: Any] {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let data = Data(cleaned.utf8)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalidResponse("LLM 返回内容不是 JSON 对象")
        }
        return json
    }

    private func stringValue(_ value: Any?, fallback: String) -> String {
        guard let value else {
            return fallback
        }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    private func normalizeScene(_ value: Any?) -> String {
        let raw = stringValue(value, fallback: "日常")
        return ["会议", "灵感", "日常"].contains(raw) ? raw : "日常"
    }

    private func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else {
            return []
        }
        return array
            .map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizeTags(_ tags: [String]) -> [String] {
        tags.map { tag in
            tag.hasPrefix("#") ? tag : "#\(tag)"
        }
    }
}
