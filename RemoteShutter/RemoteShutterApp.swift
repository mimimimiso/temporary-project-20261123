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
                settingsBox
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
            }
        } label: {
            Label("状態", systemImage: "info.circle")
        }
    }

    private var settingsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                menuRow("カメラ", selection: Binding(
                    get: { model.cameraPosition },
                    set: { model.setCameraPosition($0) }
                ), options: CameraPosition.allCases.filter { $0 == .back || AppModel.hasFrontCamera }, label: \.label)
                menuRow("向き", selection: Binding(
                    get: { model.orientation },
                    set: { model.setOrientation($0) }
                ), options: CaptureOrientation.allCases, label: \.label)
                menuRow("フラッシュ", selection: Binding(
                    get: { model.flash },
                    set: { model.setFlash($0) }
                ), options: FlashSetting.allCases, label: \.label)
                .disabled(!model.flashSupported)
                menuRow("倍率", selection: Binding(
                    get: { model.zoom },
                    set: { model.setZoom($0) }
                ), options: model.zoomOptions, label: { CameraController.zoomLabel($0) })
                Toggle("写真アプリにも保存", isOn: Binding(
                    get: { model.saveToPhotos },
                    set: { model.setSaveToPhotos($0) }
                ))
                .font(.callout)
            }
        } label: {
            Label("設定(PCのページからも変えられます)", systemImage: "slider.horizontal.3")
        }
    }

    private func menuRow<T: Hashable>(_ title: String, selection: Binding<T>, options: [T], label: @escaping (T) -> String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
        }
        .font(.callout)
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
