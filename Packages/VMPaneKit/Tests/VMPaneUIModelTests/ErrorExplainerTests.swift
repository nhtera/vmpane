import Testing
import VMPaneCore

@testable import VMPaneUI

@Test func knownProblemsComeWithTheirFix() {
    let locked = ErrorExplainer.explain("This Mac is locked. Unlock it to restore a live snapshot (its saved memory is encrypted).")
    #expect(locked?.title == "This Mac was locked" && locked?.action == nil)
    #expect(ErrorExplainer.explain("needs 40 GiB free, 3 GiB available")?.action == .openStorageSettings)
    #expect(ErrorExplainer.explain("No space left on device")?.action == .openStorageSettings)
    #expect(ErrorExplainer.explain("not enough memory for this VM")?.action == .editResources)
    #expect(ErrorExplainer.explain("missing file current/disk.img")?.action == .showInFinder)
    #expect(
        ErrorExplainer.explain("Not found. The VM was moved, renamed or deleted, or it is on a disk that is not connected.")?.action
            == .removeFromLibrary)
    #expect(ErrorExplainer.explain("the guest agent is not connected") == nil, "no guess for an unknown cause")
    let diagnostics = ErrorExplainer.diagnostics(for: "boom", vm: "Ubuntu")
    #expect(diagnostics.contains("VMPane ") && diagnostics.contains("VM: Ubuntu") && diagnostics.contains("Error: boom"))
}

@Test func agentLevelsHaveOneVocabulary() {
    #expect(PolicyLevel.allCases.map(\.title) == ["Off", "Look only", "Use the screen and keyboard", "Run commands", "Full control"])
}
