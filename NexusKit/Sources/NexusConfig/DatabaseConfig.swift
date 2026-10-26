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
