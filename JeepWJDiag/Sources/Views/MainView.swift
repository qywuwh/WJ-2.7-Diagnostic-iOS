import SwiftUI

struct MainView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics

    var body: some View {
        TabView {
            ConnectionView()
                .tabItem { Label("Связь", systemImage: "antenna.radiowaves.left.and.right") }
            DTCView()
                .tabItem { Label("Ошибки", systemImage: "exclamationmark.triangle") }
            LogView()
                .tabItem { Label("Консоль", systemImage: "terminal") }
        }
        .tint(.orange)
    }
}
