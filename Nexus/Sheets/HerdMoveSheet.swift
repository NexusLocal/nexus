import AppKit
import NexusCore
import NexusIPC
import NexusRuntime
import SwiftUI

// The move from Herd (group 9). The design is "Sheet Move From Herd", "· Progress", "· Done" and
// "· States" in nexus.pen. The sheet shows the plan first. While the move runs, it shows the steps
// of the task. The user can close the sheet, and nexusd goes on.
struct HerdMoveSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let run = model.herdMoveRun {
                switch run.result {
                case nil:
                    HerdMoveProgressView(summary: run.summary, tld: run.tld)
                case .done(let message)?:
                    HerdMoveDoneView(message: message)
                case let result?:
                    HerdMoveEndedView(result: result)
                }
            } else if model.liveHerdMoveTask != nil {
                HerdMoveProgressView(summary: nil, tld: model.herdMovePlan?.tld ?? "test")
            } else {
                HerdMoveReview()
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

private struct HerdMoveReview: View {
    @Environment(AppModel.self) private var model
    @State private var choices = HerdMoveChoices()
    @State private var loaded = false
    @State private var showsDetails = false
    @State private var contentHeight: CGFloat = 0
    @State private var errorReport: ErrorReport?

    private static let longestList: CGFloat = 420

    // The sheet keeps its buttons on the screen. The sections scroll when the plan is long.
    private var longestContent: CGFloat {
        min(Self.longestList, max(240, (NSScreen.main?.visibleFrame.height ?? 900) - 240))
    }

    var body: some View {
        let plan = model.herdMovePlan.flatMap { $0.isEmpty ? nil : $0 }
        let name = model.moveSource.name

        VStack(alignment: .leading, spacing: 12) {
            Text("Move from \(name)")
                .font(.headline)

            if let plan {
                Text(intro(plan))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    HerdMovePlanSections(plan: plan, choices: $choices)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(contentHeight, longestContent))
                .scrollBounceBehavior(.basedOnSize)
            } else if let problem = model.herdMovePlanProblem {
                FailureLabel(message: problem) { errorReport = $0 }
            } else if !loaded || model.loadingHerdMovePlan {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Nexus reads the files of \(name)…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(HerdMoveText.nothingToMove(model.herdMovePlan)) So there is nothing to move.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Show Details…") {
                    showsDetails = true
                }
                .disabled(plan == nil)
                .sheet(isPresented: $showsDetails) {
                    HerdMoveDetailsSheet(lines: plan.map { HerdMoveText.summary($0) } ?? [])
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    model.sheet = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Move") {
                    if let plan {
                        model.startHerdMove(plan: plan, choices: choices)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.map { !choices.movesItems(of: $0) } ?? true || model.liveHerdMoveTask != nil)
            }
            .padding(.top, 4)
        }
        .task {
            await model.loadHerdMovePlan()
            loaded = true
        }
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
    }

    private func intro(_ plan: HerdMovePlan) -> String {
        let name = plan.source.name

        if plan.source == .local {
            return "Local by WP Engine, earlier Local by Flywheel. Nexus copies each item that is on. Nexus changes nothing in Local. Local can stay open while Nexus copies the databases."
        }

        let runs = plan.herdRuns ? " \(name) still runs while Nexus copies the databases." : ""
        return "Nexus copies each item that is on. Nexus changes nothing in \(name).\(runs)"
    }
}

// The sections of the plan. A row with a switch adds its ids to the skipped items when it is off.
// A database row shows only the version and the size. "Show Details…" has the full list.
private struct HerdMovePlanSections: View {
    @Environment(AppModel.self) private var model
    let plan: HerdMovePlan
    @Binding var choices: HerdMoveChoices

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let packages = packages

            if !packages.isEmpty {
                HerdMoveSection(title: "Nexus installs first", footer: packagesFooter(packages)) {
                    ForEach(packages) { package in
                        HerdMoveRow(systemImage: "arrow.down.to.line", title: HerdMoveText.packageTitle(package.name, package.line), detail: ([package.reason] + [size(package.bytes)].compactMap { $0 }).joined(separator: " · "))
                    }
                }
            }

