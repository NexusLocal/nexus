import SwiftUI

struct MainWindow: View {
    static let id = "main"

    var body: some View {
        ContentUnavailableView(
            "No sites yet",
            systemImage: "server.rack",
            description: Text("Sites that you add to Nexus show here.")
        )
        .frame(minWidth: 720, minHeight: 480)
    }
}

#Preview {
    MainWindow()
}
