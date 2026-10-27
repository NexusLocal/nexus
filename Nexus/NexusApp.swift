import SwiftUI

@main
struct NexusApp: App {
    @State private var background = BackgroundServices()
    @State private var model = AppModel.forLaunch()
    @AppStorage(AppPreference.showInMenuBar) private var showInMenuBar = true

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
    }
}
