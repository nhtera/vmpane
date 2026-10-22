import AppKit
import Foundation
import VMPaneCore

/// A problem with a known cause, as the library shows it: what happened in a line, the fix, and the action that does it.
public struct ErrorExplanation: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Where the VM's memory is set (the inspector's Resources).
        case editResources
        /// macOS's Storage settings.
        case openStorageSettings
        case showInFinder
        case removeFromLibrary
    }

    public var title: String
    public var fix: String
    public var action: Action?
    public var actionTitle: String? {
        switch action {
        case .editResources?: "Change Memory…"
        case .openStorageSettings?: "Open Storage Settings"
        case .showInFinder?: "Show in Finder"
        case .removeFromLibrary?: "Remove from Library"
        case nil: nil
        }
    }
}

/// Known causes of VMPane's errors (by what their text says), each with the fix.
public enum ErrorExplainer {
    public static func explain(_ message: String) -> ErrorExplanation? {
        let text = message.lowercased()
        func has(_ parts: String...) -> Bool { parts.allSatisfy(text.contains) }
        if has("mac is locked") || has("locked", "decrypt") {
            return ErrorExplanation(
                title: "This Mac was locked", fix: "Unlock the Mac, then try again: a VM's saved memory is encrypted while it is locked.")
        }
        if has("no space left") || has("gib free") || has("mib free") || has("insufficient space") {
            return ErrorExplanation(
                title: "This Mac's disk is nearly full", fix: "Free some space (empty the Trash, delete old snapshots), then try again.",
                action: .openStorageSettings)
        }
        if has("memory") && (has("not enough") || has("low") || has("pressure")) {
            return ErrorExplanation(
                title: "Not enough memory", fix: "Quit some apps or other VMs, or give this VM less memory.", action: .editResources)
        }
        if has("sandbox") || has("operation not permitted") {
            return ErrorExplanation(
                title: "macOS refused access to a file",
                fix: "Move the file into your home folder (or a shared folder you chose) and choose it again.")
        }
        if has("missing file") || (has("no such file") && (has(".iso") || has(".img"))) {
            return ErrorExplanation(
                title: "A disk or installer image is missing",
                fix: "Put the file back where it was, or open the VM's settings and remove or replace it.", action: .showInFinder)
        }
        if has("not found. the vm was moved") {
            return ErrorExplanation(
                title: "The VM is not where it was", fix: "Reconnect its disk, or take it off the list.", action: .removeFromLibrary)
        }
        return nil
    }

    /// What to paste into a bug report: VMPane's and macOS's versions, the Mac, and the error.
    public static func diagnostics(for message: String, vm name: String) -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelName = String(bytes: model.prefix { $0 != 0 }, encoding: .utf8) ?? "?"
        return [
            "VMPane \(VMPane.version)", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(modelName), \(ProcessInfo.processInfo.physicalMemory >> 30) GB",
            "VM: \(name)", "Error: \(message)",
        ].joined(separator: "\n")
    }

    public static func copyDiagnostics(for message: String, vm name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(for: message, vm: name), forType: .string)
    }
}
