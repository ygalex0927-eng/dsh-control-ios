import SwiftUI

/// 详情页用**稳定的 sessionId** 驱动导航：列表被 api-session/* 刷新后
/// `SessionSummary` 值变了也不会把详情页弹回列表；只有会话被删除才退回。
struct SessionDetailHost: View {
    let sessionId: String
    var onDeleted: () -> Void = {}

    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if let session = app.session(id: sessionId) {
                SessionDetailView(session: session)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "trash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("会话已被删除")
                        .font(.headline)
                    Text("正在返回列表…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    app.showToast("会话已被删除")
                    onDeleted()
                }
            }
        }
    }
}
