import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// ======================= セーフモード設定 =======================
// まずは確実に起動させるため true にしておく。
// 起動を確認できたら false にして永続化(UserDefaults)とコピー(UIPasteboard)を段階的に有効化する。
private let FORCE_SAFE_MODE: Bool = true

// ======================= モデル =======================
struct VKItem: Codable {
    var type: String = "number"
    var value: Double
    var updatedAt: TimeInterval
}
struct VKMeta: Codable {
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var slots: Int = 10
}
struct VKDB: Codable {
    var items: [String: VKItem] = [:]
    var meta: VKMeta = .init(
        createdAt: Date().timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970,
        slots: 10
    )
}

// ======================= ストア（セーフ／本番 切替） =======================
@MainActor
final class VKStore: ObservableObject {
    static let key: String = "varkeep:data:v10:native"
    
    @Published var db: VKDB
    private let safeMode: Bool
    
    init(safeMode: Bool) {
        self.safeMode = safeMode
        if safeMode {
            // セーフモード：永続化を使わない
            self.db = VKDB()
        } else {
            if let d: Data = UserDefaults.standard.data(forKey: Self.key),
               let v: VKDB = try? JSONDecoder().decode(VKDB.self, from: d) {
                self.db = v
            } else {
                // 破損データなどは捨ててクリーンに
                UserDefaults.standard.removeObject(forKey: Self.key)
                self.db = VKDB()
            }
        }
    }
    
    var slotsUsed: Int {
        let c: Int = db.items.values.filter { (it: VKItem) -> Bool in it.type != "expr" }.count
        return c
    }
    
    func save() -> Void {
        guard !safeMode else { return } // セーフモードでは保存しない
        db.meta.updatedAt = Date().timeIntervalSince1970
        if let d: Data = try? JSONEncoder().encode(db) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
        self.objectWillChange.send()
    }
    
    @discardableResult
    func upsert(name: String, value: Double) -> Bool {
        if db.items[name] == nil, slotsUsed >= db.meta.slots { return false }
        db.items[name] = VKItem(type: "number", value: value, updatedAt: Date().timeIntervalSince1970)
        self.save()
        return true
    }
    
    func delete(name: String) -> Void {
        _ = db.items.removeValue(forKey: name)
        self.save()
    }
}

// ======================= 計算エンジン（型明示） =======================
enum VKCalcError: LocalizedError {
    case empty, unbalancedParens, invalidChar
    case undefinedVariable(String), nonFiniteResult, syntax(String)
    
    var errorDescription: String? {
        switch self {
        case .empty: return "式を入力してください。"
        case .unbalancedParens: return "括弧が不一致です。"
        case .invalidChar: return "使用できない文字が含まれています。"
        case .undefinedVariable(let n): return "未定義の変数: \(n)"
        case .nonFiniteResult: return "計算結果が数値ではありません。"
        case .syntax(let s): return "構文エラー: \(s)"
        }
    }
}

struct VKEngine {
    static let allowed: Set<Character> = Set<Character>(["+","-","*","×","＊","/","÷","／","%","(",")",".","^","＾"," "].map { Character($0) })
    
