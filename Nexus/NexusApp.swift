import AppKit
import NexusCore
import NexusCrashReports
import NexusIPC
import SwiftUI

// The Dock icon gets its setting before the first window shows. The crash reports start first, so
// a crash during the launch gets a report too.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        CrashReports.apply(process: "app")
        ActivityTracker.start()
        AppPreference.registerDefaults()
        AppPresence.apply()
        MoveToApplications.askIfNeeded()
    }

    // A quit ends each public link. So the app asks first while a link is active (owner,
    // 2026-11-17: question 1 of review-4ab). A logout, a restart or a shutdown of the Mac does not
    // ask. An update does not ask either. Its window names the links (owner, 2026-11-20: questions
    // 2 and 3).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = NexusApp.launchModel
        let count = model.linksToStopAtQuit

        guard count > 0, !QuitQuestion.skips, !QuitQuestion.isSystemQuit else {
            return .terminateNow
        }

        guard QuitQuestion.confirm(linkCount: count) else {
            return .terminateCancel
        }

        Task {
            await model.stopAllSharesBeforeQuit()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}

// The alert before a quit while a link is active (owner, 2026-11-17).
enum QuitQuestion {
    // The update window names the links already.
    static var skips = false

    static func confirm(linkCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = ShareText.quitTitle(linkCount)
        alert.informativeText = ShareText.quitMessage
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApplication.shared.activate()

        return alert.runModal() == .alertFirstButtonReturn
    }

    // macOS sends a quit with a reason at a logout, a restart and a shutdown. nexusd stops then too.
    // The reason can come as a type code or as an enumeration. So both values count.
    static var isSystemQuit: Bool {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else {
            return false
        }

        let systemReasons = Set([kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown].map { OSType($0) })

        return systemReasons.contains(reason.typeCodeValue) || systemReasons.contains(reason.enumCodeValue)
    }
}

@main
struct NexusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var background = BackgroundServices()
    @State private var model: AppModel
    @State private var updater = AppUpdater()
    @AppStorage(AppPreference.showInMenuBar) private var showInMenuBar = true
    @AppStorage(AppPreference.showInDock) private var showInDock = true

    // SwiftUI can make the app value more than one time. So there is one model for the launch.
    // AppDelegate and UpdateReadyPrompt read the public links of this model.
    static let launchModel = AppModel.forLaunch()

    init() {
        _model = State(initialValue: Self.launchModel)
        NotificationClicks.shared.connect(Self.launchModel)
    }

    var body: some Scene {
        Window(NexusVariant.current.name, id: MainWindow.id) {
            MainWindow()
                .environment(model)
                .environment(background)
                .plainTextInput()
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                AddMenuItems()
                    .environment(model)
            }

            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }

            CommandGroup(after: .appInfo) {
                Button("Check for updates…") {
                    updater.check()
                }
                .disabled(!updater.canCheck)
            }
        }

        Window("Welcome to \(NexusVariant.current.name)", id: FirstRunWindow.id) {
            FirstRunWindow()
                .environment(model)
                .environment(background)
                .plainTextInput()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)

        Window("About \(NexusVariant.current.name)", id: AboutWindow.id) {
            AboutWindow()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        Settings {
            SettingsWindow()
                .environment(model)
                .environment(background)
                .environment(updater)
                .plainTextInput()
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContent()
                .environment(model)
                .environment(background)
                .onAppear {
                    background.refresh()
                }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        // A Cmd-drag can remove the menu bar icon while the Dock icon is off. The Dock icon then
        // comes back, so the app stays reachable.
        .onChange(of: showInMenuBar) {
            if !showInMenuBar, !showInDock {
                showInDock = true
            }
        }
        .onChange(of: showInDock) {
            AppPresence.apply()
            NSApplication.shared.activate()
        }
    }
}

// The icon of the menu bar with a globe while a link is active (design "Menu Bar Panel · Public
// link"). It reads one stored value. So a new list of sites draws it again only when that value
// changes.
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if model.hasActivePublicLink {
            Image(nsImage: .menuBarIconWithGlobe)
        } else {
            Image("MenuBarIcon")
        }
    }
}
