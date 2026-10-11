import Foundation
import VMPaneCore

/// `thumbnail.png` in the bundle: a small picture of the guest for the library, refreshed every minute while the
/// VM runs and once more just before it stops.
extension HelperController {
    static let thumbnailInterval: Duration = .seconds(60)
    static let thumbnailEdge = 320

    var thumbnailURL: URL { prepared.lock.bundle.url.appendingPathComponent("thumbnail.png") }

    func thumbnailsFollowState(_ next: VMRunState) {
        switch next {
        case .running where thumbnailTask == nil:
            thumbnailTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.thumbnailInterval)
                    await self?.writeThumbnail()
                }
            }
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
