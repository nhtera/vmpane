import Foundation

/// A VMPane release's version (`1.0.0`, `1.0.0-beta.11`), ordered as Semantic Versioning orders them: a pre-release
/// comes before its release, and its dot-separated parts compare as numbers when both are numbers. The guest tools
/// carry the version of the VMPane they came with, so an agent older than the helper's is due an update.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let core: [Int]
    public let prerelease: [String]

    /// Nil for what is not `major.minor.patch[-pre.release][+build]`.
    public init?(_ text: String) {
        let withoutBuild = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard core.count == 3, core.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.core = core.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard !prerelease.contains(where: \.isEmpty), parts.count == 1 || !prerelease.isEmpty else { return nil }
    }

    public var description: String {
        core.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        default: break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case (let leftNumber?, let rightNumber?): return leftNumber < rightNumber
            case (.some, nil): return true  // numbers come before words
            case (nil, .some): return false
            default: return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
