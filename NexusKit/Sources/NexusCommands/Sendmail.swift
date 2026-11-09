import ArgumentParser
import Foundation
import NexusCore
import NexusMail

// nexus sendmail (Phase 3, 3b). PHP runs it for each mail() through sendmail_path. NexusCLI.main
// runs it before the parser, because the flags of a sendmail, such as -oi, do not fit the parser.
// This command puts it in nexus --help.
struct Sendmail: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Gives the mail on the input to the mail service of Nexus. PHP runs it for mail().",
        discussion: "When nexusd does not answer, the mail waits in the outbox of Nexus. The mail service gets it at its next start."
    )

    @Argument(parsing: .captureForPassthrough, help: "The arguments of a sendmail, for example: -S 127.0.0.1:1025 -t -i") var arguments: [String] = []

    func run() throws {
        throw ExitCode(SendmailRun.run(arguments))
    }
}

enum SendmailRun {
    // PHP counts each exit code but 0 and 75 as a failure of mail(). These are the codes of
    // sysexits.h.
    static let usageError: Int32 = 64
    static let refused: Int32 = 69
    static let notKept: Int32 = 74
    // The receiver waits up to 30 seconds for each answer of Mailpit before it keeps the mail in
    // the outbox. A shorter wait here would keep a second copy of the same mail.
    static let receiverTimeout: TimeInterval = 120

    // The user name of the login is the folder of the program, as PHP-FPM changes to the folder of
    // the script. nexusd turns it into the host of the site. When the receiver does not answer, the
    // mail goes into the outbox with the limits of the settings, and mail() returns true.
    static func run(
        _ arguments: [String],
        input: FileHandle = .standardInput,
        folder: String = FileManager.default.currentDirectoryPath,
        outbox: MailOutbox = MailOutbox(folder: NexusPaths.standard.mailOutbox),
        report: (String) -> Void = { FileHandle.standardError.write(Data("nexus sendmail: \($0)\n".utf8)) }
    ) -> Int32 {
        if arguments == ["--help"] {
            print(SendmailRequest.usage)
            return 0
        }

        let message: MailMessage
        let port: Int

        do {
            let request = try SendmailRequest.parse(arguments)

            guard let requestedPort = request.port else {
                throw SendmailError.usage("Give the port of the mail service with -S. \(SendmailRequest.usage)")
            }

            port = requestedPort
            message = try request.message(from: input.readDataToEndOfFile(), user: folder)
        } catch {
            report(ErrorText.plain(error))
            return usageError
        }

        do {
            try SMTPClient(port: port, timeout: receiverTimeout).send(message)
            return 0
        } catch SMTPClientError.refused(let answer) {
            report("The mail service refused the mail: \(answer)")
            return refused
        } catch {
            return keep(message, in: outbox, report: report)
        }
    }

    private static func keep(_ message: MailMessage, in outbox: MailOutbox, report: (String) -> Void) -> Int32 {
        do {
            switch try outbox.store(message, limits: outbox.storedLimits()) {
            case .stored:
                return 0
            case .full:
                report("The outbox of Nexus is full. The settings refuse new mail.")
                return refused
            }
        } catch {
            report("Nexus could not keep the mail: \(ErrorText.plain(error))")
            return notKept
        }
    }
}
