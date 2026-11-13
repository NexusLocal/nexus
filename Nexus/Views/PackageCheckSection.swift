import NexusCore
import SwiftUI

// The result of "Check for updates": the design "Packages Update Check States" in nexus.pen. On
// the Packages screen it covers all packages, and a failed check shows also without a click. On a
// service screen it covers only the package of that service. A form gives an empty section its
// own space, so the section is there only when it has a banner.
struct PackageCheckSection: View {
    private enum Content {
        case problem(String)
        case result
    }

    @Environment(AppModel.self) private var model
    @AppStorage(AppPreference.installPackageUpdates) private var installsUpdates = true
    var service: ServiceVersion?
    var showUpdates: (() -> Void)?

    private var content: Content? {
        if let problem = model.packagesProblem, service == nil || model.showsPackageCheck {
            return .problem(problem)
        }

        return model.showsPackageCheck && !model.checkingPackages ? .result : nil
    }

    var body: some View {
        if let content {
            Section {
            } footer: {
                switch content {
                case .problem(let problem):
                    WarningBanner(title: "Nexus cannot check for updates", message: problem) {
                        Button("Try again") {
                            model.checkPackagesOnClick()
                        }
                    }
                case .result:
                    result
                }
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        let updates = service.map { service in model.checkedUpdates.filter { $0.serviceID == service.id } } ?? model.checkedUpdates

        if updates.isEmpty {
            NoticeBanner(systemImage: "checkmark.circle", color: .statusGreen, background: AnyShapeStyle(.fill.quaternary), title: service.map { "\($0.name) is up to date" } ?? "All packages are up to date") {
                Text("Nexus checked the package list at \(model.packagesChecked).")
            } actions: {
                okButton
            }
        } else {
            let list = EnglishList.joined(updates.map { "\($0.name) to \($0.newVersion ?? "")" })
            let count = Count.text(updates.count, "update")

            NoticeBanner(systemImage: "arrow.down.circle", color: .accentText, background: AnyShapeStyle(Color.accentSoft), title: installsUpdates ? "Nexus installs \(count)" : "\(count) \(updates.count == 1 ? "is" : "are") ready") {
                Text(installsUpdates ? "\(list). A service that runs starts again after its update." : "\(list).")
            } actions: {
                if !installsUpdates, let showUpdates {
                    Button("Show updates", action: showUpdates)
                        .buttonStyle(.borderedProminent)
                } else {
                    okButton
                }
            }
        }
    }

    private var okButton: some View {
        Button("OK") {
            model.showsPackageCheck = false
        }
    }
}
