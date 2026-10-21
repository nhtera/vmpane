import CoreGraphics
import Foundation

/// The ids vm_read_screen gave out for one VM, with their boxes in guest pixels (a later screenshot's scale does
/// not move them). Ids are never reused while they live: every read numbers on from the last, so an id from an
/// earlier read clicks what that read saw, or nothing. Each lives 60 s, and goes when an input changes the screen
/// where it is (or a quarter of it).
struct ElementCache {
    static let lifetime = Duration.seconds(60)
    /// A change this large (a new window, a dialog) makes every id stale.
    static let staleRatio = 0.25

    private var boxes: [String: (rect: CGRect, read: ContinuousClock.Instant)] = [:]
    private var next = 1

    /// Ids for `rects` (in order, with `prefix`: t for text, e for controls), remembered from `now`.
    mutating func add(_ rects: [CGRect], prefix: String, now: ContinuousClock.Instant = .now) -> [String] {
        boxes = boxes.filter { $0.value.read.duration(to: now) < Self.lifetime }
        return rects.map { rect in
            let id = "\(prefix)\(next)"
            next += 1
            boxes[id] = (rect, now)
            return id
        }
    }

    /// The box of `id` (guest pixels), or why there is none.
    func rect(_ id: String, now: ContinuousClock.Instant = .now) -> Result<CGRect, ToolFailure> {
        guard let box = boxes[id], box.read.duration(to: now) < Self.lifetime else {
            return .failure(
                ToolFailure("element \(id.debugDescription) is unknown or stale (60 s, or the screen changed there): read the screen again")
            )
        }
        return .success(box.rect)
    }

    /// Forgets the ids where the screen changed (`box`, guest pixels), or all of them after a change of at least
    /// `staleRatio` of the screen.
    mutating func changed(_ box: CGRect?, ratio: Double) {
        guard ratio < Self.staleRatio, let box else {
            boxes = [:]
            return
        }
        boxes = boxes.filter { !$0.value.rect.intersects(box) }
    }
}
