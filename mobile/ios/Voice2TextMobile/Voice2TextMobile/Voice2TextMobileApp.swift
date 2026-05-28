import SwiftUI

@main
struct Voice2TextMobileApp: App {
    @StateObject private var viewModel = TranscriptionViewModel()
    @State private var pendingSharedURLs: [URL] = []
    @State private var sharedImportTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.importPendingSharedBatches()
                }
                .onOpenURL { url in
                    if url.scheme == "voice2text", url.host == "shared-imports" {
                        viewModel.importSharedBatch(from: url)
                    } else {
                        queueSharedURL(url)
                    }
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        viewModel.importPendingSharedBatches()
                    }
                }
        }
    }

    private func queueSharedURL(_ url: URL) {
        pendingSharedURLs.append(url)
        sharedImportTask?.cancel()
        sharedImportTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            let urls = pendingSharedURLs
            pendingSharedURLs.removeAll()
            viewModel.importSharedFiles(urls)
        }
    }
}
