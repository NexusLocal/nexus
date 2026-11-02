import Foundation
import NexusCore

// The files and SQL that a MySQL, MariaDB or PostgreSQL instance needs. my.cnf belongs to the user:
// Nexus writes it one time. The port, the address and the folders are on the command line, so
// a change in my.cnf cannot move an instance to the port of another one.
public enum DatabaseConfig {
    public static let initialMyCnf = """
        # This file belongs to you. Nexus writes it one time and does not change it after that.
        # Nexus sets the port, the address, the data folder and the socket on the command line.
        # The command line wins over the same settings in this file.
        [mysqld]

        """

    // Runs once, when mysqld --initialize-insecure has made the data folder. --initialize makes
    // only root@localhost, and a connection to 127.0.0.1 does not always match localhost.
    public static func mysqlInitSQL(account: DatabaseAccount) -> String {
        let user = sqlString(account.user)
        let password = sqlString(account.password)

        return ["localhost", "127.0.0.1", "::1"].map { host in
            let target = "\(user)@\(sqlString(host))"
            return """
                CREATE USER IF NOT EXISTS \(target);
                ALTER USER \(target) IDENTIFIED BY \(password);
                GRANT ALL PRIVILEGES ON *.* TO \(target) WITH GRANT OPTION;
                """
        }.joined(separator: "\n") + "\n"
    }

    // mariadb-install-db runs this file in bootstrap mode, where the grant tables are off and
    // ALTER USER fails. So the file changes the user table itself. It removes the anonymous users
    // and the root user for the host name of the Mac.
    public static func mariadbInitSQL(account: DatabaseAccount) -> String {
        """
        DELETE FROM mysql.global_priv WHERE User = '' OR (User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'));
        UPDATE mysql.global_priv SET User = \(sqlString(account.user)), priv = JSON_SET(priv, '$.plugin', 'mysql_native_password', '$.authentication_string', PASSWORD(\(sqlString(account.password)))) WHERE User = 'root';

        """
    }

    // An option file for the MySQL and MariaDB clients. A password in a file does not show in
    // the process list, as a password on the command line does. Without protocol = TCP, the
    // clients read the host localhost as their socket and ignore the port. The clients look
    // for their login plugins in a folder that was compiled in and does not exist. Without the
    // plugin folder of the package, MySQL 9 cannot log in with mysql_native_password (as in
    // MAMP PRO), and MariaDB cannot log in to MySQL 8 with caching_sha2_password.
    public static func clientOptions(host: String, port: Int, account: DatabaseAccount, pluginFolder: URL) -> String {
        """
        [client]
        protocol = TCP
        host = \(optionString(host))
        port = \(port)
        user = \(optionString(account.user))
        password = \(optionString(account.password))
        plugin-dir = \(optionString(pluginFolder.path(percentEncoded: false)))

        """
    }

    // MySQL does not know some table definitions of MariaDB: the uca1400 collations, the uuid and
    // inet types, a function as a default without brackets, and the Aria engine with its options.
    // A copy from MariaDB into MySQL changes them with sed. The lines with data stay as they are,
    // so text in a table that looks like a collation does not change.
    public static let mariadbToMySQLFilter = "/^INSERT INTO/!{ " + [
        #"s/([a-z0-9]+)_uca1400_[a-z0-9_]+/\1_unicode_ci/g;"#,
        #"s/uca1400_[a-z0-9_]+/utf8mb4_unicode_ci/g;"#,
        #"s/^(  `[^`]+` )uuid/\1char(36)/;"#,
        #"s/^(  `[^`]+` )inet[46]/\1varchar(45)/;"#,
        // MariaDB keeps JSON as text with a check. MySQL gives a check a name from the table, and
        // a long table name makes that name too long. The real JSON type needs no check. A table
        // with the collation utf8mb4_bin shows no character set on the column.
        #"s/^(  `[^`]+` )longtext( CHARACTER SET utf8mb4)?( COLLATE utf8mb4_bin)?(.*) CHECK \(json_valid\(`[^`]+`\)\)/\1json\4/;"#,
        // MySQL needs brackets around each default that is a function, except the time functions.
        // A text or JSON column needs them around a literal value too.
        #"s/ DEFAULT ([a-z_0-9]+\(([^()]|\(([^()]|\([^()]*\))*\))*\))/ DEFAULT (\1)/;"#,
        #"s/ DEFAULT \(((current_timestamp|now|localtime|localtimestamp)\([0-9]*\))\)/ DEFAULT \1/g;"#,
        #"/^  `[^`]+` (json|tinytext|text|mediumtext|longtext|tinyblob|blob|mediumblob|longblob)/s/ DEFAULT ('([^']|'')*')/ DEFAULT (\1)/;"#,
        // MariaDB gives the first check without a name in each table the name CONSTRAINT_1. MySQL
        // needs a name that is unique in the database, and it makes one for a check without a name.
        #"s/^  CONSTRAINT `CONSTRAINT_[0-9]+` CHECK /  CHECK /;"#,
        #"s/ENGINE=Aria/ENGINE=InnoDB/;"#,
        #"s/ (PAGE_CHECKSUM|TRANSACTIONAL)=[01]//g;"#,
        #"s/ ROW_FORMAT=PAGE//;"#,
        // The standard sql_mode of MariaDB has this mode. The dump sets the sql_mode of each
        // trigger and routine, and MySQL 8 refuses the mode.
        #"s/,NO_AUTO_CREATE_USER//;"#,
        #"s/NO_AUTO_CREATE_USER,?//;"#,
    ].joined(separator: " ") + " }"

    public static func mysqlCollation(_ collation: String) -> String {
        guard collation.contains("uca1400") else {
            return collation
        }

        guard let suffix = collation.range(of: "_uca1400") else {
            return "utf8mb4_unicode_ci"
        }

        return "\(collation[..<suffix.lowerBound])_unicode_ci"
    }

    public static func identifier(_ name: String, kind: DatabaseKind) -> String {
        kind.usesMySQLProtocol
            ? "`\(name.replacing("`", with: "``"))`"
            : "\"\(name.replacing("\"", with: "\"\""))\""
    }

    // A string literal for MySQL and MariaDB, which read a backslash as an escape.
    public static func sqlString(_ value: String) -> String {
        "'\(value.replacing("\\", with: "\\\\").replacing("'", with: "''"))'"
    }

    private static func optionString(_ value: String) -> String {
        "\"\(value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\""))\""
    }
}