    static func normalize(_ s: String) -> String {
        var t: String = s
        let reps: [(String,String)] = [("（","("),("）",")"),("＝","="),("＋","+"),("－","-"),("＊","*"),("×","*"),("／","/"),("÷","/"),("＾","^")]
        for (a, b) in reps { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }
    
    static func idStart(_ c: Character) -> Bool {
        return c == "_" || c.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }
    static func idCont(_ c: Character) -> Bool  {
        return c == "_" || c.unicodeScalars.allSatisfy { CharacterSet.letters.union(.decimalDigits).contains($0) }
    }
    
    enum Tok: Equatable { case number(Double), ident(String), op(String), lparen, rparen }
    
    static func tokenize(_ expr: String) throws -> [Tok] {
        let s: String = normalize(expr)
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw VKCalcError.empty }
        
        var out: [Tok] = []
        var i: String.Index = s.startIndex
        
        func prevIsVal(_ a: [Tok]) -> Bool {
            guard let x: Tok = a.last else { return false }
            switch x { case .number, .ident, .rparen: return true; default: return false }
        }
        
        while i < s.endIndex {
            let ch: Character = s[i]
            if ch.isWhitespace { i = s.index(after: i); continue }
            
            if ch.isNumber || ch == "." {
                var j: String.Index = i
                var dots: Int = 0
                while j < s.endIndex {
                    let c: Character = s[j]
                    if c == "." { dots += 1; if dots > 1 { break }; j = s.index(after: j); continue }
                    if !c.isNumber { break }
                    j = s.index(after: j)
                }
                let str: String = String(s[i..<j])
                guard let v: Double = Double(str) else { throw VKCalcError.syntax("数値が不正: \(str)") }
                if prevIsVal(out) { out.append(.op("*")) }
                out.append(.number(v))
                i = j
                continue
            }
            
            if idStart(ch) {
                var j: String.Index = s.index(after: i)
                while j < s.endIndex, idCont(s[j]) { j = s.index(after: j) }
                let name: String = String(s[i..<j])
                if prevIsVal(out) { out.append(.op("*")) }
                out.append(.ident(name))
                i = j
                continue
            }
            
            if ch == "(" {
                if prevIsVal(out) { out.append(.op("*")) }
                out.append(.lparen)
                i = s.index(after: i)
                continue
            }
            
            if ch == ")" { out.append(.rparen); i = s.index(after: i); continue }
            if ch == "*" {
                let n: String.Index = s.index(after: i)
                if n < s.endIndex, s[n] == "*" { out.append(.op("**")); i = s.index(i, offsetBy: 2) }
                else { out.append(.op("*")); i = n }
                continue
            }
            if ch == "+" { out.append(.op("+")); i = s.index(after: i); continue }
            if ch == "-" { out.append(.op("-")); i = s.index(after: i); continue }
            if ch == "/" { out.append(.op("/")); i = s.index(after: i); continue }
            if ch == "%" { out.append(.op("%")); i = s.index(after: i); continue }
            if ch == "^" { out.append(.op("**")); i = s.index(after: i); continue }
            
            if !allowed.contains(ch) { throw VKCalcError.invalidChar }
            i = s.index(after: i)
        }
        
        var res: [Tok] = []
        for (idx, t) in out.enumerated() {
            if case .op("-") = t {
                let prev: Tok? = idx > 0 ? out[idx-1] : nil
                let unary: Bool = {
                    guard let p: Tok = prev else { return true }
                    switch p { case .op, .lparen: return true; default: return false }
                }()
                res.append(unary ? .op("u-") : .op("-"))
            } else {
                res.append(t)
            }
        }
        return res
    }
    
    static func eval(_ expr: String, scope: [String: Double]) throws -> Double {
        let toks: [Tok] = try tokenize(expr)
        
        var depth: Int = 0
        for t in toks {
            if case .lparen = t { depth += 1 }
            if case .rparen = t { depth -= 1; if depth < 0 { throw VKCalcError.unbalancedParens } }
        }
        if depth != 0 { throw VKCalcError.unbalancedParens }
        
        func prec(_ op: String) -> (Int, Bool, Int) {
            switch op {
            case "u-": return (4, true, 1)
            case "**": return (3, true, 2)
            case "*","/","%": return (2, false, 2)
            case "+","-": return (1, false, 2)
            default: return (0, false, 2)
            }
        }
        
        var output: [Tok] = []
        var ops: [Tok] = []
        
        func push(_ op: String) -> Void {
            let (p1, r, _): (Int, Bool, Int) = prec(op)
            while let t: Tok = ops.last, case .op(let o2) = t {
                let (p2, _, _): (Int, Bool, Int) = prec(o2)
                if (r && p1 < p2) || (!r && p1 <= p2) {
                    _ = ops.popLast()
                    output.append(.op(o2))
                } else { break }
            }
            ops.append(.op(op))
        }
        
        for t in toks {
            switch t {
            case .number, .ident: output.append(t)
            case .op(let o): push(o)
            case .lparen: ops.append(.lparen)
            case .rparen:
                while let top: Tok = ops.last, top != .lparen {
                    if case .op(let o) = ops.popLast() { output.append(.op(o)) }
                }
                guard ops.last != nil else { throw VKCalcError.unbalancedParens }
                _ = ops.popLast()
            }
        }
        while let top: Tok = ops.popLast() {
            if case .lparen = top { throw VKCalcError.unbalancedParens }
            if case .op(let o) = top { output.append(.op(o)) }
        }
        
        var st: [Double] = []
        func pop() throws -> Double {
            guard let v: Double = st.popLast() else { throw VKCalcError.syntax("オペランド不足") }
            return v
        }
        
        for t in output {
            switch t {
            case .number(let v): st.append(v)
            case .ident(let n):
                guard let v: Double = scope[n], v.isFinite
                else { throw VKCalcError.undefinedVariable(n) }
                st.append(v)
            case .op(let o):
                switch o {
                case "u-": let a: Double = try pop(); st.append(-a)
                case "+":  let b: Double = try pop(), a: Double = try pop(); st.append(a + b)
                case "-":  let b: Double = try pop(), a: Double = try pop(); st.append(a - b)
                case "*":  let b: Double = try pop(), a: Double = try pop(); st.append(a * b)
                case "/":  let b: Double = try pop(), a: Double = try pop(); st.append(a / b)
                case "%":  let b: Double = try pop(), a: Double = try pop(); st.append(a.truncatingRemainder(dividingBy: b))
                case "**": let b: Double = try pop(), a: Double = try pop(); st.append(pow(a, b))
                default: throw VKCalcError.syntax("未知の演算子: \(o)")
                }
            default: break
            }
        }
        guard let res: Double = st.last, st.count == 1, res.isFinite else { throw VKCalcError.nonFiniteResult }
        return res
    }
}

