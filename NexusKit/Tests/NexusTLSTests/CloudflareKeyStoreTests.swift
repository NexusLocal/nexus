import Foundation
import Testing
@testable import NexusTLS

struct CloudflareKeyStoreTests {
    @Test func aKeyIsSavedReadReplacedAndRemovedInTheLoginKeychain() throws {
        let store = LoginCloudflareKeyStore(service: "nl.roodfruit.nexus.tests.cloudflare.\(UUID().uuidString)")
        defer {
            try? store.remove(.cert)
            try? store.remove(.tunnel)
        }

        try store.save(Data("first".utf8), as: .cert)
        let first = try store.read(.cert)
        try store.save(Data("second".utf8), as: .cert)
        let second = try store.read(.cert)
        let other = try store.read(.tunnel)
        try store.remove(.cert)

        #expect(first == Data("first".utf8))
        #expect(second == Data("second".utf8))
        #expect(other == nil)
        #expect(try store.read(.cert) == nil)
    }

    @Test func aRemovalOfAKeyThatIsNotThereThrowsNothing() throws {
        let store = LoginCloudflareKeyStore(service: "nl.roodfruit.nexus.tests.cloudflare.\(UUID().uuidString)")

        try store.remove(.tunnel)

        #expect(try store.read(.tunnel) == nil)
    }

    @Test func eachVariantHasItsOwnServiceAndLabel() {
        #expect(LoginCloudflareKeyStore.standardService == "nl.roodfruit.nexus.cloudflare")
        #expect(LoginCloudflareKeyStore.label == "Nexus Cloudflare key")
    }

    @Test func theStoreWithoutAKeychainKeepsNothing() {
        let store = NoCloudflareKeyStore()

        #expect(throws: TLSError.self) { try store.save(Data("key".utf8), as: .cert) }
        #expect(throws: TLSError.self) { try store.read(.cert) }
    }
}
