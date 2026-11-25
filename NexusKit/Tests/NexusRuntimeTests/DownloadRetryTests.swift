import Foundation
import Testing
@testable import NexusRuntime

struct DownloadRetryTests {
    @Test func aConnectionThatStoppedOrTookTooLongGetsASecondTry() {
        #expect(DownloadRetry.isBrokenConnection(URLError(.networkConnectionLost)))
        #expect(DownloadRetry.isBrokenConnection(URLError(.timedOut)))
    }

    @Test func noInternetACancelOrAnotherErrorGetsNoSecondTry() {
        #expect(!DownloadRetry.isBrokenConnection(URLError(.notConnectedToInternet)))
        #expect(!DownloadRetry.isBrokenConnection(URLError(.cancelled)))
        #expect(!DownloadRetry.isBrokenConnection(CancellationError()))
        #expect(!DownloadRetry.isBrokenConnection(RuntimeError.httpStatus(404, URL(filePath: "/"))))
    }
}
