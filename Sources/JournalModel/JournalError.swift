import Foundation

/// A problem the model can read and act on: a missing permission, something not found, a write
/// refused for a reason, an entry changed since it was read, a Journal this app does not know.
package enum JournalError: Error, CustomStringConvertible {
    case noAccess(String)
    case notFound(String)
    case refused(String)
    case conflict(String)
    case unsupported(String)
    case failed(String)

    package var description: String {
        switch self {
        case .noAccess(let m): m
        case .notFound(let what): "Not found: \(what)."
        case .refused(let m), .conflict(let m), .unsupported(let m), .failed(let m): m
        }
    }
}
