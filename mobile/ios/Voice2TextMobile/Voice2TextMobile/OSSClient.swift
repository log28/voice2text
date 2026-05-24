import CommonCrypto
import Foundation

struct OSSClient {
    let config: AppConfig

    func upload(fileURL: URL, objectKey: String) async throws -> URL {
        let contentType = "application/octet-stream"
        let uploadURL = try signedURL(method: "PUT", objectKey: objectKey, expiresIn: config.signedURLTTLSeconds, contentType: contentType)
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        try validateOSSResponse(response, operation: "OSS 上传")
        return try signedURL(method: "GET", objectKey: objectKey, expiresIn: config.signedURLTTLSeconds, contentType: "")
    }

    func delete(objectKey: String) async {
        do {
            let url = try signedURL(method: "DELETE", objectKey: objectKey, expiresIn: 300, contentType: "")
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            let (_, response) = try await URLSession.shared.data(for: request)
            try validateOSSResponse(response, operation: "OSS 删除", allowNotFound: true)
        } catch {
            // 临时文件删除失败不影响已完成的转写结果。
        }
    }

    func signedURL(method: String, objectKey: String, expiresIn: Int, contentType: String) throws -> URL {
        let expires = Int(Date().timeIntervalSince1970) + max(60, expiresIn)
        let canonicalResource = "/\(config.ossBucket)/\(objectKey)"
        let stringToSign = "\(method.uppercased())\n\n\(contentType)\n\(expires)\n\(canonicalResource)"
        let signature = HMACSHA1.sign(message: stringToSign, key: config.ossAccessKeySecret)

        var components = try baseObjectURLComponents(objectKey: objectKey)
        var queryItems = [
            URLQueryItem(name: "OSSAccessKeyId", value: config.ossAccessKeyId),
            URLQueryItem(name: "Expires", value: String(expires)),
            URLQueryItem(name: "Signature", value: signature),
        ]
        let token = config.ossSecurityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            queryItems.append(URLQueryItem(name: "security-token", value: token))
        }
        components.percentEncodedQuery = queryItems
            .map { item in
                let name = percentEncodeQueryComponent(item.name)
                let value = percentEncodeQueryComponent(item.value ?? "")
                return "\(name)=\(value)"
            }
            .joined(separator: "&")

        guard let url = components.url else {
            throw AppError.validation("无法生成 OSS 签名 URL")
        }
        return url
    }

    private func baseObjectURLComponents(objectKey: String) throws -> URLComponents {
        var endpoint = config.ossEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.contains("://") {
            endpoint = "https://\(endpoint)"
        }
        guard let endpointURL = URL(string: endpoint), let endpointHost = endpointURL.host else {
            throw AppError.validation("OSS Endpoint 格式不正确")
        }

        var components = URLComponents()
        components.scheme = endpointURL.scheme ?? "https"
        components.host = "\(config.ossBucket).\(endpointHost)"
        components.percentEncodedPath = "/" + percentEncodeObjectPath(objectKey)
        return components
    }

    private func percentEncodeObjectPath(_ objectKey: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#[]@!$&'()*+,;="))
        return objectKey
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private func percentEncodeQueryComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func validateOSSResponse(_ response: URLResponse, operation: String, allowNotFound: Bool = false) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse("\(operation)没有返回 HTTP 状态")
        }
        if allowNotFound, http.statusCode == 404 {
            return
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppError.requestFailed("\(operation)失败，HTTP \(http.statusCode)")
        }
    }
}

enum HMACSHA1 {
    static func sign(message: String, key: String) -> String {
        let keyData = Data(key.utf8)
        let messageData = Data(message.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        keyData.withUnsafeBytes { keyBytes in
            messageData.withUnsafeBytes { messageBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBytes.baseAddress,
                    keyData.count,
                    messageBytes.baseAddress,
                    messageData.count,
                    &digest
                )
            }
        }

        return Data(digest).base64EncodedString()
    }
}
