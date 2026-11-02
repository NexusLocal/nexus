import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct DatabaseConfigTests {
    private func filtered(_ text: String) throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/sed")
        process.arguments = ["-E", DatabaseConfig.mariadbToMySQLFilter]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aTableDefinitionOfMariaDBGetsCollationsThatMySQLKnows() throws {
        let definition = """
            CREATE TABLE `doc` (
              `name` varchar(20) COLLATE utf8mb4_uca1400_as_cs DEFAULT NULL,
              `old` varchar(20) CHARACTER SET utf8mb3 COLLATE utf8mb3_uca1400_ai_ci DEFAULT NULL,
              `tag` uuid DEFAULT NULL
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=uca1400_ai_ci;

            """

        let result = try filtered(definition)

        #expect(result.contains("`name` varchar(20) COLLATE utf8mb4_unicode_ci DEFAULT"))
        #expect(result.contains("COLLATE utf8mb3_unicode_ci DEFAULT"))
        #expect(result.contains("`tag` char(36) DEFAULT"))
        #expect(result.contains("COLLATE=utf8mb4_unicode_ci;"))
        #expect(!result.contains("uca1400"))
    }

    @Test func aDefaultOfMariaDBGetsTheBracketsOfMySQL() throws {
        let result = try filtered("  `id` char(36) NOT NULL DEFAULT uuid(),\n")

        #expect(result == "  `id` char(36) NOT NULL DEFAULT (uuid()),\n")
    }

    @Test func eachFunctionAsADefaultGetsBrackets() throws {
        #expect(try filtered("  `a` json NOT NULL DEFAULT json_array(),\n") == "  `a` json NOT NULL DEFAULT (json_array()),\n")
        #expect(try filtered("  `a` json DEFAULT json_object('a',concat('b','c')),\n") == "  `a` json DEFAULT (json_object('a',concat('b','c'))),\n")
    }

    @Test func aJSONColumnOfMariaDBWithAFunctionAsDefaultKeepsItsDefault() throws {
        let definition = "  `a` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL DEFAULT json_array() CHECK (json_valid(`a`)),\n"

        #expect(try filtered(definition) == "  `a` json NOT NULL DEFAULT (json_array()),\n")
    }

    @Test func aTextValueAsDefaultGetsBracketsOnlyOnTextColumns() throws {
        #expect(try filtered("  `a` text NOT NULL DEFAULT 'it''s',\n") == "  `a` text NOT NULL DEFAULT ('it''s'),\n")
        #expect(try filtered("  `a` varchar(9) NOT NULL DEFAULT 'b',\n") == "  `a` varchar(9) NOT NULL DEFAULT 'b',\n")
    }

    @Test func aTimestampDefaultStaysAsItIs() throws {
        let definition = "  `at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),\n"

        #expect(try filtered(definition) == definition)
    }

    @Test func theAriaEngineBecomesInnoDB() throws {
        let result = try filtered(") ENGINE=Aria DEFAULT CHARSET=utf8mb4 PAGE_CHECKSUM=1 TRANSACTIONAL=1 ROW_FORMAT=PAGE;\n")

        #expect(result == ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n")
    }

    @Test func aJSONColumnOfMariaDBBecomesTheJSONTypeOfMySQL() throws {
        let definition = "  `data` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`data`)),\n"

        #expect(try filtered(definition) == "  `data` json DEFAULT NULL,\n")
    }

    @Test func anInetColumnBecomesText() throws {
        #expect(try filtered("  `ip` inet6 DEFAULT NULL,\n") == "  `ip` varchar(45) DEFAULT NULL,\n")
    }

    @Test func theDataOfATableStaysAsItIs() throws {
        let data = "INSERT INTO `doc` VALUES (1,'utf8mb4_uca1400_ai_ci uuid');\n"

        #expect(try filtered(data) == data)
    }

    @Test func aColumnWithUuidInItsNameKeepsItsType() throws {
        let definition = "  `uuid` varchar(36) DEFAULT NULL,\n"

        #expect(try filtered(definition) == definition)
    }

    @Test func aCollationThatMySQLDoesNotKnowChanges() {
        #expect(DatabaseConfig.mysqlCollation("utf8mb4_uca1400_ai_ci") == "utf8mb4_unicode_ci")
        #expect(DatabaseConfig.mysqlCollation("uca1400_ai_ci") == "utf8mb4_unicode_ci")
        #expect(DatabaseConfig.mysqlCollation("utf8mb3_uca1400_ai_ci") == "utf8mb3_unicode_ci")
        #expect(DatabaseConfig.mysqlCollation("utf16_uca1400_ai_ci") == "utf16_unicode_ci")
        #expect(DatabaseConfig.mysqlCollation("utf8mb4_0900_ai_ci") == "utf8mb4_0900_ai_ci")
    }

    @Test func aCollationOfAnotherCharacterSetKeepsItsCharacterSet() throws {
        let definition = "  `a` varchar(9) CHARACTER SET utf16 COLLATE utf16_uca1400_ai_ci DEFAULT NULL,\n"

        #expect(try filtered(definition) == "  `a` varchar(9) CHARACTER SET utf16 COLLATE utf16_unicode_ci DEFAULT NULL,\n")
    }

    @Test func aJSONColumnInATableWithTheBinaryCollationBecomesTheJSONTypeOfMySQL() throws {
        #expect(try filtered("  `a` longtext DEFAULT NULL CHECK (json_valid(`a`)),\n") == "  `a` json DEFAULT NULL,\n")
        #expect(try filtered("  `a` longtext DEFAULT '[]' CHECK (json_valid(`a`)),\n") == "  `a` json DEFAULT ('[]'),\n")
    }

    @Test func aLongTextColumnWithoutACheckStaysText() throws {
        let definition = "  `a` longtext DEFAULT NULL,\n"

        #expect(try filtered(definition) == definition)
    }

    @Test func aFunctionWithThreeLevelsAsADefaultGetsBrackets() throws {
        let definition = "  `a` varchar(99) DEFAULT concat('a',ucase(concat('b','c'))),\n"

        #expect(try filtered(definition) == "  `a` varchar(99) DEFAULT (concat('a',ucase(concat('b','c')))),\n")
    }

    @Test func aCheckWithTheNameOfMariaDBLosesItsName() throws {
        #expect(try filtered("  CONSTRAINT `CONSTRAINT_1` CHECK (`id` > 0)\n") == "  CHECK (`id` > 0)\n")
    }

    @Test func aCheckWithANameOfTheUserKeepsItsName() throws {
        let definition = "  CONSTRAINT `positive_id` CHECK (`id` > 0)\n"

        #expect(try filtered(definition) == definition)
    }

    @Test func theSQLModeOfATriggerLosesAModeThatMySQLDoesNotKnow() throws {
        let line = "/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;\n"
        let first = "/*!50003 SET sql_mode              = 'NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;\n"
        let only = "/*!50003 SET sql_mode              = 'NO_AUTO_CREATE_USER' */ ;\n"

        #expect(try filtered(line) == "/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;\n")
        #expect(try filtered(first) == "/*!50003 SET sql_mode              = 'NO_ENGINE_SUBSTITUTION' */ ;\n")
        #expect(try filtered(only) == "/*!50003 SET sql_mode              = '' */ ;\n")
    }

    @Test func mySQLGetsRootWithThePasswordRootOnEveryLocalAddress() {
        let sql = DatabaseConfig.mysqlInitSQL(account: .standard)

        for host in ["localhost", "127.0.0.1", "::1"] {
            #expect(sql.contains("CREATE USER IF NOT EXISTS 'root'@'\(host)';"))
            #expect(sql.contains("ALTER USER 'root'@'\(host)' IDENTIFIED BY 'root';"))
            #expect(sql.contains("GRANT ALL PRIVILEGES ON *.* TO 'root'@'\(host)' WITH GRANT OPTION;"))
        }
    }

    @Test func mariaDBChangesTheUserTableAndRemovesTheAnonymousUsers() {
        let sql = DatabaseConfig.mariadbInitSQL(account: .standard)

        #expect(sql.contains("DELETE FROM mysql.global_priv WHERE User = ''"))
        #expect(sql.contains("PASSWORD('root')"))
        #expect(!sql.contains("ALTER USER"))
    }

    @Test func aPasswordWithQuotesStaysOneValue() {
        let account = DatabaseAccount(user: "root", password: #"it's "secret"\"#)

        let options = DatabaseConfig.clientOptions(host: "127.0.0.1", port: 3306, account: account, pluginFolder: URL(filePath: "/Application Support/mysql/lib/plugin/"))
        let sql = DatabaseConfig.mysqlInitSQL(account: account)

        #expect(options.contains(#"password = "it's \"secret\"\\""#))
        #expect(options.contains(#"plugin-dir = "/Application Support/mysql/lib/plugin/""#))
        #expect(options.contains("protocol = TCP"))
        #expect(sql.contains(#"IDENTIFIED BY 'it''s "secret"\\';"#))
    }

    @Test func identifiersGetTheQuotesOfTheirServer() {
        #expect(DatabaseConfig.identifier("shop-ticket-1", kind: .mysql) == "`shop-ticket-1`")
        #expect(DatabaseConfig.identifier("shop-ticket-1", kind: .postgresql) == "\"shop-ticket-1\"")
    }

    @Test func myCnfHasAServerSection() {
        #expect(DatabaseConfig.initialMyCnf.contains("[mysqld]"))
    }
}
