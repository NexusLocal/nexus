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

    private let controller: SPUStandardUpdaterController
    private var observer: AnyCancellable?

    init() {
        #if DEBUG
        let starts = false
        #else
        let starts = true
        #endif

        controller = SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: nil, userDriverDelegate: nil)
        lastCheck = controller.updater.lastUpdateCheckDate
        checksAutomatically = controller.updater.automaticallyChecksForUpdates

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