// ======================= UI 補助 =======================
struct WideKeyStyle: ButtonStyle {
    var height: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.vertical, 0)
            .background(configuration.isPressed ? Color(white: 0.9) : Color(white: 0.98))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
            .contentShape(Rectangle())
    }
}

struct PromoBar: View {
    var onTap: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text("Proにするとスロット無制限").font(.footnote).foregroundColor(.secondary)
            Spacer()
            Button("詳しく", action: onTap).font(.footnote)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color(white: 0.97))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(white: 0.9)), alignment: .bottom)
    }
}

//struct AdBannerStub: View {
    //var body: some View {
        // Rectangle()
        //  .fill(Color(.systemGray6))
        //  .frame(height: 50)
        //  .overlay(Text("広告バナー（ダミー）").font(.footnote).foregroundColor(.secondary))
        //  .overlay(Rectangle().stroke(Color.gray.opacity(0.3)))
        //    }
//}

// ======================= ContentView =======================
struct ContentView: View {
    @StateObject private var ads = Ads()
    @StateObject private var store: VKStore = VKStore(safeMode: FORCE_SAFE_MODE)
    
    @State private var expr: String = ""
    @State private var resultText: String = "—"
    
    @State private var showManage: Bool = false
    @State private var editName: String = ""
    @State private var editValue: String = ""
    @State private var showVarSheet: Bool = false
    
    @State private var showConfirmDelete: Bool = false          // 外のチップ「×」用
    @State private var showConfirmDeleteInManage: Bool = false  // 管理シート内「削除」用
    @State private var targetDeleteName: String = ""
    
    @State private var inlineName: String = ""
    
    @State private var showError: Bool = false
    @State private var errorMsg: String = ""
    @State private var errorHints: [String] = []
    @State private var showPromoInfo: Bool = false
    
