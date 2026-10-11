import ArgumentParser
import VMPaneCore

/// `vmpane`: VMPane's virtual machines from the command line. Running VMs are reached through their helper (the
/// same control socket the app uses); a command that needs a VM process starts its helper headless.
@main
struct VMPaneCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vmpane",
        abstract: "Control VMPane virtual machines from the command line.",
        version: VMPane.version,
        subcommands: [
            List.self, Info.self, Start.self, Stop.self, Suspend.self, Pause.self, Resume.self, Snapshot.self, Exec.self,
            Port.self, Screenshot.self, Operator.self, Version.self,
        ]
    )
}
