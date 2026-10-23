import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors surfaced by NoriaCore. Messages are technical (English); the UI maps
/// cases to localized strings.
public enum NoriaError: Error, Sendable, Equatable, CustomStringConvertible {
    case accessDenied(path: String)
    case notFound(path: String)
    case io(path: String, code: Int32)
    case cancelled
    /// The item was blocked by the safety policy.
    case blocked(path: String, reason: SafetyViolation)
    /// The item changed on disk after it was scanned.
    case changedSinceScan(path: String)
    case removalFailed(path: String, message: String)
    case unsupported(String)

    static func fromErrno(_ code: Int32, path: String) -> NoriaError {
        switch code {
        case EACCES, EPERM: return .accessDenied(path: path)
        case ENOENT, ENOTDIR: return .notFound(path: path)
        default: return .io(path: path, code: code)
        }
    }

    public var description: String {
        switch self {
        case .accessDenied(let path): return "Access denied: \(path)"
        case .notFound(let path): return "Not found: \(path)"
        case .io(let path, let code): return "I/O error \(code) (\(String(cString: strerror(code)))): \(path)"
        case .cancelled: return "Cancelled"
        case .blocked(let path, let reason): return "Blocked by safety policy (\(reason.rawValue)): \(path)"
        case .changedSinceScan(let path): return "Changed since scan: \(path)"
        case .removalFailed(let path, let message): return "Removal failed: \(path) — \(message)"
        case .unsupported(let what): return "Unsupported: \(what)"
        }
    }
}
