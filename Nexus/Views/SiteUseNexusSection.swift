import NexusIPC
import SwiftUI

// The notice "The .env of shop.test does not use Nexus" at the top of the Site screen, and its
// sheet (owner, 2026-11-14). The design is "Site Notice Use Nexus" in nexus.pen. While a copy runs,
// the notice stays, and its button opens the sheet with the progress. After the change the plan is
// empty. So the done message takes the place of the notice, and the sheet closes.
struct SiteUseNexusSection: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem
    let info: UseNexusInfo?

    @State private var showsSheet = false

    var body: some View {
        if let done = model.useNexusDone[site.host] {
            DoneSection(done: done) {
                model.useNexusDone[site.host] = nil
            }
        } else if let info {
            Section {
            } footer: {
                WarningBanner(title: info.noticeTitle, message: info.noticeMessage) {
                    Button("Use Nexus…") {
                        showsSheet = true
                    }
                }
            }
            .sheet(isPresented: $showsSheet) {
                UseNexusSheet(info: info)
            }
        }
    }
}
