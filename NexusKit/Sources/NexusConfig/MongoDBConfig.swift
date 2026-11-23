import Foundation

// The files and the arguments of a MongoDB instance. mongod.conf belongs to the user: Nexus writes it
// one time. The port, the address, the data folder and the replica set are on the command line, so a
// change in mongod.conf cannot move an instance to the port of another one.
public enum MongoDBConfig {
    public static let initialConf = """
        # This file belongs to you. Nexus writes it one time and does not change it after that.
        # Nexus sets the port, the address, the data folder and the replica set on the command line.
        # The command line wins over the same settings in this file.
        # Without cacheSizeGB, MongoDB can use half of the memory of the Mac.
        storage:
          wiredTiger:
            engineConfig:
              cacheSizeGB: 1

        """

    // The data folder holds this file when the account has a password. A replica set with a login
    // needs it. A clone of the folder gets the same file.
    public static let keyFileName = "nexus.key"

    // The cache of the server of a workspace. A Mac with 8 GB of memory must also run several
    // workspaces.
    public static let workspaceCacheSizeGB = "0.25"

    // Without --nounixsocket, mongod makes a socket file in /tmp. With a socket folder, mongod makes
    // mongodb-<port>.sock in that folder, only for its owner. A path of more than 104 bytes stops
    // mongod. Without the setting for the diagnostic data, mongod writes statistics into its data
    // folder all the time.
    public static func serverArguments(config: URL?, data: URL, port: Int, replicaSet: String?, keyFile: URL?, socketFolder: URL? = nil) -> [String] {
        var arguments = config.map { ["--config", $0.path(percentEncoded: false)] } ?? []

        arguments += [
            "--dbpath", data.path(percentEncoded: false),
            "--port", String(port),
            "--bind_ip", "127.0.0.1",
        ]

        arguments += socketFolder.map { ["--unixSocketPrefix", $0.path(percentEncoded: false)] } ?? ["--nounixsocket"]
        arguments += ["--setParameter", "diagnosticDataCollectionEnabled=false"]

        if let replicaSet {
            arguments += ["--replSet", replicaSet]
        }

        if let keyFile {
            arguments += ["--keyFile", keyFile.path(percentEncoded: false), "--auth"]
        }

        return arguments
    }

    public static func keyFile(in data: URL) -> URL {
        data.appending(path: keyFileName, directoryHint: .notDirectory)
    }

    // mongod accepts 6 to 1,024 characters of base64.
    public static func newKey() -> String {
        Data((0..<756).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }
}
