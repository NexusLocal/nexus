import NexusCore
import Testing

struct OtherWebServersTests {
    @Test func anAppIsFoundByItsBundleOrByItsFiles() {
        let installed = OtherWebServers.installed(
            home: "/Users/x",
            hasApp: { $0 == "com.getflywheel.lightning.local" },
            fileExists: { $0 == "/Users/x/.config/composer/vendor/bin/valet" || $0 == "/Applications/XAMPP" }
        )

        #expect(installed == ["Local", "Valet", "XAMPP"])
    }

    @Test func onlyAnAppThatRestartsItsServersIsAManager() {
        #expect(OtherWebServers.managerBundleIdentifier(of: "Herd") == "de.beyondco.herd")
        #expect(OtherWebServers.managerBundleIdentifier(of: "MAMP PRO") == "de.appsolute.mamppro")
        #expect(OtherWebServers.managerBundleIdentifier(of: "Local") == nil)
        #expect(OtherWebServers.managerBundleIdentifier(of: "Valet") == nil)
        #expect(OtherWebServers.managerBundleIdentifier(of: "Homebrew") == nil)
    }

    @Test func noAppGivesNoNames() {
        let installed = OtherWebServers.installed(home: "/Users/x", hasApp: { _ in false }, fileExists: { _ in false })

        #expect(installed.isEmpty)
    }

    @Test func theNoticeShowsOnlyWhileNginxHasPort80Or443() {
        #expect(OtherWebServers.noticeNames(installed: ["Local"], hidden: [], nginxPorts: [80, 443]) == ["Local"])
        #expect(OtherWebServers.noticeNames(installed: ["Local"], hidden: [], nginxPorts: [8080, 443]) == ["Local"])
        #expect(OtherWebServers.noticeNames(installed: ["Local"], hidden: [], nginxPorts: [8080, 8443]).isEmpty)
        #expect(OtherWebServers.noticeNames(installed: ["Local"], hidden: [], nginxPorts: []).isEmpty)
    }

    @Test func aHiddenNoticeComesBackOnlyForANewApp() {
        #expect(OtherWebServers.noticeNames(installed: ["Local"], hidden: ["Local"], nginxPorts: [80, 443]).isEmpty)
        #expect(OtherWebServers.noticeNames(installed: ["Local", "Herd"], hidden: ["Local"], nginxPorts: [80, 443]) == ["Herd"])
    }

    @Test func theTextsNameOneAppOrMoreApps() {
        #expect(OtherWebServers.noticeTitle(["Local"]) == "Local also needs ports 80 and 443")
        #expect(OtherWebServers.noticeTitle(["Local", "Herd"]) == "Local and Herd also need ports 80 and 443")
        #expect(OtherWebServers.noticeMessage(["Local"]).contains("the sites of Local do not open"))
        #expect(OtherWebServers.noticeMessage(["Local", "Herd"]).contains("the sites of these apps do not open"))
    }

    @Test func theButtonAndTheResultNameTheNewPorts() {
        #expect(OtherWebServers.moveButtonTitle == "Use 8080 and 8443")
        #expect(OtherWebServers.movedTitle == "Nexus uses ports 8080 and 8443 now")
    }

    @Test func theMovedMessageGivesTheNewURL() {
        #expect(OtherWebServers.movedMessage(["Local"], exampleHost: "shop.test") == "Your sites open at https://shop.test:8443. Local can use ports 80 and 443 again. Change APP_URL in the .env file of each site yourself.")
        #expect(OtherWebServers.movedMessage(["Local", "Herd"], exampleHost: nil).hasPrefix("Your sites open with port 8443 in the URL. Local and Herd can use"))
    }
}
