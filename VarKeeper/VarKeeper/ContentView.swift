//
//  ContentView.swift
//  VarKeeper
//
//  Created by 中村太陽 on 2025/10/14.
//

import SwiftUI
import WebKit

struct ContentView: View {
    var body: some View {
        LocalWebView(htmlFile: "index") // ← index.html を読み込み
            .ignoresSafeArea()
    }
}

struct LocalWebView: UIViewRepresentable {
    let htmlFile: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 追加の設定が必要ならここで (例: JavaScript 有効はデフォルトで ON)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.bounces = false

        if let url = Bundle.main.url(forResource: htmlFile, withExtension: "html") {
            // バンドル内の index.html を file:// で読み込む
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<html><body><pre>index.html が見つかりません</pre></body></html>", baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
