import Foundation
import NexusCore
import NexusDNS
import Testing
@testable import NexusEngine
@testable import NexusTLS

struct NexusVariantTests {
    @Test(arguments: ["nl.roodfruit.nexus.dev", "nl.roodfruit.nexus.dev.daemon", "nl.roodfruit.nexus.dev.helper", "nl.roodfruit.nexus.dev.cli"])
    func theProgramsOfADebugBuildAreNexusDev(bundleIdentifier: String) {
        #expect(NexusVariant.variant(for: bundleIdentifier) == .dev)
    }

    @Test(arguments: ["nl.roodfruit.nexus", "nl.roodfruit.nexus.daemon", "nl.roodfruit.nexus.helper", "nl.roodfruit.nexus.cli", "nl.roodfruit.nexus.sample", "nl.roodfruit.nexus.devtools", "com.apple.dt.xctest.tool"])
    func everyOtherProgramIsTheInstalledNexus(bundleIdentifier: String) {
        #expect(NexusVariant.variant(for: bundleIdentifier) == .release)
    }

    @Test func aProgramWithoutABundleIdIsTheInstalledNexus() {
        #expect(NexusVariant.variant(for: nil) == .release)
    }

    @Test func theReleaseKeepsTheNamesPortsAndDomainOfTheInstalledNexus() {
        let release = NexusVariant.release

        #expect(release.name == "Nexus")
        #expect(release.bundleIdentifier == "nl.roodfruit.nexus")
        #expect(release.tld == "test")
        #expect(release.firstAppPort == 19000)
        #expect(release.firstWorkspacePort == 20000)
        #expect(PortProfile.standard.defaultPort(443, variant: release) == 443)
        #expect(PortProfile.standard.defaultPort(3306, variant: release) == 3306)
        #expect(PortProfile.development.defaultPort(443, variant: release) == 8443)
        #expect(PortProfile.development.defaultPort(3306, variant: release) == 13306)
    }

    @Test func nexusDevHasItsOwnNamesPortsAndDomain() {
        let dev = NexusVariant.dev

        #expect(dev.name == "Nexus Dev")
        #expect(dev.bundleIdentifier == "nl.roodfruit.nexus.dev")
        #expect(dev.tld == "internal")
        #expect(PortProfile.standard.defaultPort(443, variant: dev) == 30443)
        #expect(PortProfile.standard.defaultPort(3306, variant: dev) == 33306)
        #expect(dev.port(10053) == 40053)
        #expect(dev.firstAppPort == 41000)
        #expect(dev.firstWorkspacePort == 42000)
        #expect(ResolverFile.marker(for: dev) == "# Written by Nexus Dev. Nexus Dev removes this file when you remove Nexus Dev.")
    }

    @Test func neitherVariantTakesTheResolverFileOfTheOtherForItsOwn() {
        let release = ResolverFile.marker(for: .release)
        let dev = ResolverFile.marker(for: .dev)

        #expect(!release.hasPrefix(dev))
        #expect(!dev.hasPrefix(release))
    }

    @Test func theNamesOfTheInstalledNexusStayTheSameAsIn020() {
        #expect(NexusVariant.current == .release)
        #expect(NexusIdentifiers.app == "nl.roodfruit.nexus")
        #expect(NexusIdentifiers.daemon == "nl.roodfruit.nexus.daemon")
        #expect(NexusIdentifiers.helper == "nl.roodfruit.nexus.helper")
        #expect(NexusIdentifiers.cli == "nl.roodfruit.nexus.cli")
        #expect(NexusPaths.standard.root.path(percentEncoded: false).hasSuffix("/Application Support/Nexus/"))
        #expect(EngineState().tld == "test")
        #expect(DNSServer.defaultPort == 10053)
        #expect(NexusEngine.firstAppPort == 19000)
        #expect(NexusEngine.firstWorkspacePort == 20000)
        #expect(SystemDNSFiles.resolverMarker == "# Written by Nexus. Nexus removes this file when you remove Nexus.")
        #expect(SystemDNSFiles.hostsBegin == "# Nexus begin")
        #expect(SystemDNSFiles.hostsEnd == "# Nexus end")
        #expect(ShellPathLine.marker == "# Added by Nexus (Settings > General > Add Nexus to PATH)")
        #expect(LoginKeychainStore.label == "Nexus Root CA")
        #expect(LoginKeychainStore.tag == Data("nl.roodfruit.nexus.root-ca".utf8))
    }
}
