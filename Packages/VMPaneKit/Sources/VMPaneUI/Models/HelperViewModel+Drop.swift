import Foundation
import VMPaneControl
import VMPaneCore

extension HelperViewModel {
    /// Copies files and folders from the Mac into the guest (`vm.files.drop`): they land in a new folder in the
    /// logged-in user's Desktop/VMPane Drops, which the guest then shows. Needs the guest agent.
    public func drop(_ urls: [URL]) async {
        guard !urls.isEmpty, transfer == nil else { return }
        transfer = Transfer(bytesDone: 0, bytesTotal: 0, file: urls[0].lastPathComponent)
        defer { transfer = nil }
        do {
            _ = try await channel.call(
                ControlMethod.vmFilesDrop.rawValue, params: ["paths": .array(urls.map { .string($0.path) })], timeout: .seconds(3600))
        } catch let error as RPCError where error.message == "cancelled" {
            // The user stopped it.
        } catch let error as RPCError {
            lastError =
                error.code == ControlErrorCode.agentUnavailable.rawValue
                ? "Copying files into the VM needs VMPane's guest tools, with someone logged in. \(error.message)" : error.message
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Stops the copy in progress; what was copied so far is removed from the guest.
    public func cancelDrop() async {
        _ = try? await channel.call(ControlMethod.vmFilesCancel.rawValue, params: nil, timeout: .seconds(10))
    }
}
