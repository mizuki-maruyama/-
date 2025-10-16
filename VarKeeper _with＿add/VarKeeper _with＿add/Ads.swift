import SwiftUI
import AppTrackingTransparency
import GoogleMobileAds

@MainActor
final class Ads: ObservableObject {
    @Published var started = false

    func start() {
        guard !started else { return } // 二重起動防止
        if #available(iOS 14, *) {
            ATTrackingManager.requestTrackingAuthorization { _ in
                // v12: GADMobileAds → MobileAds に名称変更
                MobileAds.shared.start(completionHandler: { _ in
                    DispatchQueue.main.async { self.started = true }
                })
            }
        } else {
            MobileAds.shared.start(completionHandler: { _ in
                self.started = true
            })
        }
    }
}

// v12: GADBannerView → BannerView、GADAdSizeBanner → AdSizeBanner、GADRequest → Request
struct BannerAdView: UIViewRepresentable {
    private let unitID = "ca-app-pub-3940256099942544/2934735716" // テスト用ユニットID

    func makeUIView(context: Context) -> BannerView {
        let v = BannerView(adSize: AdSizeBanner)
        v.adUnitID = unitID
        v.rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
        v.load(GoogleMobileAds.Request()) // 名前かぶり回避のためモジュール名を明示
        return v
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}
