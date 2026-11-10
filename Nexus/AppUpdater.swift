import Combine
import Foundation
import Observation
import Sparkle

// App updates come from the releases of the public repository (D6). Sparkle keeps its settings in
// the defaults of the app, and this class writes a setting only when the user changes it. A debug
// build does not start the updater, because a release must not replace a build of the source.
@Observable
final class AppUpdater {
    static let repository = "github.com/NexusLocal/nexus"

    private(set) var canCheck = false
    private(set) var lastCheck: Date?

    var checksAutomatically: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    // The same setting as the checkbox "Download and install updates automatically from now on" in
    // the update window of Sparkle.
    var installsAutomatically: Bool {
        didSet {
            controller.updater.automaticallyDownloadsUpdates = installsAutomatically
        }
    }

    let readyPrompt = UpdateReadyPrompt()

    private let controller: SPUStandardUpdaterController
    private var observer: AnyCancellable?

    init() {
        #if DEBUG
        let starts = false
        #else
        let starts = true
        #endif

        controller = SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: readyPrompt, userDriverDelegate: nil)
        lastCheck = controller.updater.lastUpdateCheckDate
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates

        #if DEBUG
        if CommandLine.arguments.contains("--alert"), CommandLine.arguments.contains("update-ready") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [readyPrompt] in
                readyPrompt.preview(version: "0.2.6")
            }
        }
        #endif

        observer = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                self?.canCheck = canCheck
                self?.lastCheck = self?.controller.updater.lastUpdateCheckDate
            }
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}
