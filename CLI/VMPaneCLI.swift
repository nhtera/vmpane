import ArgumentParser
import VMPaneCore

/// `vmpane` command-line tool. Subcommands (list, start, exec, mcp, …) are added in later phases.
@main
struct VMPaneCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vmpane",
        abstract: "Control VMPane virtual machines from the command line.",
        version: VMPane.version
    )
}
