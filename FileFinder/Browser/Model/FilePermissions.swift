import Darwin

/// Permissions as `ls -l` shows them, e.g. `drwxr-xr-x`.
nonisolated enum FilePermissions {
    /// The permissions of the item at `path`, without following a symbolic link.
    static func text(atPath path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return text(mode: info.st_mode)
    }

    static func text(mode: mode_t) -> String {
        let type: Character = switch mode & S_IFMT {
        case S_IFDIR: "d"
        case S_IFLNK: "l"
        case S_IFCHR: "c"
        case S_IFBLK: "b"
        case S_IFIFO: "p"
        case S_IFSOCK: "s"
        default: "-"
        }
        return String(type)
            + triplet(mode, read: S_IRUSR, write: S_IWUSR, execute: S_IXUSR, special: S_ISUID, mark: "s")
            + triplet(mode, read: S_IRGRP, write: S_IWGRP, execute: S_IXGRP, special: S_ISGID, mark: "s")
            + triplet(mode, read: S_IROTH, write: S_IWOTH, execute: S_IXOTH, special: S_ISVTX, mark: "t")
    }

    /// One `rwx` group; a set special bit shows as `s`/`t`, or `S`/`T` when not executable.
    private static func triplet(
        _ mode: mode_t, read: mode_t, write: mode_t, execute: mode_t, special: mode_t, mark: Character
    ) -> String {
        let executable = mode & execute != 0
        let last: Character = if mode & special != 0 {
            executable ? mark : Character(mark.uppercased())
        } else {
            executable ? "x" : "-"
        }
        return (mode & read != 0 ? "r" : "-") + (mode & write != 0 ? "w" : "-") + String(last)
    }
}
