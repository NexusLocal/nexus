import Foundation
import Testing
@testable import NexusCore

struct ThirdPartyNoticesTests {
    private static let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: repository.appending(path: path), encoding: .utf8)
    }

    @Test func eachProjectOfTheTableHasASectionWithALicenseText() throws {
        let markdown = try Self.text("THIRD-PARTY-NOTICES.md")
        let notices = ThirdPartyNotices(markdown: markdown)
        let sections = Dictionary(uniqueKeysWithValues: notices.sections.map { ($0.name, $0) })
        let rows = markdown.split(separator: "\n").filter { $0.hasPrefix("| [") }

        #expect(!notices.projects.isEmpty)
        #expect(notices.projects.count == rows.count)

        for project in notices.projects {
            let blocks = sections[project.name]?.blocks ?? []
            #expect(blocks.contains { if case .text = $0 { true } else { false } }, "\(project.name) has no license text")
        }

        #expect(sections["Apache License 2.0"] != nil)
    }

    @Test func aRowGivesTheNameTheVersionTheLicenseAndTheUse() {
        let project = ThirdPartyNotices.project(inRow: "| [Sparkle](#sparkle) | 2.10.1 | MIT | The updates of the app |")

        #expect(project == ThirdPartyNotices.Project(name: "Sparkle", version: "2.10.1", license: "MIT", use: "The updates of the app"))
        #expect(ThirdPartyNotices.project(inRow: "| Project | Version | License | Use |") == nil)
        #expect(ThirdPartyNotices.project(inRow: "| --- | --- | --- | --- |") == nil)
        #expect(ThirdPartyNotices.project(inRow: "| [Sparkle](#sparkle) | 2.10.1 | | |") == ThirdPartyNotices.Project(name: "Sparkle", version: "2.10.1", license: "", use: ""))
        #expect(ThirdPartyNotices.project(inRow: "| [Sparkle](#sparkle) | 2.10.1 | MIT |") == nil)
    }

    @Test func eachListItemIsItsOwnParagraph() {
        let notices = ThirdPartyNotices(markdown: """
            ## Sparkle

            The parts:
            - the updater
              * the window
            1. the feed
            """)

        #expect(notices.sections.first?.blocks == [.paragraph("The parts:"), .paragraph("- the updater"), .paragraph("* the window"), .paragraph("1. the feed")])
    }

    @Test func aLicenseTextKeepsItsLines() {
        let notices = ThirdPartyNotices(markdown: """
            ## Sparkle

            ```
            Copyright (c) 2006-2013 Andy Matuschak.
            Copyright (c) 2014 Big Nerd Ranch.

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software.
            ```
            """)

        #expect(notices.sections.first?.blocks == [.text("Copyright (c) 2006-2013 Andy Matuschak.\nCopyright (c) 2014 Big Nerd Ranch.\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software.")])
    }

    @Test func aParagraphKeepsALinkToTheWebAndLosesALinkInTheFile() {
        let notices = ThirdPartyNotices(markdown: """
            ## Swift Argument Parser

            The text is in the section [Apache License 2.0](#apache-license-20) at
            [GitHub](https://github.com/apple/swift-argument-parser).
            """)

        #expect(notices.sections == [ThirdPartyNotices.Section(name: "Swift Argument Parser", blocks: [
            .paragraph("The text is in the section Apache License 2.0 at [GitHub](https://github.com/apple/swift-argument-parser)."),
        ])])
    }
}
