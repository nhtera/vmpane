import Foundation
import VMPaneCore

/// `thumbnail.png` in the bundle: a small picture of the guest for the library (which watches the file), taken a few
/// seconds after a start, at a pause, every minute while the VM runs, and once more just before it stops.
extension HelperController {
    static let thumbnailInterval: Duration = .seconds(60)
    static let thumbnailEdge = 320
    static let thumbnailAfterStart: Duration = .seconds(5)

    var thumbnailURL: URL { prepared.lock.bundle.url.appendingPathComponent("thumbnail.png") }

    func thumbnailsFollowState(_ next: VMRunState) {
        switch next {
        case .running where thumbnailTask == nil:
            thumbnailTask = Task { [weak self] in
                try? await Task.sleep(for: Self.thumbnailAfterStart)
                while !Task.isCancelled {
                    await self?.writeThumbnail()
                    try? await Task.sleep(for: Self.thumbnailInterval)
                }
            }
        case .paused:
            Task { await writeThumbnail() }
        case .stopped, .error, .suspending:
            thumbnailTask?.cancel()
            thumbnailTask = nil
        default:
            break
        }
    }

    /// A screenshot of the guest, small, written atomically (a failed capture keeps the last one).
    func writeThumbnail() async {
        guard let backend, state == .running || state == .paused,
            let shot = try? await backend.screenshot(maxEdge: Self.thumbnailEdge)
        else { return }
        let url = thumbnailURL
        await Blocking.run { try? shot.png.write(to: url, options: .atomic) }
    }
}
