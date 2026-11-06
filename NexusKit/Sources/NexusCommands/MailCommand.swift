import ArgumentParser
import Foundation
import NexusCore
import NexusIPC
import NexusMail

// nexus mail (Phase 3, 3b and 3d). The inbox commands read the API of Mailpit, so Claude Code can
// read a mail during an app walk, for example the link of a password reset.
struct MailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Opens and reads the inbox of the mail service. Shows the outbox and the settings too.",
        subcommands: [Open.self, List.self, Show.self, Remove.self, Clear.self, Outbox.self, Settings.self],
        defaultSubcommand: Open.self
    )

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Opens the inbox of Mailpit in the browser.")

        func run() async throws {
            let api = try await inbox()
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/open")
            process.arguments = [api.inboxURL.absoluteString]
            try process.run()
            process.waitUntilExit()
            print("The inbox opens in the browser: \(api.inboxURL.absoluteString)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the newest mails in the inbox.")

        @Option(help: "Only the mails of this site or workspace, for example fix.shop.test.") var site: String?
        @Option(help: "The number of mails.") var limit = 50
        @Flag(help: "Prints JSON for a script.") var json = false

        func run() async throws {
            let mails = try await inbox().messages(tag: site, limit: limit)

            if json {
                print(try mailJSON(mails))
                return
            }

            guard !mails.isEmpty else {
                print(site.map { "The inbox has no mail of \($0)." } ?? "The inbox is empty.")
                return
            }

            for mail in mails {
                let tags = mail.tags.isEmpty ? "-" : mail.tags.joined(separator: ",")
                print([mail.id.padding(to: 24), shortTime(mail.created).padding(to: 17), tags.padding(to: 24), mail.from.padding(to: 30), mail.subject].joined(separator: " "))
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows one mail with its text. latest is the newest mail.")

        @Argument(help: "The id of the mail from nexus mail list, or latest.") var id = "latest"
        @Flag(help: "Prints JSON with the HTML, the headers and the files of the mail.") var json = false

        func run() async throws {
            let mail = try await inbox().message(id: id)

            if json {
                print(try mailJSON(mail))
                return
            }

            print("From:    \(mail.from)")
            print("To:      \(mail.to.joined(separator: ", "))")

            if !mail.cc.isEmpty {
                print("Cc:      \(mail.cc.joined(separator: ", "))")
            }

            print("Subject: \(mail.subject)")
            print("Date:    \(mail.date)")
            print("Tags:    \(mail.tags.isEmpty ? "-" : mail.tags.joined(separator: ", "))")

            for file in mail.attachments {
                print("File:    \(file.file) (\(file.type), \(file.size) bytes)")
            }

            print("")
            print(mail.text.isEmpty ? mail.html : mail.text)
        }
    }

    // Mailpit gives no error for an id that it does not have. So the command reads each mail
    // first. That read also turns latest into an id.
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Removes one or more mails from the inbox. latest is the newest mail.")

        @Argument(help: "The ids of the mails from nexus mail list, or latest.") var ids: [String] = []

        func validate() throws {
            if ids.isEmpty {
                throw ValidationError("Give the id of a mail, or latest. nexus mail clear removes all mails.")
            }
        }

        func run() async throws {
            let api = try await inbox()
            var found: [String] = []

            for id in ids {
                found.append(try await api.message(id: id).id)
            }

            try await api.remove(ids: found)
            print(found.count == 1 ? "Nexus removed the mail \(found[0]) from the inbox." : "Nexus removed \(found.count) mails from the inbox.")
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Removes all mails from the inbox.")

        func run() async throws {
            try await inbox().removeAll()
            print("The inbox is empty.")
        }
    }

    struct Outbox: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows the mails that wait for the mail service.")

        @Flag(help: "Removes the waiting mails and the mails that Mailpit refused.") var clear = false

        func run() async throws {
            if clear {
                try finish(try await send(.clearOutbox))
                return
            }

            let status = try await mailStatus()

            guard status.waiting > 0 else {
                print("The outbox is empty.")
                return
            }

            let size = ByteCountFormatter.string(fromByteCount: Int64(status.waitingBytes), countStyle: .file)
            let one = status.waiting == 1
            print("\(one ? "1 mail waits" : "\(status.waiting) mails wait") in the outbox (\(size)): \(status.outboxFolder)")
            let them = one ? "it" : "them"

            if status.running {
                print("Mailpit runs. So nexusd gives \(them) to Mailpit within 15 seconds.")
            } else {
                print(status.installed ? "The mail service gets \(them) at its next start. Run: nexus start mail" : "Install the mail service to read \(them). Run: nexus install mailpit 1")
            }

            if status.removed > 0 {
                print("The limits of the outbox removed \(count(status.removed, "mail")). See: nexus mail settings")
            }

            if status.refused > 0 {
                print("Mailpit refused \(count(status.refused, "mail")). They are in the folder refused next to the outbox.")
            }
        }
    }

    struct Settings: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows or changes the limits of the outbox and the inbox.")

        @Option(help: "The most mails in the outbox, from 10 to 10000.") var outboxMails: Int?
        @Option(help: "The most space of the outbox, from 10MB to 2GB.") var outboxSize: String?
        @Option(help: "The most days that a mail waits, from 1 to 90.") var outboxDays: Int?
        @Option(help: "The number of newest mails that the inbox keeps, from 100 to 50000.") var inboxMails: Int?
        @Option(help: "What a full outbox does: remove-oldest or refuse-new.") var whenFull: MailSettings.WhenFull?

        func run() async throws {
            var settings = try await mailStatus().settings

            guard outboxMails != nil || outboxSize != nil || outboxDays != nil || inboxMails != nil || whenFull != nil else {
                print("Outbox mails  \(settings.outboxMails)")
                print("Outbox size   \(MailSettings.sizeText(settings.outboxBytes))")
                print("Outbox days   \(settings.outboxDays)")
                print("Inbox mails   \(settings.inboxMails)")
                print("When full     \(settings.whenFull.argumentName)")
                return
            }

            if let outboxSize {
                guard let bytes = MailSettings.bytes(of: outboxSize) else {
                    throw ValidationError("Give the size of the outbox as 100MB or 2GB.")
                }

                settings.outboxBytes = bytes
            }

            settings.outboxMails = outboxMails ?? settings.outboxMails
            settings.outboxDays = outboxDays ?? settings.outboxDays
            settings.inboxMails = inboxMails ?? settings.inboxMails
            settings.whenFull = whenFull ?? settings.whenFull
            try finish(try await send(.setMailSettings(settings)))
        }
    }
}

