import Darwin
import Foundation

public enum PrivateFile {
    /// Whether `url` is a regular file (not a link) owned by this user and readable by no one else.
    public static func isPrivateRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }
}
