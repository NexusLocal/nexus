import NexusCore
import Testing
@testable import NexusLaravel

struct ProbeMarkersTests {
    private let markers = ProbeMarkers(keys: ["APP_URL", "DB_DATABASE", "REDIS_DB"])

    private func text(_ key: String) -> String {
        markers.textEnvironment[key]!
    }

    private func number(_ key: String) -> Int {
        Int(markers.numericEnvironment[key]!)!
    }

    @Test func everyKeyHasItsOwnMarkerOfLowercaseLettersAndDigits() {
        #expect(Set(markers.textEnvironment.values).count == 3)
        #expect(Set(markers.numericEnvironment.values).count == 3)
        #expect(markers.textEnvironment.values.allSatisfy { $0 == $0.lowercased() && $0.allSatisfy { $0.isLetter || $0.isNumber } })
    }

    @Test func aWorkspaceChangesOnlyTheDatabaseAndRedisKeys() {
        let environment = markers.workspaceEnvironment(databaseKeys: ["DB_DATABASE"], redisKeys: ["REDIS_DB"])

        #expect(environment == ["DB_DATABASE": text("DB_DATABASE"), "REDIS_DB": String(number("REDIS_DB"))])
    }

    @Test func aKeyOfADatabaseAndOfARedisIndexGetsTheTextMarker() {
        let environment = markers.workspaceEnvironment(databaseKeys: ["DB_DATABASE"], redisKeys: ["DB_DATABASE"])

        #expect(environment == ["DB_DATABASE": text("DB_DATABASE")])
    }

    @Test func aMarkerAloneFeedsTheSettingExactly() {
        let setting = markers.setting(value: .text("shop"), textPass: .text(text("DB_DATABASE")), numericPass: nil)

        #expect(setting == ConfigSetting(value: .text("shop"), keys: ["DB_DATABASE"], exact: true))
    }

    @Test func aMarkerInsideALongerValueIsNotExact() {
        let setting = markers.setting(value: .text("shop:"), textPass: .text("\(text("DB_DATABASE")):"), numericPass: nil)

        #expect(setting == ConfigSetting(value: .text("shop:"), keys: ["DB_DATABASE"], exact: false))
    }

    @Test func twoMarkersInOneValueNameBothKeys() {
        let setting = markers.setting(value: .text("x"), textPass: .text("https://\(text("APP_URL"))/\(text("DB_DATABASE"))"), numericPass: nil)

        #expect(setting.keys == ["APP_URL", "DB_DATABASE"])
        #expect(!setting.exact)
    }

    @Test func aMarkerThatTheApplicationChangedToUppercaseStillCounts() {
        let setting = markers.setting(value: .text("SHOP"), textPass: .text(text("DB_DATABASE").uppercased()), numericPass: nil)

        #expect(setting.keys == ["DB_DATABASE"])
        #expect(!setting.exact)
    }

    @Test func aCastToIntInTheTextPassNamesTheKey() {
        let setting = markers.setting(value: .number(1), textPass: .number(Double(number("REDIS_DB"))), numericPass: nil)

        #expect(setting == ConfigSetting(value: .number(1), keys: ["REDIS_DB"], exact: true))
    }

    @Test func theNumericPassFindsASettingThatLostTheTextMarker() {
        let setting = markers.setting(value: .number(1), textPass: .number(0), numericPass: .number(Double(number("REDIS_DB"))))

        #expect(setting == ConfigSetting(value: .number(1), keys: ["REDIS_DB"], exact: true))
    }

    @Test func aNumberAsTextInTheNumericPassCounts() {
        let setting = markers.setting(value: .text("1"), textPass: .number(0), numericPass: .text(String(number("REDIS_DB"))))

        #expect(setting.keys == ["REDIS_DB"])
    }

    @Test func aValueWithoutAMarkerIsFixed() {
        let setting = markers.setting(value: .number(3), textPass: .number(3), numericPass: .number(3))

        #expect(setting.isFixed)
    }

    @Test func aFixedValueThatIsTheNumberOfAKeyNamesNoKey() {
        let fixed = ConfigValue.number(Double(number("REDIS_DB")))

        #expect(markers.setting(value: fixed, textPass: fixed, numericPass: fixed).isFixed)
    }

    @Test func aNumberThatTheApplicationAddedToNamesNoKey() {
        let setting = markers.setting(value: .number(2), textPass: .number(Double(number("DB_DATABASE") + 1)), numericPass: .number(Double(number("DB_DATABASE") + 1)))

        #expect(setting.isFixed)
    }

    @Test(arguments: [1, 2, 10, 100, 1000, 10000])
    func aRoundNumberThatTheApplicationAddedNamesNoOtherKey(added: Int) {
        let keys = (0..<500).map { "KEY_\($0)" }
        let markers = ProbeMarkers(keys: keys)
        let numbers = keys.map { Int(markers.numericEnvironment[$0]!)! }

        for number in numbers {
            let sum = ConfigValue.number(Double(number + added))

            #expect(markers.setting(value: .number(2), textPass: sum, numericPass: sum).isFixed)
        }
    }
}
