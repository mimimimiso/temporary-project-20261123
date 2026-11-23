import SwiftUI
import UIKit

@main
struct RemoteShutterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// M1: 配布経路の確認用。起動できること、どのビルドが入っているかだけを表示する。
struct ContentView: View {
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("RemoteShutter")
                .font(.largeTitle.bold())
            Text("M1: インストールと起動に成功しました")
            Text("v\(appVersion) (build \(buildNumber)) / iOS \(UIDevice.current.systemVersion)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            // カメラ使用中に自動ロックされないようにする(M2以降で必要)
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}
