import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("历史", systemImage: "doc.on.clipboard") {
                HistoryView()
            }
            Tab("设置", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}
