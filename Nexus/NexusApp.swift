import AppKit
import SwiftUI

// The Dock icon gets its setting before the first window shows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppPreference.registerDefaults()
        AppPresence.apply()
    }
}

@main
struct NexusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var background = BackgroundServices()
    @State private var model = AppModel.forLaunch()
    @AppStorage(AppPreference.showInMenuBar) private var showInMenuBar = true
    @AppStorage(AppPreference.showInDock) private var showInDock = true

    var body: some Scene {
        Window("Nexus", id: MainWindow.id) {
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
        }

        Window("Welcome to Nexus", id: FirstRunWindow.id) {
            FirstRunWindow()
                .environment(model)
                .environment(background)
                .plainTextInput()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsWindow()
                .environment(model)
                .environment(background)
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
            Image("MenuBarIcon")
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