    private static let df: DateFormatter = {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                PromoBar{showPromoInfo=true}
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading) {
                        Text(expr.isEmpty ? "0" : expr)
                            .foregroundColor(expr.isEmpty ? .secondary : .primary)
                        Text(resultText).font(.title).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
                    
                    HStack(spacing: 8) {
                        Button("＋") { saveFromInlinePlus() }
                            .buttonStyle(WideKeyStyle(height: 36))
                            .frame(width: 54)
                        Text("変数")
                        TextField("変数名を入力", text: $inlineName)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .frame(width: 180)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Spacer(minLength: 0)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(sortedNumberEntries(), id: \.name) { (r: (name: String, value: Double)) in
                                HStack(spacing: 6) {
                                    Button("\(r.name)(\(trimDouble(r.value)))") { insertToken(r.name) }
                                        .buttonStyle(WideKeyStyle(height: 36))
                                    Button("×") {
                                        targetDeleteName = r.name
                                        showConfirmDelete = true   // ← 外のバー用
                                    }
                                    .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    
                    GeometryReader { (geo: GeometryProxy) in
                        let spacing: CGFloat = 8
                        let rows: Int = 5
                        let rowH: CGFloat = max(48, (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
                        VStack(spacing: spacing) {
                            keypadRow(["AC","(",")","DEL"], h: rowH)
                            keypadRow(["7","8","9","/"],     h: rowH)
                            keypadRow(["4","5","6","*"],     h: rowH)
                            keypadRow(["1","2","3","-"],     h: rowH)
                            keypadRow(["0",".","=","+"],     h: rowH)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
                
             //    AdBannerStub()
                BannerAdView().frame(height: 50)
            }
            // 「管理」シート
            .sheet(isPresented: $showManage) { manageSheet }
            // ここでは varEditSheet を出さない（競合回避）
            .alert("計算できません！", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                let msg: String = ([errorMsg] + errorHints.map { "• " + $0 }).joined(separator: "\n")
                Text(msg)
            }
            .alert("VarKeeper Pro", isPresented: $showPromoInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("スロット無制限や今後の拡張を予定。\n（この画面は控えめ表示です。実装時はStoreKitに差し替え）")
            }
            // 外のチップ列からの削除確認（このままでOK）
            .confirmationDialog("「\(targetDeleteName)」を削除しますか？",
                                isPresented: $showConfirmDelete,
                                titleVisibility: .visible) {
                Button("削除", role: .destructive) { store.delete(name: targetDeleteName) }
                Button("キャンセル", role: .cancel) {}
            }
        }
        .onAppear { ads.start() }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    // ---- UI building blocks ----
    func keypadRow(_ labels: [String], h: CGFloat) -> some View {
        HStack(spacing: 8) {
            ForEach(labels, id: \.self) { (k: String) in
                Button(action: { handleKey(k) }) {
                    Text(k).font(.title3).frame(maxWidth: .infinity)
                }
                .buttonStyle(WideKeyStyle(height: h))
            }
        }
    }
    
    func handleKey(_ k: String) -> Void {
        switch k {
        case "AC": clearAll()
        case "DEL":
            var s: String = expr
            if s.isEmpty { return }
            if let r: Range<String.Index> = lastIdentifierIn(s) { s.removeSubrange(r); expr = s; return }
            _ = s.popLast()
            expr = s
        case "=": doCalc()
        default: expr += k
        }
    }
    
    @inline(__always)
    func insertToken(_ t: String) -> Void { expr += t }
    
    // ---- Manage/編集 ----
    var manageSheet: some View {
        let items: [(name: String, value: Double, updatedAt: TimeInterval)] = sortedByUpdated()
        return NavigationView {
            List {
                ForEach(items, id: \.name) { (r: (name: String, value: Double, updatedAt: TimeInterval)) in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.name).font(.headline)
                        Text(dateString(from: r.updatedAt)).font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("編集") { editName = r.name; editValue = trimDouble(r.value); showVarSheet = true }
                            Button("式へ") { expr += r.name }
                            Button("コピー") { copyToPasteboard(trimDouble(r.value)) }
                            Button("削除", role: .destructive) {
                                targetDeleteName = r.name
                                showConfirmDeleteInManage = true   // ← 管理シート内の確認
                            }
                        }.font(.footnote)
                    }
                }
            }
            .navigationTitle("変数の管理")
        }
        // ★ 競合回避のため、管理シート側から出す
        .sheet(isPresented: $showVarSheet) { varEditSheet }
        .confirmationDialog("「\(targetDeleteName)」を削除しますか？",
                            isPresented: $showConfirmDeleteInManage,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) { store.delete(name: targetDeleteName) }
            Button("キャンセル", role: .cancel) {}
        }
    }
    
    var varEditSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("変数名", text: $editName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("値（式OK）", text: $editValue)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                Section {
                    Button("保存") { saveEditedVar() }
                    Button("キャンセル", role: .cancel) { showVarSheet = false }
                }
            }
            .navigationTitle("変数の編集")
        }
    }
    
    // ---- ロジック/ユーティリティ ----
    func lastIdentifierIn(_ s: String) -> Range<String.Index>? {
        // 正規表現を使わず末尾から走査（プレビューでの落下要因を排除）
        func isIdStart(_ c: Character) -> Bool { VKEngine.idStart(c) }
        func isIdCont(_ c: Character)  -> Bool { VKEngine.idCont(c)  }
        var i: String.Index = s.endIndex
        var start: String.Index = i
        var seen: Bool = false
        while i > s.startIndex {
            let j: String.Index = s.index(before: i)
            let c: Character = s[j]
            if isIdCont(c) { start = j; seen = true; i = j }
            else { break }
        }
        if seen && start < s.endIndex && isIdStart(s[start]) { return start..<s.endIndex }
        return nil
    }
    
    func clearAll() -> Void { expr = ""; resultText = "—" }
    
    func scopeNumeric() -> [String: Double] {
        var m: [String: Double] = [:]
        for (k, v) in store.db.items where v.type == "number" { m[k] = v.value }
        return m
    }
    