            if plan.source == .local {
                LocalMoveSections(plan: plan, choices: $choices)
            } else {
                herdSections
            }
        }
    }

    @ViewBuilder
    private var herdSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !plan.sites.isEmpty {
                HerdMoveSection(title: "Sites", footer: sitesFooter) {
                    ForEach(plan.sites) { site in
                        siteRow(site)
                    }
                }
            }

            if !plan.databases.isEmpty || !plan.redis.isEmpty {
                HerdMoveSection(title: "Databases", footer: databasesFooter) {
                    ForEach(plan.databases) { database in
                        HerdMoveRow(title: database.name, isOn: isOn([database.id])) {
                            databaseValue(database)
                        }
                    }

                    ForEach(plan.redis) { server in
                        HerdMoveRow(title: redisTitle(server), detail: redisDetail(server), isOn: isOn([server.id]))
                    }
                }
            }

            if hasSettings {
                HerdMoveSection(title: "Settings") {
                    if !plan.ini.isEmpty {
                        let lines = plan.ini.reduce(0) { $0 + $1.lines.count }
                        HerdMoveRow(title: "php.ini lines", detail: "PHP \(EnglishList.joined(plan.ini.map(\.line))) · \(Count.text(lines, "line"))", isOn: isOn(plan.ini.map(\.id)))
                    }

                    if !sitesWithOwnLines.isEmpty {
                        HerdMoveRow(title: "Own nginx lines", detail: Count.text(sitesWithOwnLines.count, "site"), isOn: isOn([HerdMovePlan.ownLinesID]))
                    }

                    if !plan.envFiles.isEmpty {
                        HerdMoveRow(title: ".env files", detail: Count.text(plan.envFiles.count, "Laravel site"), isOn: isOn(plan.envFiles.map(\.id)))
                    }
                }
            }

            if !plan.files.isEmpty {
                HerdMoveSection(title: "Shell and projects", footer: "Nexus keeps a copy of each file that it changes.") {
                    ForEach(plan.files.filter { $0.kind == .shell }) { file in
                        HerdMoveRow(title: HerdMoveText.shortPath(file.path), detail: "\(Count.text(file.lines.count, "line")) of Herd", isOn: isOn([file.id]))
                    }

                    let projectFiles = plan.files.filter { $0.kind == .project }

                    if !projectFiles.isEmpty {
                        HerdMoveRow(title: "Project files with a PHP of Herd", detail: Count.text(projectFiles.count, "file"), isOn: isOn(projectFiles.map(\.id)))
                    }
                }
            }
        }
    }

    private func isOn(_ ids: [String]) -> Binding<Bool> {
        Binding(
            get: { choices.isOn(ids) },
            set: { choices.set(ids, on: $0) }
        )
    }

    // MARK: Packages

    // A package that the plan names, or a version line that the user chose and that is not installed.
    private var packages: [HerdMovePlan.Package] {
        let planned = Set(plan.packages.map(\.id))
        let installed = model.installedLoaded ? Set(model.installedRuntimes.map { "\($0.name)-\($0.line)" }) : nil

        return choices.packages(
            of: plan,
            isMissing: { name, line in
                planned.contains("\(name)-\(line)") || installed.map { !$0.contains("\(name)-\(line)") } == true
            },
            bytes: { name, line in
                plan.packages.first { $0.id == "\(name)-\(line)" }?.bytes ?? model.manifestPackages.first { $0.name == name && $0.line == line }?.size.map(Int64.init)
            }
        )
    }

    private func packagesFooter(_ packages: [HerdMovePlan.Package]) -> String {
        let sizes = packages.compactMap(\.bytes)
        let total = sizes.count == packages.count ? size(sizes.reduce(0, +)).map { ", \($0) in all" } ?? "" : ""

        return "Nexus downloads these packages before it copies anything\(total). The list follows the switches below."
    }

    private func size(_ bytes: Int64?) -> String? {
        bytes.map { $0.formatted(.byteCount(style: .file)) }
    }

    // MARK: Sites

    @ViewBuilder
    private func siteRow(_ site: HerdMovePlan.SiteItem) -> some View {
        let title = EnglishList.joined(site.hosts)

        if let herd = changedPHP(of: site) {
            HerdMoveRow(title: title, isOn: isOn([site.id])) {
                HStack(spacing: 6) {
                    Text((place(of: site) + ["PHP \(herd) →"]).joined(separator: " · "))
                        .foregroundStyle(Color.orangeText)

                    Picker("PHP", selection: phpLine(of: site)) {
                        ForEach(site.phpChoices, id: \.self) { Text("PHP \($0)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .disabled(!choices.isOn([site.id]))
                }
            }
        } else if site.kind == .proxy {
            HerdMoveRow(title: title, detail: "Proxy to \(site.address ?? "")", isOn: isOn([site.id]))
        } else {
            HerdMoveRow(title: title, detail: (place(of: site) + [site.php.map { "PHP \($0)" }].compactMap { $0 }).joined(separator: " · "), isOn: isOn([site.id]))
        }
    }

    private func place(of site: HerdMovePlan.SiteItem) -> [String] {
        [HerdMoveText.shortPath(site.folder)] + (site.projectType.isWordPress ? [site.projectType.displayName] : [])
    }

    // The version of Herd when Nexus suggests another line, for example 8.1 when Nexus has 8.2.
    private func changedPHP(of site: HerdMovePlan.SiteItem) -> String? {
        guard site.kind == .php, let herd = site.herdPHP, let line = site.php, !site.phpChoices.isEmpty else {
            return nil
        }

        let herdLine = VersionText.majorMinor(herd)
        return herdLine == line ? nil : herdLine
    }

    private func phpLine(of site: HerdMovePlan.SiteItem) -> Binding<String> {
        Binding(
            get: { choices.phpLine(of: site) ?? "" },
            set: { choices.php[site.id] = $0 }
        )
    }

    private var sitesFooter: String {
        let parked = plan.parked.map { HerdMoveText.shortPath($0.folder) }
        let parks = parked.isEmpty ? [] : ["Nexus parks \(EnglishList.joined(parked)), so each new folder there is a site too."]

        return (parks + plan.notes).joined(separator: " ")
    }

    // MARK: Databases

    @ViewBuilder
    private func databaseValue(_ database: HerdMovePlan.DatabaseItem) -> some View {
        let size = [size(database.bytes)].compactMap { $0 }

        if let source = changedSource(of: database) {
            HStack(spacing: 6) {
                Text(([HerdMoveText.packageTitle(database.kind, source)] + size).joined(separator: " · ") + " →")
                    .foregroundStyle(Color.orangeText)

                Picker("Version", selection: line(of: database)) {
                    ForEach(database.lineChoices, id: \.self) { Text(HerdMoveText.packageTitle(database.kind, $0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(!choices.isOn([database.id]))
            }
        } else if let line = database.line {
            Text(([HerdMoveText.packageTitle(database.kind, line)] + size).joined(separator: " · "))
                .foregroundStyle(.secondary)
        } else {
            Text("Nexus has no server for it")
                .foregroundStyle(Color.orangeText)
        }
    }

    // The version line of the server when Nexus does not have it. PostgreSQL names its lines with
    // one number.
    private func changedSource(of database: HerdMovePlan.DatabaseItem) -> String? {
        guard let version = database.version, let line = database.line, !database.lineChoices.isEmpty else {
            return nil
        }

        let major = VersionText.major(version)
        let source = database.kind == "postgresql" ? major : VersionText.majorMinor(version)

        return source == line || major == line ? nil : source
    }

    private func line(of database: HerdMovePlan.DatabaseItem) -> Binding<String> {
        Binding(
            get: { choices.line(of: database) ?? "" },
            set: { choices.databaseLines[database.id] = $0 }
        )
    }

    private func redisTitle(_ server: HerdMovePlan.RedisItem) -> String {
        let title = server.valkey ? "Valkey \(server.version.map(VersionText.majorMinor) ?? "")".trimmingCharacters(in: .whitespaces) : "Redis"
        let same = plan.redis.filter { $0.valkey == server.valkey }.count > 1

        return same ? "\(title) on port \(server.port)" : title
    }

    private func redisDetail(_ server: HerdMovePlan.RedisItem) -> String {
        let keys = server.keys.map { Count.text($0, "key") } ?? "The keys"
        let sameLine = !server.valkey && server.version.map(VersionText.majorMinor) == server.line

        return sameLine ? keys : "\(keys) → Redis \(server.line)"
    }

    private var databasesFooter: String {
        let changed = plan.databases.compactMap { database in changedSource(of: database).map { HerdMoveText.packageTitle(database.kind, $0) } }
        var sentences = ["Nexus reads each database from the server in the .env of the site, also when DBngin or Homebrew runs that server."]

        if changed.isEmpty {
            sentences.append("Each database goes to the same version in Nexus.")
        } else {
            sentences.append("Nexus has no \(EnglishList.joined(changed)). The popup offers only newer versions. A dump of a newer server does not always load into an older one.")
        }

        sentences.append("The server keeps its data.")

        if let valkey = plan.redis.first(where: \.valkey) {
            sentences.append("Nexus has no Valkey. Redis \(valkey.line) reads the keys of Valkey, so the applications need no change.")
        }

        return sentences.joined(separator: " ")
    }

    // MARK: Settings

    private var sitesWithOwnLines: [HerdMovePlan.SiteItem] {
        plan.sites.filter { $0.kind == .php && !$0.ownLines.isEmpty }
    }

    private var hasSettings: Bool {
        !plan.ini.isEmpty || !sitesWithOwnLines.isEmpty || !plan.envFiles.isEmpty
    }
}

// The sections of the move from Local (group 11). The design is "Sheet Move From Local" in
// nexus.pen. Each Local site has its own database server, so a site and its database share one
// row and one switch. A popup shows when Nexus suggests another PHP or database version.
private struct LocalMoveSections: View {
    let plan: HerdMovePlan
    @Binding var choices: HerdMoveChoices

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !plan.sites.isEmpty {
                HerdMoveSection(title: "Sites and their databases", footer: sitesFooter) {
                    ForEach(plan.sites) { site in
                        siteRow(site)
                    }
                }
            }

            HerdMoveSection(title: "Settings", footer: plan.httpsSites.isEmpty ? "" : "Nexus serves each site over HTTPS. So it changes the URLs in each database from http:// to https://.") {
                if !plan.ini.isEmpty {
                    let first = plan.ini[0]
                    HerdMoveRow(title: "php.ini lines", detail: "PHP \(EnglishList.joined(plan.ini.map(\.line))) · \(Count.text(plan.ini.reduce(0) { $0 + $1.lines.count }, "line"))", isOn: isOn(plan.ini.map(\.id)))
                        .help(first.lines.joined(separator: "\n"))
                }

                let ownLines = plan.sites.filter { !$0.ownLines.isEmpty }

                if !ownLines.isEmpty {
                    HerdMoveRow(title: "Own nginx lines", detail: Count.text(ownLines.count, "site"), isOn: isOn([HerdMovePlan.ownLinesID]))
                }

                if !plan.httpsSites.isEmpty {
                    HerdMoveRow(title: "URLs to HTTPS", detail: Count.text(plan.httpsSites.count, "site"), isOn: isOn([HerdMovePlan.httpsID]))
                }

                if let devTLD = plan.devTLD {
                    HerdMoveRow(title: "New sites get .\(devTLD.tld)", detail: devTLD.nexusSites == 0 ? "Nexus has no sites yet" : "Renames \(Count.text(devTLD.nexusSites, "site")) of Nexus", isOn: devTLDBinding(devTLD))
                }
            }

            if let devTLD = plan.devTLD, devTLD.nexusSites > 0, choices.usesDevTLD(plan) {
                Text("The switch also gives the \(Count.text(devTLD.nexusSites, "site")) of Nexus a new name, for example shop.test becomes shop.\(devTLD.tld). A name with *. does not work with .\(devTLD.tld). The sites of Local keep their .local names in each case.")
                    .font(.caption)
                    .foregroundStyle(Color.orangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let envrc = plan.files.filter { $0.kind == .envrc }

            if !envrc.isEmpty {
                HerdMoveSection(title: "Shell", footer: "Nexus keeps a copy of each file that it changes. Local writes each .envrc again when it starts the site.") {
                    HerdMoveRow(title: ".envrc files", detail: "\(Count.text(envrc.count, "site")), for direnv", isOn: isOn(envrc.map(\.id)))
                }
            }
        }
    }

    private func isOn(_ ids: [String]) -> Binding<Bool> {
        Binding(
            get: { choices.isOn(ids) },
            set: { choices.set(ids, on: $0) }
        )
    }

    private func devTLDBinding(_ item: HerdMovePlan.DevTLDItem) -> Binding<Bool> {
        Binding(
            get: { choices.devTLD ?? item.isOnByDefault },
            set: { choices.devTLD = $0 }
        )
    }

    private func siteRow(_ site: HerdMovePlan.SiteItem) -> some View {
        let database = choices.localDatabase(of: site, in: plan)
        let ids = [site.id] + [database?.id].compactMap { $0 }
        let changedPHP = changedPHP(of: site)
        let changedDatabase = database.flatMap(changedSource)

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.hosts[0])
                    .lineLimit(1)

                Text(detail(of: site, database: database, changedDatabase: changedDatabase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let changedPHP {
                Text("PHP \(changedPHP) →")
                    .font(.callout)
                    .foregroundStyle(Color.orangeText)

                Picker("PHP", selection: phpLine(of: site)) {
                    ForEach(site.phpChoices, id: \.self) { Text("PHP \($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(!choices.isOn(ids))
            } else if let line = site.php {
                Text("PHP \(line)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let database, changedDatabase != nil {
                Picker("Version", selection: line(of: database)) {
                    ForEach(database.lineChoices, id: \.self) { Text(HerdMoveText.packageTitle(database.kind, $0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(!choices.isOn(ids))
            }

            Toggle(site.hosts[0], isOn: isOn(ids))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }

    // "~/Local Sites/shop · nginx · MySQL 8.4 · 1.4 MB · runs". A row with two popups leaves out
    // the folder, so the row fits.
    private func detail(of site: HerdMovePlan.SiteItem, database: HerdMovePlan.DatabaseItem?, changedDatabase: String?) -> String {
        let folder = HerdMoveText.shortPath(URL(filePath: site.folder).deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let place = site.network.map { "Network on \($0.rawValue)" } ?? folder
        let server = site.server == .apache ? "Apache" : "nginx"
        var parts = changedDatabase != nil && changedPHP(of: site) != nil ? [server] : [place, server]

        if let database {
            parts.append(HerdMoveText.packageTitle(database.kind, changedDatabase ?? database.line ?? VersionText.majorMinor(database.version ?? "")))
            parts += [database.bytes.map { $0.formatted(.byteCount(style: .file)) }].compactMap { $0 }

            if database.runs == true {
                parts.append("runs")
            } else if database.dataFolder == nil, database.dump != nil {
                parts.append("only local.sql")
            }
        }

        return parts.joined(separator: " · ")
    }

    private func changedPHP(of site: HerdMovePlan.SiteItem) -> String? {
        guard let local = site.herdPHP, let line = site.php, !site.phpChoices.isEmpty else {
            return nil
        }

        let localLine = VersionText.majorMinor(local)
        return localLine == line ? nil : localLine
    }

    private func changedSource(of database: HerdMovePlan.DatabaseItem) -> String? {
        guard let version = database.version, let line = database.line, !database.lineChoices.isEmpty else {
            return nil
        }

        let source = VersionText.majorMinor(version)
        return source == line ? nil : source
    }

    private func phpLine(of site: HerdMovePlan.SiteItem) -> Binding<String> {
        Binding(
            get: { choices.phpLine(of: site) ?? "" },
            set: { choices.php[site.id] = $0 }
        )
    }

    private func line(of database: HerdMovePlan.DatabaseItem) -> Binding<String> {
        Binding(
            get: { choices.line(of: database) ?? "" },
            set: { choices.databaseLines[database.id] = $0 }
        )
    }

    private var sitesFooter: String {
        (["Each site keeps its folder and its name. Nexus writes the names to /etc/hosts, because macOS finds .local names only there. A site that runs in Local gives the data of this moment. For a stopped site, Nexus opens a copy of its data folder."] + plan.notes).joined(separator: " ")
    }
}

// The first one or two numbers of a version, for example 8.4 and 8 of 8.4.7.
enum VersionText {
    static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func major(_ version: String) -> String {
        String(version.split(separator: ".").first ?? "")
    }
}

private struct HerdMoveSection<Content: View>: View {
    let title: String
    var footer = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .fontWeight(.semibold)

            RowGroup {
                content
            }

            if !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HerdMoveRow<Value: View>: View {
    var systemImage: String?
    let title: String
    var isOn: Binding<Bool>?
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }

            Text(title)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 12)

            value
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            if let isOn {
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }
}

extension HerdMoveRow where Value == Text {
    init(systemImage: String? = nil, title: String, detail: String, isOn: Binding<Bool>? = nil) {
        self.init(systemImage: systemImage, title: title, isOn: isOn) {
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }
}

// "Show Details…": the whole plan as text, with each php.ini line and each file.
private struct HerdMoveDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details of the move")
                .font(.headline)

            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 420)
            .background(.fill.quaternary, in: .rect(cornerRadius: 10))

            HStack {
                Button("Copy") {
                    copyToPasteboard(lines.joined(separator: "\n"))
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

// The steps of the move. The step "Quit Herd" waits until Herd stops. Then the banner asks the
// user to quit Herd and to turn off its login item, because only the user can change that.
private struct HerdMoveProgressView: View {
    @Environment(AppModel.self) private var model
    @State private var quitting = false
    let summary: String?
    let tld: String

    var body: some View {
        let task = model.liveHerdMoveTask ?? model.herdMoveTask
        let source = model.moveSource
        let waitsForApp = task?.steps?.contains { $0.state == .running && $0.title == source.stopStep } == true

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Moving from \(source.name)")
                    .font(.headline)

                if let summary {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
            }

            if let steps = task?.steps {
                TaskStepList(steps: steps, waitsForUser: source.stopStep)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Nexus reads the files of \(source.name) and plans the steps…")
                        .foregroundStyle(.secondary)
                }
            }

            if waitsForApp, source == .valet {
                ValetStopBanner(tld: tld)
            } else if waitsForApp, source == .local {
                // "Sheet Move From Local · States": after the click, the banner says that Local
                // needs some seconds (owner, 2026-11-27).
                NoticeBanner(systemImage: "hand.raised", color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: quitting ? "Local quits" : "Quit Local to go on") {
                    Text(quitting
                        ? "Local stops its sites first. Nexus goes on when Local and its helper have stopped. This takes about 15 seconds."
                        : "Local has ports 80 and 443. Nexus serves your sites after Local quits. When sites run, Local asks if you are sure. Click Yes there.")
                } actions: {
                    if quitting {
                        QuittingLabel()
                    } else {
                        Button("Quit Local", action: quitHerd)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if waitsForApp {
                // "Sheet Move From Herd · States": after the click, the banner says that Herd needs
                // some seconds (owner, 2026-11-27).
                NoticeBanner(systemImage: "hand.raised", color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: quitting ? "Herd quits" : "Quit Herd to go on") {
                    Text(quitting
                        ? "Herd stops its services first. Nexus goes on when Herd has stopped. This takes some seconds. Also turn off Herd in Login Items."
                        : "Herd has ports 80 and 443 and the domain .\(tld). Nexus takes them over when Herd stops. Also turn off Herd in Login Items. Else Herd starts again at the next login.")
                } actions: {
                    Button("Open Login Items") {
                        model.openLoginItems()
                    }

                    if quitting {
                        QuittingLabel()
                    } else {
                        Button("Quit Herd", action: quitHerd)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                TaskLogBox(lines: task?.log ?? [], height: 120)
            }

            Text(waitsForApp ? "You can close this sheet. The move waits for \(source.name). The Overview shows it under Activity." : "You can close this sheet. Nexus goes on. The Overview shows the move under Activity.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Show log file") {
                    if let file = task?.logFile {
                        NSWorkspace.shared.open(URL(filePath: file))
                    }
                }
                .disabled(task?.logFile == nil)

                Spacer()

                Button("Stop") {
                    if let running = model.liveHerdMoveTask {
                        model.stopTask(running.id)
                    }
                }
                .disabled(model.liveHerdMoveTask == nil)

                Button("Close") {
                    model.sheet = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // Herd and Local can ask a question before they quit. So the button works again after a while.
    // Local and its helper need about 15 seconds after the answer.
    private func quitHerd() {
        quitting = true
        model.quitHerd()

        Task {
            try? await Task.sleep(for: .seconds(model.moveSource == .local ? 45 : 10))
            quitting = false
        }
    }
}

// The place of the quit button while the app quits.
private struct QuittingLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Quitting…")
                .foregroundStyle(.secondary)
        }
    }
}

// The design is "Sheet Move From Valet · Progress" in nexus.pen. Valet runs as root, so only
// valet stop with the password of the user stops it (owner, 2026-11-25).
private struct ValetStopBanner: View {
    static let command = "valet stop"
    let tld: String

    var body: some View {
        NoticeBanner(systemImage: "hand.raised", color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: "Stop Valet to go on") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Valet has ports 80 and 443 and the domain .\(tld). Valet runs as root, so Nexus cannot stop it. Run this command in Terminal. Valet asks for your password, and Nexus goes on when Valet stops.")

                HStack(spacing: 8) {
                    Text(Self.command)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

                    Button("Copy") {
                        copyToPasteboard(Self.command)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } actions: {
            EmptyView()
        }
    }
}

private struct HerdMoveDoneView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        let steps = model.endedHerdMoveSteps(.done(message))
        let name = model.moveSource.name

        VStack(alignment: .leading, spacing: 12) {
            Text("Your sites moved from \(name)")
                .font(.headline)

            Text(Self.result(of: message))
                .fixedSize(horizontal: false, vertical: true)

            if !steps.isEmpty {
                TaskStepList(steps: steps)
            }

            if model.hasHerdCertificate {
                HerdCertificateBanner()
            }

            Text("\(name) and its files stay as they are. The report tells you how to go back to \(name).\(model.moveSource == .local ? " These things did not move: the mails of Local, Live Links, the Blueprints and the connections to WP Engine." : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Show Report") {
                    model.showHerdReport()
                }

                Spacer()

                Button("Done") {
                    model.endHerdMove()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // "Show Report" opens the report. So the path of the report leaves the message.
    static func result(of message: String) -> String {
        guard let range = message.range(of: " The report is in ") else {
            return message
        }

        return String(message[..<range.lowerBound])
    }
}

// Herd and Valet made a root certificate, and its key is a plain file. Nexus does not need it
// (decision 8). Valet trusts it for each user of this Mac (owner, 2026-11-25).
private struct HerdCertificateBanner: View {
    @Environment(AppModel.self) private var model
    @State private var removing = false
    @State private var removed = false
    @State private var problem: String?

    var body: some View {
        let name = model.moveSource.name

        VStack(alignment: .leading, spacing: 6) {
            if removed {
                NoticeBanner(systemImage: "checkmark.shield", color: .statusGreen, background: AnyShapeStyle(.fill.quaternary), title: "macOS does not trust the \(name) \(model.moveSource == .local ? "certificates" : "certificate") now") {
                    Text("The certificate \(model.moveSource == .local ? "files stay" : "file stays") in the folder of \(name).")
                } actions: {
                    EmptyView()
                }
            } else {
                NoticeBanner(systemImage: "exclamationmark.shield", color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: "Remove the trust of the \(name) \(localCount > 1 ? "certificates" : "certificate")") {
                    Text(certificateText)
                } actions: {
                    Button(removing ? "Removing…" : "Remove Trust…", action: remove)
                        .disabled(removing)
                }
            }

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Color.redText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var localCount: Int {
        model.moveSource == .local ? model.certificates(of: .local).count : 1
    }

    // Local makes a certificate for each site. "Trust" in Local makes it a trusted root.
    private var certificateText: String {
        switch model.moveSource {
        case .valet:
            "Valet made a root certificate that can sign any domain. Each user of this Mac trusts it. Its key is a plain file. Nexus does not need it. macOS asks for your password."
        case .local:
            "Local made a certificate for \(EnglishList.joined(model.certificates(of: .local).map { $0.deletingPathExtension().lastPathComponent })) that can sign any domain. This Mac trusts it. Its key is a plain file. Nexus does not need it. macOS asks for your password."
        case .herd:
            "Herd made a root certificate that can sign any domain. Its key is a plain file on this Mac. Nexus does not need it."
        }
    }

    private func remove() {
        removing = true
        problem = nil

        Task {
            problem = await model.removeHerdCertificateTrust()
            removed = problem == nil
            removing = false
        }
    }
}

// A move that failed or that the user stopped. The report names what moved and how to go back.
private struct HerdMoveEndedView: View {
    @Environment(AppModel.self) private var model
    @State private var errorReport: ErrorReport?
    let result: HerdMoveResult

    var body: some View {
        let steps = model.endedHerdMoveSteps(result)
        let failedInstall = steps.first.map { $0.state == .failed && $0.title.hasPrefix("Install ") } == true
        let name = model.moveSource.name

        VStack(alignment: .leading, spacing: 12) {
            Text("The move from \(name) stopped")
                .font(.headline)

            switch result {
            case .failed(let message):
                FailureLabel(message: message) { errorReport = $0 }
            case .stopped(let message), .done(let message):
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !steps.isEmpty {
                TaskStepList(steps: steps)
            }

            Text(failedInstall ? "The move stops before it copies anything. \(name) still runs, and your sites keep working." : "\(name) and its files stay as they are. The report tells you what moved and how to go back to \(name).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Show Report") {
                    model.showHerdReport()
                }

                Spacer()

                Button("Try Again") {
                    model.tryHerdMoveAgain()
                }

                Button("Close") {
                    model.endHerdMove()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(item: $errorReport) { report in
            ErrorDetailsSheet(report: report)
        }
    }
}
