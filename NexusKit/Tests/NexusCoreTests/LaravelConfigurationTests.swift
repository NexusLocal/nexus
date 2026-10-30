import Foundation
import NexusCore
import Testing

struct LaravelConfigurationTests {
    @Test func aConfigValueKeepsItsTypeThroughJSON() throws {
        let values: [ConfigValue] = [.text("shop"), .number(6379), .flag(true), .null]

        let decoded = try JSONDecoder().decode([ConfigValue].self, from: JSONEncoder().encode(values))

        #expect(decoded == values)
    }

    @Test func aWholeNumberPrintsWithoutADecimalPart() {
        #expect(ConfigValue.number(6379).description == "6379")
        #expect(ConfigValue.number(1.5).description == "1.5")
    }

    @Test func aWholeNumberAboveTheLimitOfIntStillPrints() {
        #expect(ConfigValue.number(1e19).description == "1e+19")
    }

    @Test func aSettingWithoutKeysIsFixed() {
        #expect(ConfigSetting(value: .text("main")).isFixed)
        #expect(!ConfigSetting(value: .text("main"), keys: ["DB_CONNECTION"], exact: true).isFixed)
    }
}