    func doCalc() -> Void {
        do {
            let e: String = expr.isEmpty ? "0" : expr
            let val: Double = try VKEngine.eval(e, scope: scopeNumeric())
            resultText = trimDouble(val)
        } catch {
            presentCalcError(error)
        }
    }
    
    func presentError(_ msg: String, hints: [String] = []) -> Void {
        errorMsg = msg; errorHints = hints; showError = true
    }
    
    func presentCalcError(_ e: Error) -> Void {
        let raw: String = e.localizedDescription
        var hints: [String] = []
        if raw.contains("括弧が不一致") { hints.append("かっこは（ と ）のペアになっていますか？") }
        if raw.contains("構文エラー") || raw.contains("オペランド不足") { hints.append("演算子の連続や先頭/末尾の記号に注意してください。") }
        if raw.contains("未定義の変数") { hints.append("その名前の変数は保存されていますか？（数値として登録されていますか？）") }
        if raw.contains("数値ではありません") { hints.append("0で割っていませんか？または無効な計算になっていませんか？") }
        if raw.contains("使用できない文字") { hints.append("使える記号は +, -, *, /, %, ** と () のみです。") }
        if hints.isEmpty { hints.append("全角/半角が混ざっていないか確認してください。") }
        presentError(raw, hints: hints)
    }
    
    func saveFromInlinePlus() -> Void {
        do {
            let name: String = inlineName.trimmingCharacters(in: .whitespaces)
            try validateName(name)
            let value: Double = try VKEngine.eval(expr.isEmpty ? "0" : expr, scope: scopeNumeric())
            guard store.upsert(name: name, value: value) else {
                presentError("無料/現在のプランでは変数を \(store.db.meta.slots) 個まで保存できます。")
                return
            }
            inlineName = ""
            clearAll()
        } catch {
            presentCalcError(error)
        }
    }
    
    func validateName(_ name: String) throws -> Void {
        if name.isEmpty { throw VKCalcError.syntax("変数名を入力してください。") }
        // 正規表現なしで簡易チェック：先頭=Start、以降=Cont
        guard let f: Character = name.first, VKEngine.idStart(f) else {
            throw VKCalcError.syntax("変数名が不正です。日本語を含む文字で始め、以降は文字・数字・_ のみ。")
        }
        for c in name.dropFirst() {
            if !VKEngine.idCont(c) {
                throw VKCalcError.syntax("変数名が不正です。日本語を含む文字で始め、以降は文字・数字・_ のみ。")
            }
        }
    }
    
    func saveEditedVar() -> Void {
        do {
            try validateName(editName)
            let value: Double = try VKEngine.eval(editValue, scope: scopeNumeric())
            guard store.upsert(name: editName, value: value) else {
                presentError("無料/現在のプランでは変数を \(store.db.meta.slots) 個まで保存できます。")
                return
            }
            showVarSheet = false
        } catch {
            presentCalcError(error)
        }
    }
    
    func sortedNumberEntries() -> [(name: String, value: Double)] {
        let arr: [(name: String, value: Double)] =
        store.db.items
            .filter { (kv: (key: String, value: VKItem)) -> Bool in kv.value.type == "number" }
            .map { (kv: (key: String, value: VKItem)) -> (name: String, value: Double) in (kv.key, kv.value.value) }
            .sorted { (a: (name: String, value: Double), b: (name: String, value: Double)) -> Bool in
                a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        return arr
    }
    
    func sortedByUpdated() -> [(name: String, value: Double, updatedAt: TimeInterval)] {
        let arr: [(name: String, value: Double, updatedAt: TimeInterval)] =
        store.db.items
            .map { (kv: (key: String, value: VKItem)) -> (name: String, value: Double, updatedAt: TimeInterval) in
                (kv.key, kv.value.value, kv.value.updatedAt)
            }
            .sorted { (a, b) -> Bool in a.updatedAt > b.updatedAt }
        return arr
    }
    
    func trimDouble(_ v: Double) -> String {
        var s: String = String(v)
        if s.contains(".") {
            while s.last == "0" { _ = s.popLast() }
            if s.last == "." { _ = s.popLast() }
        }
        return s
    }
    
    func dateString(from t: TimeInterval) -> String {
        return ContentView.df.string(from: Date(timeIntervalSince1970: t))
    }
    
    func copyToPasteboard(_ s: String) -> Void {
        guard !FORCE_SAFE_MODE else { return }  // セーフモードでは何もしない
#if canImport(UIKit)
        UIPasteboard.general.string = s
#endif
    }
}
