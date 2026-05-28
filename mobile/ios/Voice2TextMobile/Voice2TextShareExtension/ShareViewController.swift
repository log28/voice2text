import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "正在导入到 voice2text..."
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else {
            return
        }
        didStart = true
        collectSharedFiles()
    }

    private func collectSharedFiles() {
        guard
            let groupIdentifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
            let sharedRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        else {
            finishWithError("未配置 App Group，无法导入多个音频。")
            return
        }

        let batchID = UUID().uuidString
        let batchDirectory = sharedRoot
            .appendingPathComponent("SharedImports", isDirectory: true)
            .appendingPathComponent(batchID, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
        } catch {
            finishWithError("创建共享目录失败：\(error.localizedDescription)")
            return
        }

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finishWithError("没有收到可导入的音频。")
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var copiedCount = 0
        var firstError: String?

        for provider in providers {
            guard let typeIdentifier = preferredTypeIdentifier(for: provider) else {
                continue
            }

            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                defer { group.leave() }

                if let error {
                    lock.withLock {
                        firstError = firstError ?? error.localizedDescription
                    }
                    return
                }
                guard let url else {
                    lock.withLock {
                        firstError = firstError ?? "收到空文件地址"
                    }
                    return
                }

                do {
                    let destination = batchDirectory.appendingPathComponent(
                        self.uniqueFileName(basedOn: url.lastPathComponent, in: batchDirectory)
                    )
                    try FileManager.default.copyItem(at: url, to: destination)
                    lock.withLock {
                        copiedCount += 1
                    }
                } catch {
                    lock.withLock {
                        firstError = firstError ?? error.localizedDescription
                    }
                }
            }
        }

        group.notify(queue: .main) {
            guard copiedCount > 0 else {
                self.finishWithError(firstError ?? "没有导入任何音频。")
                return
            }

            do {
                let markerURL = batchDirectory.appendingPathComponent(".ready")
                try Data().write(to: markerURL, options: .atomic)
            } catch {
                self.finishWithError("标记共享导入失败：\(error.localizedDescription)")
                return
            }

            var components = URLComponents()
            components.scheme = "voice2text"
            components.host = "shared-imports"
            components.queryItems = [
                URLQueryItem(name: "batch", value: batchID),
            ]

            guard let url = components.url else {
                self.finishWithError("无法唤起 voice2text。")
                return
            }

            self.statusLabel.text = "已准备 \(copiedCount) 个音频，正在打开 voice2text..."
            self.extensionContext?.open(url) { _ in
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        let candidates = [
            UTType.audio.identifier,
            UTType.movie.identifier,
            "public.mpeg-4-audio",
            "com.apple.m4a-audio",
            "public.mp3",
            "com.microsoft.waveform-audio",
            UTType.fileURL.identifier,
        ]
        return candidates.first { provider.hasItemConformingToTypeIdentifier($0) }
    }

    private func uniqueFileName(basedOn fileName: String, in directory: URL) -> String {
        let cleaned = fileName.isEmpty ? "\(UUID().uuidString).m4a" : fileName.replacingOccurrences(of: "/", with: "_")
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

    private func finishWithError(_ message: String) {
        statusLabel.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
