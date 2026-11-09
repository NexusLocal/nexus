import Foundation
import Testing
@testable import NexusCore

struct ErrorTextTests {
    private struct OwnError: Error, CustomStringConvertible {
        let description = "Nexus has no site shop.test."
    }

    @Test func aFileThatExistsGetsASentence() {
        let error = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: "/w/shop/.env"])

        #expect(ErrorText.plain(error) == "/w/shop/.env exists already.")
    }

    @Test func aMissingFileWithoutAPathGetsASentence() {
        #expect(ErrorText.plain(CocoaError(.fileReadNoSuchFile)) == "The file does not exist.")
    }

    @Test func aTimeoutNamesTheServer() {
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://github.com/NexusLocal")!])

        #expect(ErrorText.plain(error) == "The connection to github.com took too long.")
    }

    @Test func aSystemErrorGetsASentence() {
        #expect(ErrorText.plain(POSIXError(.ENOSPC)) == "The disk is full.")
        #expect(ErrorText.plain(POSIXError(.EADDRINUSE)) == "Another program uses the port already.")
    }

    @Test func anErrorOfNexusKeepsItsText() {
        #expect(ErrorText.plain(OwnError()) == "Nexus has no site shop.test.")
    }

    @Test func noTextHasTheDomainOfTheError() {
        let errors: [any Error] = [
            CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: "/w/a"]),
            URLError(.badServerResponse),
            POSIXError(.EBUSY),
            DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "The data is not JSON")),
        ]

        for error in errors {
            let text = ErrorText.plain(error)

            #expect(!text.contains("Domain="))
            #expect(!text.contains("Code="))
            #expect(text.hasSuffix("."))
        }
    }
}
