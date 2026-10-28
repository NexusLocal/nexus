import Foundation
import NexusCore
import Testing

struct EnvFileTests {
    @Test func theValuesKeepTheirTextWithoutQuotesAndComments() {
        let text = """
            # A comment
            APP_NAME="My Shop"
            export DB_HOST=127.0.0.1
            DB_PORT = 3306 # the port of MySQL
            DB_DATABASE='shop#1'
            DB_PASSWORD=
            APP_URL=https://shop.test#top
            NOT A KEY
            """

        let values = EnvFile.values(in: text)

        #expect(values == [
            "APP_NAME": "My Shop",
            "DB_HOST": "127.0.0.1",
            "DB_PORT": "3306",
            "DB_DATABASE": "shop#1",
            "DB_PASSWORD": "",
            "APP_URL": "https://shop.test#top",
        ])
    }

    @Test func aMissingFileHasNoValues() {
        #expect(EnvFile.values(of: URL(filePath: "/nonexistent/.env")).isEmpty)
    }
}
