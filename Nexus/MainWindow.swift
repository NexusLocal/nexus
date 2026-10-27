import AppKit
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    // The task below runs again each time the window opens. The launch arguments apply one time.
    private static var launchArgumentsApplied = false

    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            background.registerIfNeeded()

            guard !Self.launchArgumentsApplied else {
                return
            }

            Self.launchArgumentsApplied = true

            if CommandLine.arguments.contains("--first-run") {
                openWindow(id: FirstRunWindow.id)
            }

            #if DEBUG
            DebugLaunch.apply(to: model) { openSettings() }
            #endif
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .addSite:
                AddSiteSheet()
            case .importDatabase(let instance):
                ImportDatabaseSheet(instance: instance)
            case .portInUse(let id, let holder):
                if let service = model.service(id) {
                    PortInUseSheet(service: service, holder: holder)
                } else {
                    Color.clear
                        .onAppear { model.sheet = nil }
                }
            }
        }
        .alert(windowFailure?.title ?? "", isPresented: showsFailure, presenting: windowFailure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            background.refresh()
        }
    }

    private var windowFailure: ActionFailure? {
        model.failure.flatMap { $0.place == .window ? $0 : nil }
    }

    private var showsFailure: Binding<Bool> {
        Binding(
            get: { windowFailure != nil },
            set: { shown in
                if !shown {
                    model.failure = nil
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .site(let host):
            if let site = model.site(host) {
                SiteScreen(site: site)
                    .id(host)
            } else {
                OverviewScreen()
            }
        case .service(let kind):
            ServiceScreen(kind: kind)
                .id(kind)
        case .packages:
            PackagesScreen()
        case .commandLine:
            CommandLineScreen()
        case .overview, nil:
            OverviewScreen()
        }
    }
}

#Preview {
    MainWindow()
        .environment(AppModel.sample())
        .environment(BackgroundServices())
}
