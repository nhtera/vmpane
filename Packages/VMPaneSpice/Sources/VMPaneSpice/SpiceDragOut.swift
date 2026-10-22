import AppKit
import UniformTypeIdentifiers

/// Files dragged out of the guest into Finder (Windows guests with VMPane's agent), set by the helper: `probe` names
/// what the guest's drag carries once the pointer leaves the VM's view, `copy` puts one at a place on the Mac (what
/// Finder asked for) and says where it landed.
public struct SpiceDragOut: Sendable {
    public struct Item: Sendable, Equatable {
        /// The guest's path.
        public let path: String
        public let folder: Bool

        public init(path: String, folder: Bool) {
            self.path = path
            self.folder = folder
        }

        /// The name the guest gives it (the last component, either separator).
        var name: String { path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path }

        var type: UTType { folder ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data }
    }

    public let probe: @Sendable () async -> [Item]
    public let copy: @Sendable (String, URL) async throws -> URL

    public init(probe: @escaping @Sendable () async -> [Item], copy: @escaping @Sendable (String, URL) async throws -> URL) {
        self.probe = probe
        self.copy = copy
    }
}

/// One dragged guest item as a file promise: written when Finder drops it, by copying it out of the guest.
final class GuestFilePromise: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private let item: SpiceDragOut.Item
    private let copy: @Sendable (String, URL) async throws -> URL
    private let queue = OperationQueue()

    init(_ item: SpiceDragOut.Item, copy: @escaping @Sendable (String, URL) async throws -> URL) {
        self.item = item
        self.copy = copy
    }

    /// A provider that keeps this promise alive (its delegate is weak).
    func provider() -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: item.type.identifier, delegate: self)
        provider.userInfo = self
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { item.name }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let (path, copy) = (item.path, copy)
        Task {
            do {
                _ = try await copy(path, url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}
