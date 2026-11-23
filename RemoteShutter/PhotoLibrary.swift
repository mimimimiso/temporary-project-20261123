import Photos

/// iPhone の写真アプリへの保存(「写真を追加のみ」の権限で足りる)
enum PhotoLibrary {
    /// 許可を求める(まだ聞いていなければダイアログが出る)。結果は任意のスレッドで返る
    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            completion(status == .authorized || status == .limited)
        }
    }

    static func save(_ data: Data, log: @escaping (String) -> Void) {
        requestAccess { granted in
            guard granted else {
                log("写真アプリへの保存が許可されていません(設定 > RemoteShutter > 写真 で「写真を追加のみ」を選んでください)")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { ok, error in
                if ok {
                    log("写真アプリに保存しました")
                } else {
                    log("写真アプリへの保存に失敗: \(error?.localizedDescription ?? "不明なエラー")")
                }
            })
        }
    }
}
