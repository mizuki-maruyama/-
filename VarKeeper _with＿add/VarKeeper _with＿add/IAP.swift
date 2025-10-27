import SwiftUI
import StoreKit

@MainActor
final class IAPStore: ObservableObject {
    enum SKU: String, CaseIterable {
        case removeAds = "remove_ads"
        case slotsPlus = "slots_plus"
        case proBundle = "pro_bundle"
    }

    @Published var products: [SKU: Product] = [:]
    @Published var adsRemoved = false
    @Published var slotsPlus = false

    init() {
        Task { await load() }
        Task { await observe() }
    }

    func load() async {
        do {
            let ids = SKU.allCases.map(\.rawValue)
            let list = try await Product.products(for: ids)
            var map: [SKU: Product] = [:]
            for p in list { if let s = SKU(rawValue: p.id) { map[s] = p } }
            self.products = map
            for await e in Transaction.currentEntitlements {
                if case .verified(let t) = e { apply(t.productID) }
            }
        } catch { print(error) }
    }

    func buy(_ sku: SKU) async {
        guard let p = products[sku] else { return }
        do {
            let r = try await p.purchase()
            if case .success(let v) = r, case .verified(let t) = v {
                apply(t.productID); await t.finish()
            }
        } catch { print(error) }
    }

    func restore() async { do { try await AppStore.sync() } catch { print(error) } }

    private func observe() async {
        for await u in Transaction.updates {
            if case .verified(let t) = u { apply(t.productID); await t.finish() }
        }
    }

    private func apply(_ id: String) {
        switch id {
        case SKU.removeAds.rawValue: adsRemoved = true
        case SKU.slotsPlus.rawValue: slotsPlus = true
        case SKU.proBundle.rawValue: adsRemoved = true; slotsPlus = true
        default: break
        }
    }

    func price(_ s: SKU) -> String { products[s]?.displayPrice ?? "" }
}

struct PurchaseSheet: View {
    @ObservedObject var store: IAPStore
    var onClose: () -> Void
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("広告を非表示")) {
                    if store.products[.removeAds] != nil {
                        Button("購入 \(store.price(.removeAds))") { Task { await store.buy(.removeAds); onClose() } }
                    } else {
                        ProgressView("価格を取得中…")
                    }
                }
                Section { Button("購入を復元") { Task { await store.restore(); onClose() } } }
            }
            .navigationTitle("アップグレード")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる", action: onClose) } }
        }
    }
}
