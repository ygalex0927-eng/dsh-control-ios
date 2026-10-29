import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var push: PushManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasHandledLaunchArguments = false

    var body: some View {
        TabView(selection: $app.tab) {
            OverviewView()
                .tabItem { Label("总览", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.overview)

            SessionListView()
                .tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(AppTab.sessions)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(.accentColor)
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastView(toast: toast)
                    .padding(.top, 6)
                    .zIndex(2)
            }
        }
        .animation(.snappy, value: app.toast)
        .onChange(of: app.filterMachineId) { _, machineId in
            app.activateMachine(machineId)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await push.refreshAuthorization()
            if !hasHandledLaunchArguments {
                hasHandledLaunchArguments = true
                await app.handleLaunchArguments()
            }
            await app.bootstrap()
        }
    }
}

