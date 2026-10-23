import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The kind of a file-system node as reported by `lstat` (symbolic links are never followed).
public enum NodeType: String, Codable, Sendable {
    case file
    case directory
    case symlink
    case other
}

/// Identity and metadata of a file-system node, read with `lstat`.
///
/// `device` + `inode` identify a node uniquely on a mounted system, which lets
/// Noria avoid counting hard-linked files twice and detect that a path was
/// replaced between the scan and the cleanup.
public struct FileStat: Sendable, Hashable, Codable {
    public var device: UInt64
    public var inode: UInt64
    public var type: NodeType
    /// Logical size in bytes.
    public var size: Int64
    /// Bytes actually allocated on disk (blocks × 512). This is what is freed on deletion.
    public var allocatedSize: Int64
    public var linkCount: UInt64
    public var modificationDate: Date

    public var identity: FileIdentity { FileIdentity(device: device, inode: inode) }
}

public struct FileIdentity: Sendable, Hashable, Codable {
    public var device: UInt64
    public var inode: UInt64
}

/// An entry returned by `FileSystem.directoryEntries`.
public struct DirectoryEntry: Sendable {
    public var name: String
    public var path: String
}

/// Thin, portable wrappers over POSIX calls. Everything here is synchronous and
/// must be called off the main actor.
public enum FileSystem {

    /// `lstat` the given path. Returns `nil` when the node does not exist or cannot be read.
    public static func stat(_ path: String) -> FileStat? {
        #if canImport(Darwin)
        var info = Darwin.stat()
        #else
        var info = Glibc.stat()
        #endif
        guard lstat(path, &info) == 0 else { return nil }
        let type: NodeType
        switch info.st_mode & S_IFMT {
        case S_IFREG: type = .file
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symlink
        default: type = .other
        }
        #if canImport(Darwin)
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        #else
        let seconds = TimeInterval(info.st_mtim.tv_sec) + TimeInterval(info.st_mtim.tv_nsec) / 1e9
        #endif
        return FileStat(
            device: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(truncatingIfNeeded: info.st_ino),
            type: type,
            size: Int64(info.st_size),
            allocatedSize: Int64(info.st_blocks) * 512,
            linkCount: UInt64(info.st_nlink),
            modificationDate: Date(timeIntervalSince1970: seconds)
        )
    }

    /// Lists the direct children of a directory without following symbolic links.
    /// Throws `NoriaError.accessDenied` / `.notFound` / `.io` on failure.
    public static func directoryEntries(_ path: String) throws(NoriaError) -> [DirectoryEntry] {
        guard let dir = opendir(path) else {
            throw NoriaError.fromErrno(errno, path: path)
        }
        defer { closedir(dir) }
        var result: [DirectoryEntry] = []
        let base = path.hasSuffix("/") ? path : path + "/"
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            result.append(DirectoryEntry(name: name, path: base + name))
        }
        return result
    }

    /// Resolves symbolic links and relative components. Returns `nil` if the path does not exist.
    public static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Canonicalizes as much of the path as exists. Useful for locations that may
    /// not exist yet (e.g. an empty DerivedData folder).
    public static func bestEffortCanonicalPath(_ path: String) -> String {
        if let resolved = canonicalPath(path) { return resolved }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        guard parent != path, !parent.isEmpty else { return path }
        return (bestEffortCanonicalPath(parent) as NSString).appendingPathComponent(url.lastPathComponent)
    }
}

extension String {
    /// `true` when `self` is `ancestor` or lies inside it. Both paths must be canonical.
    public func isSameOrDescendant(of ancestor: String) -> Bool {
        if self == ancestor { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return hasPrefix(prefix)
    }

    /// `true` when `self` lies strictly inside `ancestor`.
    public func isStrictDescendant(of ancestor: String) -> Bool {
        self != ancestor && isSameOrDescendant(of: ancestor)
    }
}
