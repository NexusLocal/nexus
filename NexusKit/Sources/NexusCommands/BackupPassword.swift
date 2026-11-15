import ArgumentParser
import Darwin
import Foundation
import NexusCore

// The password of a .wpress backup for nexus import. The terminal does not show it.
enum BackupPassword {
    static let prompt = "Password of the backup: "
    static let noTerminal = "This backup has a password. Run the command in a terminal, or give the password with --password-stdin."

    static func ask(signature: String, fromInput: Bool) throws -> String {
        if fromInput {
            let password = Self.fromInput(FileHandle.standardInput.readDataToEndOfFile())

            guard WpressCipher.isPassword(password, of: signature) else {
                try fail(BackupText.wrongPassword)
            }

            return password
        }

        var buffer = [CChar](repeating: 0, count: 8192)

        for _ in 1...3 {
            let answer = readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY)
            let password = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            memset_s(&buffer, buffer.count, 0, buffer.count)

            guard answer != nil else {
                try fail(noTerminal)
            }

            if WpressCipher.isPassword(password, of: signature) {
                return password
            }

            FileHandle.standardError.write(Data("\(BackupText.wrongPassword)\n".utf8))
        }

        throw ExitCode.failure
    }

    private static func fail(_ message: String) throws -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        throw ExitCode.failure
    }

    // echo adds a line end. Only one line end goes. So a password can end with a space.
    static func fromInput(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)

        if text.last?.isNewline == true {
            text.removeLast()
        }

        return text
    }
}
