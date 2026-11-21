import Foundation
import NexusCore
import NexusRuntime

// The cloudflared package of NexusLocal/binaries (group 4, 4a). Its version starts with the year,
// for example 2026.11.0. So the package has the one line 1. Nexus runs only this binary. It never
// runs a cloudflared of Homebrew, of the system or of the PATH (D7).
enum CloudflaredPackage {
    static let name = "cloudflared"
    static let line = "1"

    static func binary(in folder: URL) -> URL {
        folder.appending(path: "bin/cloudflared", directoryHint: .notDirectory)
    }
}

extension NexusEngine {
    // A read of the manifest counts for one hour. So a second link in that hour does not wait for
    // GitHub (group 4, 4a).
    static let cloudflaredCheckInterval: TimeInterval = 60 * 60

    // The part of 4a in firstShareStep. A link without a cloudflared that can run starts with the
    // download. An update shows its step when it starts in prepareShare.
    func firstCloudflaredStep() async -> ShareStep {
        await usableCloudflared() == nil ? .downloadCloudflared : .openLink
    }

    // The part of 4a in prepareShare. It runs before the ports. So a long download holds no port.
    func prepareCloudflared(forShare id: String) async throws -> URL {
        try await prepareCloudflared {
            await self.showStep(.downloadCloudflared, ofShare: id)
        }
    }

    // The binary for a new link (group 4, 4a). Cloudflare refuses old clients (decision 1). So
    // nexusd installs the build of the manifest before a link. "Install package updates
    // automatically" is a setting of the app. nexusd does not read it. An open link keeps its
    // process, because the program keeps its old file. When an update fails the link uses the
    // installed build (owner, review-4ab question 13).
    func prepareCloudflared(onDownload: @Sendable () async -> Void) async throws -> URL {
        let installed = await usableCloudflared()
        let offered: ManifestPackage?

        do {
            offered = try await cloudflaredInManifest()
        } catch {
            guard let installed else {
                throw RuntimeError.unsupported(ShareText.Cloudflared.noPackageList(ErrorText.plain(error)))
            }

            activity?.write("share", ShareText.Cloudflared.oldPackageList(installed.version, reason: ErrorText.plain(error)))
            return CloudflaredPackage.binary(in: installed.folder)
        }

        guard let offered else {
            guard let installed else {
                throw RuntimeError.unsupported(ShareText.Cloudflared.notInPackageList)
            }

            return CloudflaredPackage.binary(in: installed.folder)
        }

        if let installed, installed.isSameBuild(as: offered) {
            return CloudflaredPackage.binary(in: installed.folder)
        }

        await onDownload()
        activity?.write("share", installed.map { ShareText.Cloudflared.update(from: $0.version, to: offered.version) } ?? ShareText.Cloudflared.download(offered.version))

        do {
            try await installCloudflared(offered)
        } catch {
            guard let installed else {
                throw error
            }

            activity?.write("share", ShareText.Cloudflared.updateFailed(from: installed.version, to: offered.version, reason: ErrorText.plain(error)))
            return CloudflaredPackage.binary(in: installed.folder)
        }

        guard let runtime = await usableCloudflared() else {
            throw RuntimeError.unsupported(ShareText.Cloudflared.noBinary)
        }

        return CloudflaredPackage.binary(in: runtime.folder)
    }

    // The installed package, when its binary can run.
    func usableCloudflared() async -> InstalledRuntime? {
        guard let runtime = await installer.installed(name: CloudflaredPackage.name, line: CloudflaredPackage.line) else {
            return nil
        }

        let binary = CloudflaredPackage.binary(in: runtime.folder).path(percentEncoded: false)
        return FileManager.default.isExecutableFile(atPath: binary) ? runtime : nil
    }

    private func cloudflaredInManifest() async throws -> ManifestPackage? {
        if let last = lastManifest, Date.now.timeIntervalSince(last.read) < Self.cloudflaredCheckInterval {
            return last.manifest.package(named: CloudflaredPackage.name, line: CloudflaredPackage.line)
        }

        return try await manifest().package(named: CloudflaredPackage.name, line: CloudflaredPackage.line)
    }

    // Each link that starts during an install waits for that install, as two new Laravel sites do.
    // A folder without a binary that can run goes first. Else install(_:) finds the same build and
    // does nothing.
    private func installCloudflared(_ package: ManifestPackage) async throws {
        if let running = cloudflaredInstall {
            try await running.value
            return
        }

        let download = Task {
            if await self.usableCloudflared() == nil {
                try await self.installer.remove(name: CloudflaredPackage.name, line: CloudflaredPackage.line)
            }

            _ = try await self.install(package)
        }

        cloudflaredInstall = download
        defer { cloudflaredInstall = nil }

        try await download.value
    }

    // The share panel shows the step of a link that starts. A link that ended keeps its state.
    private func showStep(_ step: ShareStep, ofShare id: String) async {
        if (try? await updateShare(id) { $0.state = .starting(step) }) != nil {
            publishSiteList()
        }
    }
}
