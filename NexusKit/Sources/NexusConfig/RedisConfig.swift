import Foundation

// redis.conf belongs to the user, as my.cnf does. Nexus writes it one time. The port, the address,
// the data folder and the number of databases are on the command line after the file, so they win.
// A change in redis.conf cannot move Redis to another port or remove the databases of the
// workspaces.
public enum RedisConfig {
    public static let initial = """
        # This file belongs to you. Nexus writes it one time and does not change it after that.
        # Nexus sets the port, the address, the data folder and the number of databases on the
        # command line. The command line wins over the same settings in this file.
        # Restart Redis after a change.

        """
}
