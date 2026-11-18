//
//  PandoraLoader.swift
//  TrollFools
//
//  脚本加载器：把一个 dylib（PandoraLoader）和选中的脚本一起部署到目标 App。
//
//  和普通的 dylib 注入只差一件事：脚本必须落在**目标沙盒**里，
//  因为 PdRootDir() 取的是被注入进程自己的 Documents：
//      <dataContainer>/Documents/Pandora/scripts/_manifest.json
//  注入端每秒比对 _manifest.json 的 ver，变了就重新加载 —— 所以改脚本
//  只要重写这个目录，不需要重新注入、不需要重启游戏。
//

import Darwin
import SwiftUI
import UIKit

// MARK: - 脚本模型

struct PandoraScript: Hashable, Identifiable {
    let name: String
    let size: Int

    var id: String { name }

    var url: URL {
        PandoraScriptStore.shared.scriptsURL.appendingPathComponent(name)
    }

    /// js / pjs / lua —— 决定用哪个运行时，也决定同一个 App 能不能混选。
    var lang: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "lua": return "lua"
        case "pjs": return "pjs"
        default: return "js"
        }
    }

    var langTitle: String {
        switch lang {
        case "lua": return "Lua"
        case "pjs": return "PuerTS"
        default: return "JSC"
        }
    }

    var langHint: String {
        switch lang {
        case "lua": return "自带 Lua 5.4（需打包时内置）"
        case "pjs": return "跑在游戏自己的 PuerTS 里，能用 CS.*"
        default: return "自带 JavaScriptCore，隔离但拿不到 Unity API"
        }
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - 脚本仓库

final class PandoraScriptStore {
    static let shared = PandoraScriptStore()

    /// 与 Stash 同级：/var/mobile/Library/TrollFools/Pandora
    ///
    /// 必须 resolvingSymlinksInPath()：iOS 上 /var 是 /private/var 的软链，
    /// 目录枚举返回 /private/var/... 形态，不解析会让"前缀剔除"错位（同 StashManager）。
    static let rootURL = URL(fileURLWithPath: "/var/mobile/Library/TrollFools/Pandora")
        .resolvingSymlinksInPath()

    var scriptsURL: URL {
        Self.rootURL.appendingPathComponent("Scripts", isDirectory: true)
    }

    private var bindingsURL: URL {
        Self.rootURL.appendingPathComponent("bindings.json")
    }

    private var fm: FileManager { FileManager.default }

    private init() {
        try? fm.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
        seedStarterIfNeeded()
    }

    /// 第一次用的时候放一个能直接跑通的示例。
    /// 只做一次（UserDefaults 打标），删掉之后不会被反复重建。
    private func seedStarterIfNeeded() {
        let key = "shiliu.pandora.starterSeeded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let existing = (try? fm.contentsOfDirectory(atPath: scriptsURL.path)) ?? []
        let hasAny = existing.contains {
            ["js", "lua", "pjs"].contains(($0 as NSString).pathExtension.lowercased())
        }
        guard !hasAny else { return }
        try? write(Self.template(for: "demo.js"), to: "demo.js")
    }

    // MARK: 列表

    func allScripts() -> [PandoraScript] {
        guard let names = try? fm.contentsOfDirectory(atPath: scriptsURL.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .filter { ["js", "lua", "pjs"].contains(($0 as NSString).pathExtension.lowercased()) }
            .map {
                PandoraScript(
                    name: $0,
                    size: StashManager.fileSize(of: scriptsURL.appendingPathComponent($0))
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func script(named name: String) -> PandoraScript? {
        allScripts().first { $0.name == name }
    }

    // MARK: 导入 / 删除 / 编辑

    struct ImportReport {
        var imported: [String] = []
        var skipped: [String] = []
        var isEmpty: Bool { imported.isEmpty && skipped.isEmpty }
    }

    /// 只收 .js / .lua / .pjs。重名按内容覆盖（同名同大小直接跳过）。
    @discardableResult
    func importScripts(from urls: [URL], securityScoped: Bool = true) -> ImportReport {
        var report = ImportReport()
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ["js", "lua", "pjs"].contains(ext) else {
                report.skipped.append("\(url.lastPathComponent)（只收 .js / .lua / .pjs）")
                continue
            }

            let scoped = securityScoped && url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let name = StashManager.normalizedPluginName(url.lastPathComponent)
            let dst = scriptsURL.appendingPathComponent(name)

            if fm.fileExists(atPath: dst.path),
               StashManager.contentSignature(of: dst) == StashManager.contentSignature(of: url)
            {
                report.skipped.append("\(name)（内容没变）")
                continue
            }

            do {
                try StashManager.atomicCopy(from: url, to: dst)
                report.imported.append(name)
            } catch {
                report.skipped.append("\(name)（\(error.localizedDescription)）")
            }
        }
        return report
    }

    func remove(_ name: String) {
        try? fm.removeItem(at: scriptsURL.appendingPathComponent(name))
        // 绑定里的名字也要清掉，否则下次部署会因为"绑了但文件不在"而报错
        let affected = bindings().filter { $0.value.contains(name) }.map(\.key)
        for bid in affected {
            var pick = Set(bindings()[bid] ?? [])
            pick.remove(name)
            setSelection(pick.isEmpty ? nil : pick, bid: bid)
        }
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: scriptsURL.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func write(_ text: String, to name: String) throws {
        let dst = scriptsURL.appendingPathComponent(name)
        guard let data = text.data(using: .utf8) else { return }
        try data.write(to: dst, options: .atomic)
    }

    /// 新建一个空脚本，返回最终文件名（重名自动加序号）。
    func create(name rawName: String, lang: String) -> String {
        var base = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "script" }
        let ext = (base as NSString).pathExtension.lowercased()
        if !["js", "lua", "pjs"].contains(ext) {
            base += ".\(lang == "lua" ? "lua" : (lang == "pjs" ? "pjs" : "js"))"
        }

        var candidate = base
        var i = 2
        let nsBase = (base as NSString).deletingPathExtension
        let nsExt = (base as NSString).pathExtension
        while fm.fileExists(atPath: scriptsURL.appendingPathComponent(candidate).path) {
            candidate = "\(nsBase)-\(i).\(nsExt)"
            i += 1
        }
        try? write(PandoraScriptStore.template(for: candidate), to: candidate)
        return candidate
    }

    static func template(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "lua":
            return """
            -- \(name) · PandoraLoader
            -- 可用：print / Native.log / onTick / onUnload

            local n = 0
            function onTick(dt)
                n = n + 1
                if n % 60 == 0 then
                    print("lua tick " .. n)
                end
            end

            function onUnload()
                print("lua unload")
            end
            """
        case "pjs":
            return """
            // \(name) · PandoraLoader（跑在游戏自己的 PuerTS 里）
            // 这里的 CS.* 是游戏提供的，不需要任何桥。
            // 控制台输出会写到游戏沙盒 Documents/Pandora/js.log，自动转发到日志页。

            var U = CS.UnityEngine;
            var n = 0;

            onTick(function (dt) {
                n++;
                if (n % 60 === 0) console.log("pjs tick " + n);
            });

            onUnload(function () {
                console.log("pjs unload");
            });
            """
        default:
            return """
            // \(name) · PandoraLoader
            // 自建 JavaScriptCore：没有 CS.*，但有 console / setTimeout / onTick。

            var n = 0;

            onTick(function (dt) {
                n++;
                if (n % 60 === 0) console.log("js tick " + n);
            });

            onUnload(function () {
                console.log("js unload");
            });
            """
        }
    }

    // MARK: 每个 App 的绑定

    private func bindings() -> [String: [String]] {
        guard let data = try? Data(contentsOf: bindingsURL),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return map
    }

    /// nil = 没绑定（表示"该 App 用全部脚本"）。
    func selection(bid: String) -> Set<String>? {
        guard let list = bindings()[bid] else { return nil }
        return Set(list)
    }

    func setSelection(_ names: Set<String>?, bid: String) {
        var map = bindings()
        if let names, !names.isEmpty {
            map[bid] = names.sorted()
        } else {
            map.removeValue(forKey: bid)
        }
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: bindingsURL, options: .atomic)
        }
    }

    // MARK: 实际生效的脚本

    /// 加载器只按 **第一个文件的 lang** 起运行时（见 PdClient -applyFiles:），
    /// 所以同一个 App 里混 js/pjs/lua 一定出错。这里统一收口：
    /// 显式绑定优先；没绑定就挑数量最多的那一组（平局 pjs > js > lua）。
    func effectiveScripts(bid: String) -> [PandoraScript] {
        let all = allScripts()
        if let pick = selection(bid: bid) {
            let chosen = all.filter { pick.contains($0.name) }
            if !chosen.isEmpty { return normalize(chosen) }
        }
        let groups = Dictionary(grouping: all, by: \.lang)
        let best = groups.max { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return Self.rank(lhs.key) < Self.rank(rhs.key)
        }
        guard let list = best?.value else { return [] }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 跨语言时只保留第一组的语言，其余剔除（UI 里会提示）。
    func normalize(_ list: [PandoraScript]) -> [PandoraScript] {
        guard let lang = list.first?.lang else { return [] }
        return list.filter { $0.lang == lang }
    }

    private static func rank(_ lang: String) -> Int {
        switch lang {
        case "pjs": return 3
        case "js": return 2
        case "lua": return 1
        default: return 0
        }
    }
}

// MARK: - 部署

enum PandoraLoader {
    static let dylibName = "PandoraLoader.dylib"

    /// 内置 payload：打包时放在 .app 根目录（和 insert_dylib / ldid 那些工具同级）。
    /// 找不到就退回暂存箱里的同名文件，方便不重新打包也能换版本。
    static func payloadURL() -> URL? {
        if let url = Bundle.main.url(forResource: "PandoraLoader", withExtension: "dylib"),
           FileManager.default.isReadableFile(atPath: url.path)
        {
            return url
        }
        if let first = ProcessInfo.processInfo.arguments.first {
            let sibling = URL(fileURLWithPath: first)
                .deletingLastPathComponent()
                .appendingPathComponent(dylibName)
            if FileManager.default.isReadableFile(atPath: sibling.path) {
                return sibling
            }
        }
        let stashed = StashManager.stashRootURL.appendingPathComponent(dylibName)
        if FileManager.default.isReadableFile(atPath: stashed.path) {
            return stashed
        }
        return nil
    }

    static var isAvailable: Bool { payloadURL() != nil }

    /// 目标 App 的数据容器。
    ///
    /// LSApplicationProxy 的 dataContainerURL 对"从没启动过"的 App 会给 nil
    /// （容器还没被创建）。这时扫一遍容器根目录的元数据兜底 —— TrollFools
    /// 带 com.apple.private.MobileContainerManager.lookup，读得到别人的容器。
    static func dataContainerURL(bid: String) -> URL? {
        if let proxy = LSApplicationProxy(forIdentifier: bid),
           let url = proxy.dataContainerURL(),
           url.path.count > 1,
           FileManager.default.fileExists(atPath: url.path)
        {
            return url
        }

        let root = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for dir in dirs {
            let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: meta),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any],
                  let ident = dict["MCMMetadataIdentifier"] as? String,
                  ident == bid
            else { continue }
            return dir
        }
        return nil
    }

    /// 把脚本写进目标沙盒的 Documents/Pandora/scripts/ 并生成 _manifest.json。
    ///
    /// - 版本号用秒级时间戳：单调递增，注入端每轮询一次就能看出变化。
    /// - 目录里不在本次名单的旧脚本会被删掉，否则加载器会把上次残留的也执行一遍。
    @discardableResult
    static func stageScripts(_ scripts: [PandoraScript], dataContainer: URL) throws -> Int {
        let fm = FileManager.default
        let dir = dataContainer.appendingPathComponent("Documents/Pandora/scripts", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var entries: [[String: Any]] = []
        for script in scripts {
            let dst = dir.appendingPathComponent(script.name)
            let data = try Data(contentsOf: script.url)
            try data.write(to: dst, options: .atomic)
            entries.append([
                "name": script.name,
                "lang": script.lang,
                "size": data.count,
            ])
        }

        let keep = Set(scripts.map(\.name))
        if let old = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in old where !name.hasPrefix(".") && name != "_manifest.json" && !keep.contains(name) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }

        let manifest: [String: Any] = [
            "ver": String(Int(Date().timeIntervalSince1970)),
            "files": entries,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appendingPathComponent("_manifest.json"), options: .atomic)

        return scripts.count
    }

    /// 只清脚本，不动 dylib。用于「还原」之后收拾残局。
    static func clearScripts(dataContainer: URL) {
        let dir = dataContainer.appendingPathComponent("Documents/Pandora/scripts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - UI：脚本列表（供注入页嵌入）

final class PandoraScriptModel: ObservableObject {
    @Published var scripts: [PandoraScript] = []
    @Published var selected: Set<String> = []

    /// 同一个 App 只能有一种语言，见 PandoraScriptStore.effectiveScripts。
    var mixedWarning: String? {
        let langs = Set(scripts.filter { selected.contains($0.name) }.map(\.lang))
        guard langs.count > 1 else { return nil }
        return "选中的脚本语言不一致（\(langs.sorted().joined(separator: " / "))）。加载器按第一个文件的语言起运行时，其余会被跳过。"
    }

    func reload(bid: String?) {
        scripts = PandoraScriptStore.shared.allScripts()
        if let bid {
            selected = PandoraScriptStore.shared.selection(bid: bid) ?? []
            // 绑了但文件已经不在的条目，属于脏数据，顺手清掉
            let alive = Set(scripts.map(\.name))
            selected = selected.intersection(alive)
        } else {
            selected = []
        }
    }

    /// 点选。跨语言时把另一种语言的全部取消 —— 与其让用户选完再报错，
    /// 不如在点击这一下就把状态收敛掉。
    func toggle(_ script: PandoraScript, bid: String?) {
        if selected.contains(script.name) {
            selected.remove(script.name)
        } else {
            let others = scripts.filter { selected.contains($0.name) && $0.lang != script.lang }
            for other in others { selected.remove(other.name) }
            selected.insert(script.name)
        }
        if let bid {
            PandoraScriptStore.shared.setSelection(selected.isEmpty ? nil : selected, bid: bid)
        }
    }
}

// MARK: - UI：脚本编辑

/// sheet(item:) 要求 Identifiable，String 不满足，用一个壳包一层。
struct PandoraEditorTarget: Identifiable {
    let name: String
    var id: String { name }
}

struct PandoraEditorView: View {
    let name: String
    @State private var text: String = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            PandoraTextEditor(text: $text)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { presentationMode.wrappedValue.dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            try? PandoraScriptStore.shared.write(text, to: name)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            text = PandoraScriptStore.shared.read(name)
        }
    }
}

private struct PandoraTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: PandoraTextEditor

        init(_ parent: PandoraTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
