import Foundation

// The text of an error as a plain sentence (owner, 2026-11-09). An error of Nexus has a sentence
// already. An error of macOS, such as a file that exists already, prints as "Error Domain=
// NSCocoaErrorDomain Code=516 ..." with its own description. The app and the nexus command show
// this text, so these errors get a sentence here. A log keeps the full text of the error.
public enum ErrorText {
    public static func plain(_ error: any Error) -> String {
        if error is CancellationError {
            return "The work was stopped."
        }

        if let decoding = error as? DecodingError {
            return "Nexus cannot read the data. \(decodingReason(decoding))"
        }

        let system = error as NSError

        switch system.domain {
        case NSCocoaErrorDomain:
            return fileText(system)
        case NSURLErrorDomain:
            return connectionText(system)
        case NSPOSIXErrorDomain:
            return posixText(Int32(system.code), path: path(of: system))
        default:
            return String(describing: error)
        }
    }

    private static func path(of error: NSError) -> String? {
        (error.userInfo[NSFilePathErrorKey] as? String) ?? (error.userInfo[NSURLErrorKey] as? URL)?.path(percentEncoded: false)
    }

    private static func fileText(_ error: NSError) -> String {
        let item = path(of: error) ?? "The file"
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError

        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return "\(item) does not exist."
        case NSFileWriteFileExistsError:
            return "\(item) exists already."
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return "Nexus has no permission to use \(item)."
        case NSFileWriteOutOfSpaceError:
            return "The disk is full, so Nexus cannot write \(item)."
        case NSFileWriteVolumeReadOnlyError:
            return "\(item) is on a disk that is read-only."
        case NSFileReadCorruptFileError, NSFileReadInapplicableStringEncodingError, NSFileReadUnknownStringEncodingError:
            return "Nexus cannot read \(item). It has a format that Nexus does not know."
        default:
            if let underlying, underlying.domain == NSPOSIXErrorDomain {
                return posixText(Int32(underlying.code), path: path(of: error))
            }

            return sentence(error.localizedDescription)
        }
    }

    private static func connectionText(_ error: NSError) -> String {
        let server = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host() ?? "the server"

        switch error.code {
        case NSURLErrorTimedOut:
            return "The connection to \(server) took too long."
        case NSURLErrorNotConnectedToInternet:
            return "This Mac has no internet connection."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Nexus cannot find the server \(server)."
        case NSURLErrorCannotConnectToHost:
            return "Nexus cannot connect to \(server)."
        case NSURLErrorNetworkConnectionLost:
            return "The connection to \(server) stopped."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot:
            return "The secure connection to \(server) failed."
        default:
            return sentence(error.localizedDescription)
        }
    }

    private static func posixText(_ code: Int32, path: String?) -> String {
        let item = path ?? "A file or a folder"

        switch code {
        case ENOENT:
            return "\(item) does not exist."
        case EEXIST:
            return "\(item) exists already."
        case EACCES, EPERM:
            return "Nexus has no permission to use \(path ?? "a file or a folder")."
        case ENOSPC:
            return "The disk is full."
        case ECONNREFUSED:
            return "The server refused the connection."
        case EADDRINUSE:
            return "Another program uses the port already."
        default:
            return sentence(String(cString: strerror(code)))
        }
    }

    private static func decodingReason(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            return sentence(context.debugDescription)
        @unknown default:
            return ""
        }
    }

    // macOS puts curly quotes around names. The other texts of Nexus have none.
    private static func sentence(_ text: String) -> String {
        let plain = text
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespaces)

        return plain.hasSuffix(".") ? plain : "\(plain)."
    }
}
