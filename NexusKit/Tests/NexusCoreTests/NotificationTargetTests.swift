import Foundation
import Testing
@testable import NexusCore

struct NotificationTargetTests {
    static let targets: [NotificationTarget] = [
        .workspace(site: "blog.test", name: "fix"),
        .service(id: "mysql-8.4"),
        .database(instance: "mysql-8.0", name: "shop"),
        .mail(id: "sample-3", tag: "blog.test"),
        .mail(id: "sample-5", tag: nil),
        .site(host: "shop.test"),
    ]

    @Test(arguments: targets)
    func eachTargetSurvivesTheTripThroughTheUserInfo(target: NotificationTarget) {
        #expect(NotificationTarget(userInfo: target.userInfo) == target)
    }

    @Test(arguments: targets)
    func theUserInfoIsAPropertyList(target: NotificationTarget) throws {
        _ = try PropertyListSerialization.data(fromPropertyList: target.userInfo, format: .binary, options: 0)
    }

    @Test
    func aMailWithoutATagHasNoTagKey() {
        let userInfo = NotificationTarget.mail(id: "sample-5", tag: nil).userInfo

        #expect(userInfo["tag"] == nil)
        #expect(userInfo == ["target": "mail", "mail": "sample-5"])
    }

    @Test
    func eachTargetHasTheKeysOfTheContract() {
        #expect(NotificationTarget.workspace(site: "blog.test", name: "fix").userInfo == ["target": "workspace", "site": "blog.test", "workspace": "fix"])
        #expect(NotificationTarget.service(id: "mysql-8.4").userInfo == ["target": "service", "service": "mysql-8.4"])
        #expect(NotificationTarget.database(instance: "mysql-8.0", name: "shop").userInfo == ["target": "database", "service": "mysql-8.0", "database": "shop"])
        #expect(NotificationTarget.mail(id: "sample-3", tag: "blog.test").userInfo == ["target": "mail", "mail": "sample-3", "tag": "blog.test"])
        #expect(NotificationTarget.site(host: "shop.test").userInfo == ["target": "site", "site": "shop.test"])
    }

    @Test
    func anEmptyUserInfoGivesNoTarget() {
        #expect(NotificationTarget(userInfo: [:]) == nil)
    }

    @Test
    func anUnknownTargetGivesNoTarget() {
        #expect(NotificationTarget(userInfo: ["target": "dumps", "site": "blog.test"]) == nil)
    }

    @Test(arguments: [
        ["target": "workspace", "workspace": "fix"],
        ["target": "workspace", "site": "blog.test"],
        ["target": "service"],
        ["target": "database", "database": "shop"],
        ["target": "database", "service": "mysql-8.0"],
        ["target": "mail", "tag": "blog.test"],
        ["target": "site"],
    ])
    func aMissingRequiredKeyGivesNoTarget(userInfo: [String: String]) {
        #expect(NotificationTarget(userInfo: userInfo) == nil)
    }

    @Test
    func aValueThatIsNotAStringGivesNoTarget() {
        #expect(NotificationTarget(userInfo: ["target": "workspace", "site": 5, "workspace": "fix"]) == nil)
        #expect(NotificationTarget(userInfo: ["target": "mail", "mail": "sample-3", "tag": 5]) == nil)
        #expect(NotificationTarget(userInfo: ["target": 5]) == nil)
    }
}
