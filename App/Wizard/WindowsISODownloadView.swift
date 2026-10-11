import SwiftUI
import WebKit

/// Microsoft's own Windows 11 for Arm download page, inside VMPane: the user picks the language and clicks
/// Microsoft's download button; the ISO is saved to ~/Downloads and handed to the wizard. VMPane does not fetch
/// Windows by itself (Gate 00), and the install checks the ISO (Windows 11, arm64) before using it.
struct WindowsISODownloadView: View {
    let done: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var browser = ISOBrowser()

    var body: some View {
        VStack(spacing: 0) {
            ISOWebView(browser: browser)
            Divider()
            HStack {
                switch browser.download {
                case .idle:
                    Text("Choose “Windows 11 (multi-edition ISO for Arm64)” and your language, then Download.")
                        .font(.callout).foregroundStyle(.secondary)
                case .running(let received, let total):
                    if let total, total > 0 {
                        ProgressView(value: Double(received), total: Double(total)).frame(width: 200)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Downloading… \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))")
                case .finished(let url):
                    Label("Downloaded \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") {
                    browser.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if case .finished(let url) = browser.download {
                    Button("Use This ISO") {
                        done(url)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 900, height: 680)
    }
}

/// The web view's state: navigation stays on Microsoft's pages; the ISO response becomes a download.
@MainActor
@Observable
final class ISOBrowser: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
    enum Download: Equatable {
        case idle
        case running(received: Int64, total: Int64?)
        case finished(URL)
        case failed(String)
    }

    static let page = URL(string: "https://www.microsoft.com/software-download/windows11arm64")

    var download: Download = .idle
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var active: WKDownload?
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private var progress: NSKeyValueObservation?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()  // nothing from this visit stays behind
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let page = Self.page { webView.load(URLRequest(url: page)) }
    }

    func cancel() {
        active?.cancel { _ in }
        active = nil
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let host = action.request.url?.host?.lowercased() else { return .cancel }
        // Microsoft's pages and its download hosts only.
        let allowed =
            host == "microsoft.com" || host.hasSuffix(".microsoft.com") || host.hasSuffix(".msft.net")
            || host.hasSuffix(".live.com") || host.hasSuffix(".microsoftonline.com")
        return allowed ? (action.shouldPerformDownload ? .download : .allow) : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let name = response.response.suggestedFilename ?? ""
        let isISO = name.lowercased().hasSuffix(".iso") || response.response.mimeType == "application/octet-stream"
        return response.canShowMIMEType && !isISO ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        start(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        start(download)
    }

    private func start(_ download: WKDownload) {
        active = download
        download.delegate = self
        self.download = .running(received: 0, total: nil)
        progress = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
            Task { @MainActor in self?.download = .running(received: received, total: total) }
        }
    }

    /// Links that open a new window (target=_blank) load here instead, through the same navigation rules.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        webView.load(action.request)
        return nil
    }

    // MARK: - Download

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        var url = folder.appendingPathComponent(suggestedFilename)
        let base = (suggestedFilename as NSString).deletingPathExtension
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(suffix).iso")
            suffix += 1
        }
        destination = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        progress = nil
        active = nil
        if let destination { self.download = .finished(destination) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        progress = nil
        active = nil
        self.download = .failed("The download stopped: \(error.localizedDescription)")
    }
}

private struct ISOWebView: NSViewRepresentable {
    let browser: ISOBrowser

    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
