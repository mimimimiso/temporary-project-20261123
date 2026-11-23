import Combine
import SwiftUI
import UIKit

@main
struct RemoteShutterApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.start()
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    private let ipTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                urlBox
                statusBox
                logBox
                Button(role: .destructive) {
                    model.regenerateToken()
                } label: {
                    Text("トークンを作り直す")
                }
                .font(.footnote)
            }
            .padding()
        }
        .onAppear {
            // カメラ使用中に自動ロックされないようにする
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
        .onReceive(ipTimer) { _ in
            model.refreshIP()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("RemoteShutter").font(.title.bold())
            Spacer()
            Text("v\(AppModel.appVersion) (build \(AppModel.buildNumber))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var urlBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.urlString)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("コピー") {
                        UIPasteboard.general.string = model.urlString
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text("トークン: \(model.token)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("同じWi-FiのPCのブラウザで開く", systemImage: "desktopcomputer")
        }
    }

    private var statusBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                row("サーバー", model.serverState)
                row("カメラ", model.cameraState)
                row("最大解像度", model.maxPhotoSize)
                row("撮影回数", "\(model.captureCount)")
                row("ライブ映像の視聴", "\(model.streamClients)")
                HStack {
                    Text("向き").foregroundStyle(.secondary)
                    Spacer()
                    Picker("向き", selection: Binding(
                        get: { model.orientation },
                        set: { model.setOrientation($0) }
                    )) {
                        ForEach(CaptureOrientation.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .font(.callout)
            }
        } label: {
            Label("状態", systemImage: "info.circle")
        }
    }

    private var logBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.logs.suffix(40).reversed()) { line in
                    Text(line.text)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            Label("ログ(新しい順)", systemImage: "list.bullet.rectangle")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }
}