extension MailSettings.WhenFull: ExpressibleByArgument {
    public init?(argument: String) {
        guard let value = Self.allCases.first(where: { $0.argumentName == argument }) else {
            return nil
        }

        self = value
    }

    public static var allValueStrings: [String] {
        allCases.map(\.argumentName)
    }

    var argumentName: String {
        rawValue.replacing("_", with: "-")
    }
}

// The inbox needs an installed and running Mailpit.
private func inbox() async throws -> MailpitAPI {
    let status = try await mailStatus()

    guard status.installed else {
        FileHandle.standardError.write(Data("The mail service is not installed. Run: nexus install mailpit 1\n".utf8))
        throw ExitCode.failure
    }

    guard status.running, let port = status.inboxPort else {
        FileHandle.standardError.write(Data("The inbox does not run. Run: nexus start mail\n".utf8))
        throw ExitCode.failure
    }

    return MailpitAPI(port: port)
}

private func mailStatus() async throws -> MailStatus {
    let response = try await send(.mailStatus)

    guard case .mailStatus(let status) = response else {
        try finish(response)
        throw ExitCode.failure
    }

    return status
}

private func mailJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

// Mailpit gives the time with fractions of a second and a time zone.
private func shortTime(_ created: String) -> String {
    let withFractions = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    guard let date = (try? Date(created, strategy: withFractions)) ?? (try? Date(created, strategy: .iso8601)) else {
        return created
    }

    return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

private func count(_ number: Int, _ noun: String) -> String {
    number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
}
