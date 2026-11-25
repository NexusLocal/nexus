import Foundation

// A connection that stopped or took too long often works at the next try, for example after a
// change of the network. On 2026-11-25 an automatic update of PHP failed once with "The connection
// to release-assets.githubusercontent.com stopped", and the same file downloaded at once later. A
// Mac without internet gets no second try, because the next try fails the same way.
public enum DownloadRetry {
    public static func isBrokenConnection(_ error: any Error) -> Bool {
        guard let error = error as? URLError else {
            return false
        }

        return error.code == .networkConnectionLost || error.code == .timedOut
    }
}
