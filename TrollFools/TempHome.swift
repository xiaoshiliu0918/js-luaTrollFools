//
//  TempHome.swift
//  TrollFools
//
//  Minimal temp-injection launcher:
//  permanent plugin stash + one-tap game launch with auto inject & auto restore.
//

import SwiftUI
import UIKit
import CoreServices
import UniformTypeIdentifiers

// MARK: - Alert item (iOS 14 compatible)

struct TempAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Game Targets

struct GameTarget {
    let buttonTitle: String
    let emoji: String
    /// keywords matched against plugin file names in the stash
    let pluginKeywords: [String]
    /// keywords matched against installed app display names
    let appNameKeywords: [String]
    /// optional hard-coded bundle identifier (checked first)
    let fixedBundleID: String?

    static let wzry = GameTarget(
        buttonTitle: "启动王者荣耀",
        emoji: "👑",
        pluginKeywords: ["王者", "王者荣耀", "wzry", "smoba"],
        appNameKeywords: ["王者", "smoba"],
        fixedBundleID: "com.tencent.smoba"
    )

    static let dnf = GameTarget(
        buttonTitle: "启动地下城与勇士",
        emoji: "⚔️",
        pluginKeywords: ["地下城", "dnf", "DNF"],
        appNameKeywords: ["地下城", "dnf", "DNF"],
        fixedBundleID: nil
    )
}

// MARK: - Stash

final class StashManager {
    static let shared = StashManager()

    /// 必须解析符号链接：iOS 上 /var 是 /private/var 的软链，目录枚举器
    /// 返回的是 /private/var/... 形态；若根仍是 /var/...，"根前缀剔除"会错位，
    /// 把绝对路径后缀（如 "ts/插件导入"、"s/Stash"）当成相对路径 → 嵌套污染。
    /// 只解析一次：`resolvingSymlinksInPath()` 每次都走文件系统，
    /// 而 listDeep / category(ofPluginAt:) 会在循环里反复调用它。
    static let stashRootURL: URL = URL(fileURLWithPath: "/var/mobile/Library/TrollFools/Stash")
        .resolvingSymlinksInPath()

    /// 导入结果：新导入 / 覆盖更新 / 同名同大小跳过。
    enum ImportOutcome {
        case imported
        case updated
        case skipped
    }

    // MARK: 双向镜像快照
    // 「插件导入」文件夹 ⇄ 暂存箱 双向同步的状态依据：
    /// iOS 文件 App 复制重名文件时会自动生成 "Name (2).ext" / "Name(2).ext"。
    /// 把这类名字折叠回 "Name.ext"，避免同一插件因重复复制产生多个副本。
    static func normalizedPluginName(_ rawName: String) -> String {
        let nsName = rawName as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        if let range = base.range(of: #"\s*\(\d+\)\s*$"#, options: .regularExpression) {
            let stripped = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty {
                return ext.isEmpty ? stripped : "\(stripped).\(ext)"
            }
        }
        return rawName
    }

    static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    /// 内容指纹，用于判断“要不要重新同步”。
    ///
    /// 为什么不能只比 size：
    /// - 重新编译出来的 dylib 体积恰好相同很常见，只比 size 会永远判等、更新永远同步不过去；
    /// - `.framework` / `.bundle` 是目录，`fileSizeKey` 返回的是目录项自身大小（通常 64~4096 字节），
    ///   内部换了多少个文件都看不出来。
    /// 所以目录走递归聚合（文件数 + 总字节 + 最新修改时间）。
    static func contentSignature(of url: URL) -> String {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return "missing"
        }
        if !isDirectory.boolValue {
            let size = fileSize(of: url)
            let mtime = modificationDate(of: url)?.timeIntervalSince1970 ?? 0
            return "f:\(size):\(Int(mtime))"
        }
        var count = 0
        var total = 0
        var latest: TimeInterval = 0
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        ) {
            for case let child as URL in enumerator {
                let values = try? child.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
                )
                if values?.isDirectory == true { continue }
                count += 1
                total += values?.fileSize ?? 0
                latest = max(latest, values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return "d:\(count):\(total):\(Int(latest))"
    }

    /// 目标卷可用空间（字节）；取不到时返回 nil（调用方按“够用”处理）。
    static func availableBytes(at url: URL) -> Int64? {
        let probe = url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// 估算一个条目需要多少空间（目录递归求和）。
    static func byteSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64(max(0, fileSize(of: url)))
        }
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            for case let child as URL in enumerator {
                let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values?.isDirectory == true { continue }
                total += Int64(max(0, values?.fileSize ?? 0))
            }
        }
        return total
    }

    /// 原子替换式拷贝：先写同目录临时文件（以 "." 开头，同步扫描会跳过），
    /// 成功后一次 rename 覆盖目标。
    ///
    /// 旧写法是“先删目标、再 copyItem 到目标名”，两个后果：
    /// 1. 拷贝中途失败（空间不足/权限）→ 目标位置留下半个文件，它会被当成插件注入，
    ///    目标 App 下次启动直接 dyld 崩溃；
    /// 2. 删了旧文件但新文件没写成 → 原本可用的插件也没了。
    static func atomicCopy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let required = byteSize(of: src)
        if required > 0, let available = availableBytes(at: dst), available < required + 64 * 1024 * 1024 {
            let needMB = Double(required) / 1_048_576
            let freeMB = Double(available) / 1_048_576
            throw NSError(
                domain: "StashSync", code: -2,
                userInfo: [NSLocalizedDescriptionKey: String(
                    format: "空间不足：需要 %.1f MB，可用 %.1f MB", needMB, freeMB
                )]
            )
        }

        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".sync-\(UUID().uuidString)")
        let backup = dst.deletingLastPathComponent()
            .appendingPathComponent(".old-\(UUID().uuidString)")
        try? fm.removeItem(at: tmp)

        do {
            try fm.copyItem(at: src, to: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        // 先把旧版本挪到隐藏名（扫描会跳过 "." 开头的条目），再 rename 新版上位；
        // 任何一步失败都能把旧版本挪回来，不会出现“旧的删了、新的没成”。
        let hadExisting = fm.fileExists(atPath: dst.path)
        if hadExisting {
            do {
                try fm.moveItem(at: dst, to: backup)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
        }
        do {
            try fm.moveItem(at: tmp, to: dst)
            // 保持与源一致的修改时间：指纹里带了 mtime，若拷贝后 mtime 变了，
            // 下一轮同步会认为“内容又变了”，每次都整盘重拷（大 framework 极慢）。
            if let mtime = modificationDate(of: src) {
                try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dst.path)
            }
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.removeItem(at: tmp)
            if hadExisting {
                try? fm.moveItem(at: backup, to: dst)
            }
            throw error
        }
    }

    /// 分块流式拷贝：替代 `Data(contentsOf:)` 整文件读内存的兜底路径。
    /// 几百 MB 的 framework 走 `Data(contentsOf:)` 会直接把进程顶到内存上限。
    static func streamCopy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard let input = try? FileHandle(forReadingFrom: src) else {
            throw NSError(domain: "StashImport", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取源文件"])
        }
        defer { try? input.close() }

        fm.createFile(atPath: dst.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: dst) else {
            throw NSError(domain: "StashImport", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入目标文件"])
        }
        defer { try? output.close() }

        let chunkSize = 4 * 1024 * 1024
        while let chunk = try? input.read(upToCount: chunkSize), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }

    func ensureStash() {
        try? FileManager.default.createDirectory(
            at: Self.stashRootURL, withIntermediateDirectories: true
        )
    }

    /// All plugin files currently in the stash (dylib / framework / bundle).
    func listPlugins() -> [URL] {
        ensureStash()
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: Self.stashRootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Import one file into the stash (dedup version).
    /// - 同名且同大小的文件已在暂存箱 → .skipped（不覆盖、不重复导入）
    /// - 同名但内容不同 → 覆盖更新 → .updated
    /// - 新文件 → .imported
    /// - "Name(2).ext" 这类文件 App 复制副本名会被折叠回 "Name.ext"
    @discardableResult
    func importPluginDedup(from src: URL) throws -> (name: String, outcome: ImportOutcome) {
        ensureStash()
        let fm = FileManager.default
        let name = Self.normalizedPluginName(src.lastPathComponent)
        let dst = Self.stashRootURL.appendingPathComponent(name)

        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let srcSize = Self.fileSize(of: src)

        // 暂存箱已有同名且同大小的文件：跳过
        if fm.fileExists(atPath: dst.path), srcSize >= 0 {
            let dstSize = Self.fileSize(of: dst)
            if dstSize == srcSize {
                return (name, .skipped)
            }
        }

        let hadExisting = fm.fileExists(atPath: dst.path)
        if hadExisting {
            try? fm.removeItem(at: dst)
        }

        var reasons: [String] = []

        // Strategy 1: direct copy
        if !fm.fileExists(atPath: dst.path) {
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                reasons.append("copy:\(error.localizedDescription)")
            }
        }

        // Strategy 2: chunked stream copy
        // 旧写法是 `Data(contentsOf: src)` 整文件读进内存，几百 MB 的 framework
        // 会直接把进程顶到内存上限（Jetsam）。改成 4MB 分块流式读写。
        if !fm.fileExists(atPath: dst.path) {
            do {
                try Self.streamCopy(from: src, to: dst)
            } catch {
                reasons.append("stream:\(error.localizedDescription)")
            }
        }

        // Verify
        guard fm.fileExists(atPath: dst.path) else {
            throw NSError(
                domain: "StashImport", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "所有方式均失败（\(reasons.joined(separator: "；"))）。源路径：\(src.path)"]
            )
        }

        // 成功导入，保持镜像状态一致（无墓碑机制，删除由双向同步处理）
        return (name, hadExisting ? .updated : .imported)
    }

    /// Import one file into the stash. Returns the stored file name.
    /// (兼容旧调用点；内部走去重逻辑)
    @discardableResult
    func importPlugin(from src: URL) throws -> String {
        try importPluginDedup(from: src).name
    }

    /// 从暂存箱删除插件。
    /// 「插件导入」文件夹里的同名文件由双向同步负责删除。
    /// 从暂存箱删除插件。暂存箱是「插件导入」文件夹的单向镜像，
    /// 因此同时删除文件夹里的对应文件（同相对路径），否则下次同步又会被收回来。
    func removePlugin(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        let root = Self.stashRootURL.path + "/"
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return }
        let rel = String(path.dropFirst(root.count))
        // rel 为空意味着 url 就是暂存箱根目录本身：绝不能拿它去删导入文件夹的根。
        guard !rel.isEmpty else { return }
        let mirror = ImportEngine.importFolderURL.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: mirror.path) {
            try? FileManager.default.removeItem(at: mirror)
        }
    }

    // MARK: 深度列举（支持子文件夹分类）

    /// 暂存箱/导入文件夹内的一项（文件或目录），relPath 相对根目录，
    /// 例如 "DNF.dylib"、"王者荣耀/DNF.dylib"。
    struct DeepItem {
        let relPath: String
        let url: URL
        let isDirectory: Bool
    }

    /// 递归列举目录下所有文件与子目录（跳过点文件），按相对路径排序。
    func listDeep(at root: URL? = nil) -> [DeepItem] {
        var rootURL = root ?? Self.stashRootURL
        if root != nil {
            // 只有外部传入的根需要解析；默认根已经是解析过的静态值。
            rootURL = rootURL.resolvingSymlinksInPath()
        }
        ensureStash()
        let fm = FileManager.default
        let rootPath = rootURL.path
        var result: [DeepItem] = []
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            var path = url.path
            if !path.hasPrefix(rootPath + "/") {
                path = url.resolvingSymlinksInPath().path
            }
            guard path.hasPrefix(rootPath + "/") else {
                enumerator.skipDescendants()
                continue
            }
            let rel = String(path.dropFirst(rootPath.count + 1))
            if rel.isEmpty { continue }
            let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            result.append(DeepItem(relPath: rel, url: url, isDirectory: isDir))
        }
        result.sort { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
        return result
    }

    /// 只列出「插件条目」：dylib/zip/deb 文件与 .framework/.bundle 目录。
    /// 插件 bundle（.framework/.bundle）内部的文件不单独列出；
    /// 分类子文件夹（非插件目录）本身也不是条目。
    func listPluginItems(at root: URL? = nil) -> [DeepItem] {
        listDeep(at: root).filter { item in
            if item.isDirectory {
                let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
                return Self.pluginBundleExtensions.contains(ext)
            }
            // 文件：扩展名须为插件类型，且不在插件 bundle 内部
            let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
            guard Self.pluginFileExtensions.contains(ext) else { return false }
            let ancestors = item.relPath.split(separator: "/").dropLast().map(String.init)
            return !ancestors.contains {
                Self.pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }
        }
    }

    /// 某插件文件所属的分类名（暂存箱根下的第一级子文件夹名；根目录文件 = 未分类）。
    static func category(ofPluginAt url: URL) -> String {
        // stashRootURL 已经是解析过符号链接的静态值，不必每次再走一遍文件系统；
        // 只有调用方传进来的 url 形态对不上时才做一次解析（listDeep/reload 会
        // 对每个插件调用本函数，逐个 resolvingSymlinksInPath 是纯浪费）。
        let root = stashRootURL.path + "/"
        var path = url.path
        if !path.hasPrefix(root) {
            path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { return "未分类" }
        }
        let rel = String(path.dropFirst(root.count))
        let parts = rel.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : "未分类"
    }

    // MARK: 插件类型判定
    // 只有这些类型会被当作插件：dylib / framework / bundle / zip / deb。
    // 分类子文件夹仅用于归类，其内部仍只收上述类型；
    // 其他任意文件（txt/png 等）不参与同步、不进暂存箱。

    static let pluginFileExtensions: Set<String> = ["dylib", "zip", "deb"]
    static let pluginBundleExtensions: Set<String> = ["framework", "bundle"]

    /// 判断一个相对路径是否为插件（或插件 bundle 内部的组成部分）。
    /// - 顶层/任意层级文件：扩展名为 dylib/zip/deb
    /// - .framework / .bundle 目录本身及其内部所有内容
    static func isPluginPath(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/").map(String.init)
        guard let last = parts.last else { return false }
        // 位于插件 bundle 内部 → 属于插件的一部分
        if parts.count > 1 {
            let ancestors = parts.dropLast()
            if ancestors.contains(where: {
                pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }) {
                return true
            }
        }
        let ext = (last as NSString).pathExtension.lowercased()
        return pluginFileExtensions.contains(ext) || pluginBundleExtensions.contains(ext)
    }

    /// Plugins whose file name (only the file itself, not its category
    /// folder path) contains any of the keywords.
    /// 分类文件夹仅用于视觉归类，不参与一键启动匹配；匹配只看插件文件名。
    func plugins(matching keywords: [String]) -> [URL] {
        listPluginItems().filter { item in
            let name = item.url.lastPathComponent.lowercased()
            return keywords.contains { name.contains($0.lowercased()) }
        }.map { $0.url }
    }
}

// MARK: - 单侧扫描结果

/// 镜像同步时对一侧目录的扫描结果。
/// `ok == false` 表示枚举器创建失败（目录不存在/不可访问），
/// 此时绝不能把它当成“目录为空”，否则会清空另一侧。
private struct StashSideScan {
    var files: [String: URL] = [:]
    var dirs: Set<String> = []
    var ok = false
    /// 因路径形态异常/根嵌套而整棵跳过的子树数量（>0 时禁止删除）
    var skipped = 0
}

// MARK: - Import Engine (multi-channel, always visible on screen)

final class ImportEngine: ObservableObject {

    static let shared = ImportEngine()

    /// On-screen log lines, newest last. Rendered in the UI so results are
    /// always visible even if system alerts fail to present.
    @Published var logs: [String] = []
    /// 单调递增的日志版本号。
    /// 不能拿 `logs.count` 当变化信号：数组上限 40 条，写满之后 count 恒为 40，
    /// `onChange(of: logs.count)` 再也不会触发，界面就停在旧内容上不刷新了。
    @Published var logRevision: Int = 0
    @Published var notice: TempAlertItem?

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    func log(_ line: String) {
        DispatchQueue.main.async {
            self.logs.append("[\(self.stamp())] \(line)")
            if self.logs.count > 40 {
                self.logs.removeFirst(self.logs.count - 40)
            }
            self.logRevision &+= 1
        }
    }

    /// Import a batch of files. Safe to call from anywhere.
    func importURLs(_ urls: [URL], source: String, showAlert: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var ok: [String] = []
            var skipped: [String] = []
            var failures: [String] = []
            let fm = FileManager.default
            for url in urls {
                do {
                    // 一切以「插件导入」文件夹为准：外部导入（共享接收等）
                    // 先落进导入文件夹，再由单向同步收进暂存箱
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let name = StashManager.normalizedPluginName(url.lastPathComponent)
                    let dst = Self.importFolderURL.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) {
                        let oldSize = StashManager.fileSize(of: dst)
                        let newSize = StashManager.fileSize(of: url)
                        if oldSize >= 0, oldSize == newSize {
                            skipped.append(name)
                            continue
                        }
                        try? fm.removeItem(at: dst)
                    }
                    try fm.copyItem(at: url, to: dst)
                    ok.append(name)
                } catch {
                    failures.append("\(url.lastPathComponent)\n\(error.localizedDescription)")
                }
            }
            if !ok.isEmpty || !skipped.isEmpty {
                self.syncImportFolder()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for name in ok {
                    self.log("✅ \(source)：已导入 \(name)")
                }
                for name in skipped {
                    self.log("♻️ \(source)：\(name) 已在暂存箱，跳过")
                }
                for failure in failures {
                    self.log("❌ \(source)：\(failure)")
                }
                if showAlert {
                    if !failures.isEmpty {
                        self.notice = TempAlertItem(title: "导入失败", message: failures.joined(separator: "\n\n"))
                    } else if !ok.isEmpty {
                        var msg = ok.joined(separator: ", ")
                        if !skipped.isEmpty {
                            msg += "\n\n已存在跳过：\(skipped.joined(separator: ", "))"
                        }
                        self.notice = TempAlertItem(title: "已添加插件", message: msg)
                    } else if !skipped.isEmpty {
                        self.notice = TempAlertItem(title: "插件已存在", message: skipped.joined(separator: ", "))
                    }
                }
            }
        }
    }

    /// The user-visible import folder inside our own Documents, exposed via
    /// UIFileSharingEnabled so it shows up in the Files app
    /// (固定路径：/var/mobile/Documents/插件导入).
    static let importFolderURL: URL = {
        // 用户明确要求：导入文件夹固定为 /var/mobile/Documents/插件导入。
        // TrollStore 环境下 app 以 mobile 身份运行，可直接读写该全局目录；
        // 用户在文件 App / Filza 里往这里放插件、建分类文件夹，app 据此同步。
        // 若该位置不可写（非 TrollStore 安装），退回应用沙盒 Documents/插件导入。
        //
        // 只判定一次并缓存：这是“暂存箱的唯一权威根”，如果在运行期漂移
        // （某次探测失败退回沙盒），单向镜像会把整个暂存箱当成“文件夹里没有”而清空。
        let fm = FileManager.default
        let preferred = URL(fileURLWithPath: "/var/mobile/Documents/插件导入", isDirectory: true)
            .resolvingSymlinksInPath()
        try? fm.createDirectory(at: preferred, withIntermediateDirectories: true)
        if fm.isWritableFile(atPath: preferred.path) {
            return preferred
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("插件导入", isDirectory: true)
            .resolvingSymlinksInPath()
    }()

    static func ensureImportFolder() {
        try? FileManager.default.createDirectory(
            at: importFolderURL, withIntermediateDirectories: true
        )
    }

    /// 所有镜像动作串行化。
    /// 旧实现每次调用都扔到 global 队列：根页面 onAppear、暂存箱页 onAppear、
    /// 导入完成回调、日志变化都会各起一份，边拷边删互相踩。
    private static let syncQueue = DispatchQueue(label: "wiki.qaq.TrollFools.stash.sync")

    /// 记录上一次使用的导入根，用于识别“根漂移”。
    private static let importRootKey = "shiliu.importRoot"

    /// 「插件导入」文件夹 → 暂存箱 **单向**镜像同步（递归，支持子文件夹分类）。
    /// ★ 一切以 /var/mobile/Documents/插件导入 为准：
    ///   - 文件夹里有 → 暂存箱必须有（内容不同以文件夹覆盖）
    ///   - 文件夹里没有 → 暂存箱删除（app 内的内容绝不回灌进文件夹）
    ///   - 文件夹里的分类目录 → 暂存箱同步创建（空分类也建）
    /// - 只同步插件类型（dylib/zip/deb 文件与 .framework/.bundle 目录）
    /// - 文件 App 复制副本 "DNF(2).dylib" 自动并入正本 "DNF.dylib"（按目录内处理）
    /// - force = true（手动按钮）：忽略大小比对，全部重新复制一遍
    ///
    /// 安全闸门（删除是最危险的一步，任何一种“扫描不完整”都不允许删）：
    ///   1. 任一侧目录枚举失败 → 整轮放弃；
    ///   2. 导入根与上次不同（换了安装形态/权限）→ 只补齐、不删除；
    ///   3. 有路径形态对不上而跳过的子树 → 只补齐、不删除。
    func syncImportFolder(force: Bool = false) {
        Self.syncQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            Self.ensureImportFolder()
            StashManager.shared.ensureStash()

            let folderURL = Self.importFolderURL
            let stashURL = StashManager.stashRootURL

            // 根漂移检测：跨启动记住上次的权威根，变化时禁止删除。
            let previousRoot = UserDefaults.standard.string(forKey: Self.importRootKey)
            let rootChanged = (previousRoot != nil && previousRoot != folderURL.path)
            UserDefaults.standard.set(folderURL.path, forKey: Self.importRootKey)

            // 递归扫描一侧：返回 relPath → URL 的文件表 + 目录集合。
            // 双保险：枚举器返回的路径若与根前缀对不上（符号链接解析差异），
            // 先尝试标准化对齐；仍对不上则连同子树整体跳过，绝不生成碎片相对路径。
            func scan(_ root: URL, otherRoot: URL) -> StashSideScan {
                var result = StashSideScan()
                let rootPath = root.resolvingSymlinksInPath().path
                let otherPath = otherRoot.resolvingSymlinksInPath().path
                guard let enumerator = fm.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { return result }
                result.ok = true
                for case let url as URL in enumerator {
                    let name = url.lastPathComponent
                    if name.hasPrefix(".") {
                        enumerator.skipDescendants()
                        continue
                    }
                    var path = url.path
                    if !path.hasPrefix(rootPath + "/") {
                        path = url.resolvingSymlinksInPath().path
                    }
                    guard path.hasPrefix(rootPath + "/") else {
                        enumerator.skipDescendants() // 路径形态对不上：整棵子树跳过
                        result.skipped += 1
                        continue
                    }
                    if path.hasPrefix(otherPath + "/") {
                        enumerator.skipDescendants() // 对端根嵌套在本端内：整体跳过，防止互拷
                        result.skipped += 1
                        continue
                    }
                    let rel = String(path.dropFirst(rootPath.count + 1))
                    if rel.isEmpty { continue }
                    let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
                    if isDir { result.dirs.insert(rel) } else { result.files[rel] = url }
                }
                return result
            }

            var folderScan = scan(folderURL, otherRoot: stashURL)
            var stashScan = scan(stashURL, otherRoot: folderURL)

            // ── 安全闸门 ──
            guard folderScan.ok, stashScan.ok else {
                self.log("⏸ 同步已跳过：目录不可访问（插件导入/暂存箱），本轮不做任何删除")
                return
            }

            var allowDelete = true
            if rootChanged {
                allowDelete = false
                let from = previousRoot ?? "(无)"
                self.log("⚠️ 导入目录已变化：\(from) → \(folderURL.path)，本轮只补齐、不删除")
            }
            if folderScan.skipped > 0 || stashScan.skipped > 0 {
                allowDelete = false
                self.log("⚠️ 有 \(folderScan.skipped + stashScan.skipped) 棵子树路径异常已跳过，本轮不做删除")
            }

            // ── Step A-：清理历史版本遗留的"相对路径碎片"污染 ──
            // 症状：目录里出现 "ts/插件导入/…"、"s/Stash/…" 这类嵌套
            // （绝对路径后缀被当成相对路径复制）。
            // 只认这两种绝不会作为分类名出现在自己根下的目录名；不再使用
            // Documents / Library / var 这类常见名，避免误删用户自建分类。
            let pollutionNames: Set<String> = ["插件导入", "Stash"]
            func isPolluted(_ rel: String) -> Bool {
                rel.split(separator: "/").contains { pollutionNames.contains(String($0)) }
            }
            var cleanedCount = 0
            for (rootURL, scanResult) in [(folderURL, folderScan), (stashURL, stashScan)] {
                var removedPrefixes: [String] = []
                for rel in Set(scanResult.files.keys).union(scanResult.dirs).sorted() {
                    guard isPolluted(rel),
                          !removedPrefixes.contains(where: { rel.hasPrefix($0 + "/") }) else { continue }
                    try? fm.removeItem(at: rootURL.appendingPathComponent(rel))
                    removedPrefixes.append(rel)
                    cleanedCount += 1
                }
            }
            if cleanedCount > 0 {
                self.log("🧹 已清理路径污染残留 \(cleanedCount) 项（历史版本相对路径错位导致）")
                // 重新扫描，保证后续步骤基于干净状态
                folderScan = scan(folderURL, otherRoot: stashURL)
                stashScan = scan(stashURL, otherRoot: folderURL)
            }

            var folderFiles = folderScan.files
            let folderDirs = folderScan.dirs
            var stashFiles = stashScan.files
            let stashDirs = stashScan.dirs

            // ── Step A0：类型过滤——只有插件类型（dylib/zip/deb 文件与
            // .framework/.bundle 目录及其内部）参与同步。
            // 用户放在导入文件夹里的其他文件（笔记/图片等）保持原样，不进暂存箱。
            folderFiles = folderFiles.filter { StashManager.isPluginPath($0.key) }
            stashFiles = stashFiles.filter { StashManager.isPluginPath($0.key) }

            // 暂存箱里不应该有非插件文件（可能是历史版本同步进去的残留），清掉
            if allowDelete {
                for (rel, url) in stashScan.files where !StashManager.isPluginPath(rel) {
                    try? fm.removeItem(at: url)
                    self.log("🧹 已清理暂存箱内的非插件文件 \(rel)")
                }
            }

            // ── Step A：每个目录内做文件 App 复制副本规范化（DNF(2).dylib → DNF.dylib）──
            let folderByParent = Dictionary(grouping: folderFiles.keys) {
                ($0 as NSString).deletingLastPathComponent
            }
            for (parent, paths) in folderByParent {
                for path in paths.sorted() {
                    let raw = (path as NSString).lastPathComponent
                    let norm = StashManager.normalizedPluginName(raw)
                    guard norm != raw else { continue }
                    let normRel = parent.isEmpty ? norm : parent + "/" + norm
                    if let twinURL = folderFiles[normRel] {
                        // 正本存在：大小相同 → 副本是重复复制产生的，删除
                        let s1 = StashManager.fileSize(of: folderFiles[path]!)
                        let s2 = StashManager.fileSize(of: twinURL)
                        if s1 >= 0, s1 == s2 {
                            try? fm.removeItem(at: folderFiles[path]!)
                            folderFiles.removeValue(forKey: path)
                            self.log("♻️ 已合并重复副本 \(path) → \(normRel)")
                        }
                        // 大小不同 → 视为不同版本，保留原名当独立插件
                    } else {
                        // 没有正本：直接改名为正本名
                        let dstURL = folderURL.appendingPathComponent(normRel)
                        try? fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if (try? fm.moveItem(at: folderFiles[path]!, to: dstURL)) != nil {
                            folderFiles.removeValue(forKey: path)
                            folderFiles[normRel] = dstURL
                        }
                    }
                }
            }

            // ── Step B：单向镜像——一切以「插件导入」文件夹为准 ──
            var imported: [String] = []
            var updated: [String] = []
            var removed: [String] = []

            for rel in folderFiles.keys.sorted() {
                let src = folderFiles[rel]!
                let dst = stashURL.appendingPathComponent(rel)
                let existing = stashFiles[rel]
                let needCopy: Bool
                if let s = existing {
                    // 文件比 size+mtime，目录比递归指纹：
                    // 只比 size 会漏掉“同体积但内容更新”的插件，也会把整个 .framework
                    // 目录永远判成“没变化”（目录项大小不随内部文件变化）。
                    needCopy = force
                        || StashManager.contentSignature(of: src) != StashManager.contentSignature(of: s)
                } else {
                    needCopy = true
                }
                guard needCopy else { continue }
                do {
                    try? fm.createDirectory(
                        at: dst.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    // 原子替换：先写临时文件再 rename，拷一半失败不会留下半个插件，
                    // 也不会因为“先删后拷”把原本可用的旧版本弄丢。
                    try StashManager.atomicCopy(from: src, to: dst)
                    if existing == nil { imported.append(rel) } else { updated.append(rel) }
                } catch {
                    self.log("❌ 同步：\(rel) \(error.localizedDescription)")
                }
            }

            // 暂存箱里多出来的文件 = 文件夹里已不存在 → 删除（以文件夹为准，不回灌）
            // 删除前必须通过安全闸门：扫描不完整/根漂移时宁可留着，也不清空用户插件。
            if allowDelete {
                for rel in stashFiles.keys where folderFiles[rel] == nil {
                    try? fm.removeItem(at: stashURL.appendingPathComponent(rel))
                    removed.append(rel)
                }
            } else if !stashFiles.isEmpty, folderFiles.isEmpty {
                self.log("⏸ 导入文件夹当前为空，但本轮处于保护模式，暂存箱未清空")
            }

            // 目录对齐：文件夹里的目录 → 暂存箱同步创建（空分类也建）；
            // 暂存箱多出来的目录（含残留空分类）→ 删除
            for rel in folderDirs.sorted() {
                let dst = stashURL.appendingPathComponent(rel, isDirectory: true)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                }
            }
            if allowDelete {
                for rel in stashDirs.sorted() where !folderDirs.contains(rel) {
                    // 其内容已在上一步按文件级清空，这里移除目录本身
                    try? fm.removeItem(at: stashURL.appendingPathComponent(rel, isDirectory: true))
                }
            }

            if !imported.isEmpty || !updated.isEmpty || !removed.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !imported.isEmpty {
                        self.log("✅ 同步：已导入 \(imported.joined(separator: ", "))")
                    }
                    if !updated.isEmpty {
                        self.log("🔄 同步：已更新 \(updated.joined(separator: ", "))")
                    }
                    if !removed.isEmpty {
                        self.log("🗑 同步：已移除 \(removed.joined(separator: ", "))")
                    }
                    if !imported.isEmpty || !updated.isEmpty {
                        let names = (imported + updated).joined(separator: ", ")
                        self.notice = TempAlertItem(title: "同步完成", message: names)
                    }
                }
            }
        }
    }
}

// MARK: - Process kill helper

/// 注入前必须让目标处于未运行状态。
/// 这里按完整可执行文件路径匹配（`<Xxx>.app/<Executable>`），
/// 不再用 `p_comm`（内核截断 15 字节，Unity 系游戏几乎必然撞名）。
private func killRunningApp(bid: String) {
    guard let proxy = LSApplicationProxy(forIdentifier: bid),
          let bundleURL = proxy.bundleURL()
    else { return }

    // 绝不允许把自己杀掉
    if bundleURL.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path {
        return
    }

    let killed = ProcessUtil.killApp(at: bundleURL, signal: SIGKILL)
    if killed > 0 {
        ImportEngine.shared.log("⛔️ 已结束 \(killed) 个运行中的目标进程（\(bid)）")
    }

    // SIGKILL 只是投递信号，进程退出/内核回收映射需要一点时间。
    // 旧实现在调用点固定 sleep 0.5 秒，大型游戏常常还没退干净就开始改写
    // 主二进制；这里按实际存活状态轮询，最多等 5 秒。
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !ProcessUtil.pidsOfApp(at: bundleURL).isEmpty {
        Thread.sleep(forTimeInterval: 0.2)
    }
}

// MARK: - Injector orchestration

final class GameInjector: ObservableObject {

    static let shared = GameInjector()

    @Published var isWorking = false
    @Published var statusText: String = ""

    /// Resolve target app: fixed bid first, then display-name match.
    private func resolveApp(_ target: GameTarget) -> (bid: String, url: URL)? {
        if let bid = target.fixedBundleID,
           let proxy = LSApplicationProxy(forIdentifier: bid),
           let url = proxy.bundleURL() {
            return (bid, url)
        }
        let installed = LSApplicationWorkspace.default().allApplications() ?? []
        for kw in target.appNameKeywords {
            if let hit = installed.first(where: { proxy in
                (proxy.localizedName() ?? "").contains(kw) && proxy.bundleURL() != nil
            }) {
                guard let bid = hit.applicationIdentifier(), let url = hit.bundleURL() else { continue }
                return (bid, url)
            }
        }
        return nil
    }

    /// 通用临时注入：对任意 App 注入指定插件列表，然后跳转。
    /// - Parameters:
    ///   - appName: 用于日志与提示的显示名。
    ///   - bid: 目标 App 的 bundle identifier。
    ///   - bundleURL: 目标 App 的 bundle URL。
    ///   - plugins: 要注入的插件文件列表。
    ///   - scriptNames: 要一并部署的脚本名（PandoraScriptStore 里的文件名）。
    ///     非空时会自动追加 PandoraLoader.dylib，并把脚本写进目标沙盒。
    func injectAndLaunch(
        appName: String,
        bid: String,
        bundleURL: URL,
        plugins: [URL],
        scriptNames: [String]? = nil
    ) {
        guard !isWorking else { return }
        isWorking = true
        statusText = "正在处理…"
        let engine = ImportEngine.shared
        engine.log("🚀 \(appName)：开始处理")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            engine.log("🩺 目标 App：\(bid)")
            var assets = plugins

            // 0. 脚本先落盘。
            // 注入完成会立刻跳转启动游戏，脚本晚一步就没意义了（加载器启动时就读一次）。
            if let scriptNames, !scriptNames.isEmpty {
                let store = PandoraScriptStore.shared
                let picked = store.allScripts().filter { scriptNames.contains($0.name) }

                if picked.isEmpty {
                    engine.log("⚠️ 选中的脚本都不在脚本库里了，本次只注入插件")
                } else {
                    guard let container = PandoraLoader.dataContainerURL(bid: bid) else {
                        engine.log("❌ 拿不到目标数据容器")
                        self.finish(alertOnly: "拿不到 \(appName) 的数据容器。\n\n请先手动启动一次这个 App（系统才会给它建容器），再回来部署。")
                        return
                    }

                    do {
                        let count = try PandoraLoader.stageScripts(picked, dataContainer: container)
                        let list = picked.map { "\($0.name) · \($0.lang)" }.joined(separator: ", ")
                        engine.log("📜 已写入 \(count) 个脚本：\(list)")
                        engine.log("   → \(container.path)/Documents/Pandora/scripts")
                    } catch {
                        engine.log("❌ 写脚本失败：\(error.localizedDescription)")
                        self.finish(alertOnly: "脚本写入失败：\(error.localizedDescription)")
                        return
                    }

                    guard let payload = PandoraLoader.payloadURL() else {
                        engine.log("❌ 包里没有 \(PandoraLoader.dylibName)")
                        self.finish(alertOnly: "包里没有 \(PandoraLoader.dylibName)。\n\n把编译好的加载器放到工程的 TrollFools/ 目录后重新打包；或者先把 dylib 丢进暂存箱。")
                        return
                    }
                    if !assets.contains(where: { $0.lastPathComponent == PandoraLoader.dylibName }) {
                        assets.append(payload)
                        engine.log("🧩 已附加 \(PandoraLoader.dylibName)")
                    }
                }
            }

            guard !assets.isEmpty else {
                engine.log("❌ 没有要注入的东西")
                self.finish(alertOnly: "没有要注入的插件，也没有选脚本。")
                return
            }

            let names = assets.map { $0.lastPathComponent }.joined(separator: ", ")
            engine.log("💉 注入 \(assets.count) 个文件：\(names)…")

            DispatchQueue.main.async { self.statusText = "正在加载 \(assets.count) 个文件…" }

            // 1. kill the app if running (inject requires it not running)
            killRunningApp(bid: bid)
            Thread.sleep(forTimeInterval: 0.5)

            // 2. inject (non-persistent)
            do {
                let injector = try InjectorV3(bundleURL, loggerType: .os)
                try injector.inject(assets, shouldPersist: false)
                engine.log("✅ 注入完成")

                // 3. record session + spawn detached watchdog
                let manager = TempInjectManager.shared
                // 状态先落盘（决定下次启动能否自愈，写失败必须整体失败）；
                // 看门狗只是“退出即还原”的快路径，起不来不该把成功报成失败。
                try manager.writeState(bid: bid, assetURLs: assets)
                do {
                    try manager.spawnWatchdog(bid: bid)
                    engine.log("🐕 看门狗已启动（退出后自动还原）")
                } catch {
                    engine.log("⚠️ 看门狗启动失败：\(error.localizedDescription)；注入已生效，下次打开本 App 时自动还原")
                }

                // 4. jump to the app
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let launched = manager.launchApp(bid: bid)
                    engine.log(launched ? "📲 跳转指令已发送" : "⚠️ 跳转指令发送失败，请手动打开")
                    if !launched {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let retry = manager.launchApp(bid: bid)
                            engine.log(retry ? "📲 重试跳转成功" : "❌ 重试跳转仍失败，请手动打开")
                        }
                    }
                }
                self.finish(success: "插件已加载，正在打开 \(appName)。退出后插件自动移除。")
            } catch {
                engine.log("❌ 注入失败：\(error.localizedDescription)")
                self.finish(alertOnly: "加载失败：\(error.localizedDescription)")
            }
        }
    }

    func injectAndLaunch(_ target: GameTarget, stash: StashManager = .shared) {
        guard !isWorking else { return }
        isWorking = true
        statusText = "正在处理…"
        let engine = ImportEngine.shared
        engine.log("🚀 \(target.buttonTitle)：开始处理")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. resolve app
            guard let targetApp = self.resolveApp(target) else {
                engine.log("❌ 未找到已安装的目标 App")
                self.finish(alertOnly: "未找到「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」对应的已安装 App，请确认游戏已安装。")
                return
            }
            let bid = targetApp.bid
            let bundleURL = targetApp.url
            engine.log("🩺 目标 App：\(bid)")

            // 2. resolve plugins
            let plugins = stash.plugins(matching: target.pluginKeywords)
            guard !plugins.isEmpty else {
                engine.log("❌ 暂存箱无匹配插件（关键词：\(target.pluginKeywords.joined(separator: "/"))）")
                self.finish(alertOnly: "暂存箱中没有匹配「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」的插件。\n请先把对应的 dylib 放入暂存箱（文件名需包含“\(target.appNameKeywords.first ?? "")”）再试。")
                return
            }
            let names = plugins.map { $0.lastPathComponent }.joined(separator: ", ")
            engine.log("💉 匹配到 \(plugins.count) 个插件：\(names)，开始注入…")

            DispatchQueue.main.async { self.statusText = "正在加载 \(plugins.count) 个插件…" }

            // 3. kill the game if running (inject requires it not running)
            killRunningApp(bid: bid)
            Thread.sleep(forTimeInterval: 0.5)

            // 4. inject (non-persistent)
            do {
                let injector = try InjectorV3(bundleURL, loggerType: .os)
                try injector.inject(plugins, shouldPersist: false)
                engine.log("✅ 注入完成")

                // 5. record session + spawn detached watchdog
                let manager = TempInjectManager.shared
                try manager.writeState(bid: bid, assetURLs: plugins)
                do {
                    try manager.spawnWatchdog(bid: bid)
                    engine.log("🐕 看门狗已启动（退出游戏后自动还原）")
                } catch {
                    engine.log("⚠️ 看门狗启动失败：\(error.localizedDescription)；注入已生效，下次打开本 App 时自动还原")
                }

                // 6. jump to the game
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let launched = manager.launchApp(bid: bid)
                    engine.log(launched ? "📲 跳转指令已发送" : "⚠️ 跳转指令发送失败，请手动打开游戏")
                    if !launched {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let retry = manager.launchApp(bid: bid)
                            engine.log(retry ? "📲 重试跳转成功" : "❌ 重试跳转仍失败，请手动打开游戏")
                        }
                    }
                }
                self.finish(success: "插件已加载，正在打开游戏。退出游戏后插件自动移除。")
            } catch {
                engine.log("❌ 注入失败：\(error.localizedDescription)")
                self.finish(alertOnly: "加载失败：\(error.localizedDescription)")
            }
        }
    }

    private func finish(alertOnly message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            ImportEngine.shared.notice = TempAlertItem(title: "提示", message: message)
        }
    }

    private func finish(success message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            ImportEngine.shared.notice = TempAlertItem(title: "完成", message: message)
        }
    }
}

// MARK: - iOS 原生分组卡片（inset grouped 材质）

// MARK: - 柔光背景

/// App 背景：一层干净的柔光，不含任何线条。
///
/// 磨砂玻璃要成立，背后必须有**明暗**可糊 —— 纯色底上 `ultraThinMaterial`
/// 糊一片纯色得到的还是纯色，卡片就成了塑料片。
/// 但反过来，背景画满纹理线条同样不行：卡片之间只留 9pt 间隙，
/// 露出来的一条条乱纹比没有背景更难看。
///
/// 所以这里只画大尺度柔光斑：足够让玻璃透出层次，又不产生任何线条。
/// 深色 / 浅色各一张，首次访问时绘制一次并常驻，切换外观不会重画。
private enum FrostWallpaper {

    static let dark: UIImage = make(dark: true)
    static let light: UIImage = make(dark: false)

    private static let canvas = CGSize(width: 390, height: 844)

    private static func make(dark: Bool) -> UIImage {
        let size = canvas
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            let g = ctx.cgContext
            let W = size.width, H = size.height

            // 1. 底色：深色走中性近黑（不用亮蓝，否则整屏发闷），浅色走 iOS 分组灰白
            let baseRGB: [(CGFloat, CGFloat, CGFloat)] = dark
                ? [(0.043, 0.071, 0.125), (0.027, 0.047, 0.086), (0.004, 0.008, 0.024)]
                : [(0.980, 0.992, 1.000), (0.937, 0.965, 0.996), (0.816, 0.882, 0.953)]
            let stops: [CGFloat] = [0, 0.38, 1]

            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: baseRGB.map {
                    UIColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1).cgColor
                } as CFArray,
                locations: stops
            ) {
                g.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: W * 0.55, y: H),
                    options: []
                )
            }

            // 2. 柔光斑：只给明暗层次，不落任何线条。
            //    半径都在 0.55W 以上，模糊之后化成一片过渡，玻璃透出的就是这层光。
            let blobs: [(CGFloat, CGFloat, CGFloat, UIColor)] = dark
                ? [
                    (0.08, -0.02, 1.24, UIColor(red: 0.59, green: 0.76, blue: 1.00, alpha: 0.30)),
                    (0.98,  0.22, 0.70, UIColor(red: 0.27, green: 0.43, blue: 0.75, alpha: 0.20)),
                    (0.00,  0.98, 0.84, UIColor(red: 0.63, green: 0.80, blue: 1.00, alpha: 0.20)),
                    (0.66,  0.48, 0.62, UIColor(red: 0.00, green: 0.01, blue: 0.03, alpha: 0.55))
                  ]
                : [
                    (0.08, -0.02, 1.24, UIColor(white: 1.00, alpha: 1.00)),
                    (0.94,  0.18, 0.72, UIColor(red: 0.65, green: 0.82, blue: 1.00, alpha: 0.58)),
                    (0.00,  0.98, 0.86, UIColor(red: 0.94, green: 0.98, blue: 1.00, alpha: 0.80)),
                    (0.66,  0.54, 0.58, UIColor(red: 0.59, green: 0.75, blue: 0.92, alpha: 0.28))
                  ]

            for (bx, by, br, color) in blobs {
                let center = CGPoint(x: bx * W, y: by * H)
                let radius = br * W
                if let grad = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                    locations: [0, 1]
                ) {
                    g.drawRadialGradient(
                        grad, startCenter: center, startRadius: 0,
                        endCenter: center, endRadius: radius, options: []
                    )
                }
            }
        }
    }
}


// MARK: - 独立分离的磨砂卡片

/// 独立分离的磨砂卡片（「02 独立卡 + 03 厚磨砂」）。
///
/// 四层叠加：
/// 1. **提亮半透底** — 浅色 52% 白 / 深色 8.5% 冷白，玻璃必须比背景亮
/// 2. **ultraThinMaterial** — 真模糊。背后由 `LiquidGlassBackground` 铺柔光底，
///    糊开之后透上来的是那片光的明暗，不是一片死色
/// 3. **透光渐变** — 左上受光、右下微沉，做出玻璃曲面
/// 4. **厚度边** — 1.5pt 顶棱高光 + 底边暗线 + 外侧投影
///
/// 真机上 `ultraThinMaterial` 自带雾感和去饱和，不需要额外伪造颗粒。
/// 早先那版在纯色底上做磨砂，糊纯色等于没糊，才看不出玻璃。
///
/// 圆角 16 对齐行高，间距由调用方给。
private struct LiquidGlassCard: ViewModifier {

    var cornerRadius: CGFloat = 18

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(backdrop)
            .clipShape(shape)
            .shadow(
                color: Color.black.opacity(isDark ? 0.55 : 0.055),
                radius: isDark ? 14 : 10,
                x: 0,
                y: isDark ? 10 : 6
            )
    }

    private var backdrop: some View {
        ZStack {
            // 1. 半透底
            // 提亮型半透底。这里如果填暗色，玻璃会比背景更黑，
            // 整块卡片就"陷"进去，失去 iOS 玻璃浮起来的感觉。
            shape.fill(isDark
                ? Color(red: 146 / 255, green: 184 / 255, blue: 242 / 255).opacity(0.085)
                : Color.white.opacity(0.52))

            // 2. 高斯模糊
            if #available(iOS 15.0, *) {
                shape.fill(.ultraThinMaterial)
            }

            // 3. 透光渐变
            shape.fill(
                LinearGradient(
                    stops: isDark
                        ? [
                            .init(color: Color.white.opacity(0.075), location: 0.00),
                            .init(color: Color.white.opacity(0.012), location: 0.38),
                            .init(color: Color.white.opacity(0.000), location: 0.62),
                            .init(color: Color.black.opacity(0.180), location: 1.00)
                          ]
                        : [
                            .init(color: Color.white.opacity(0.46), location: 0.00),
                            .init(color: Color.white.opacity(0.07), location: 0.36),
                            .init(color: Color.white.opacity(0.00), location: 0.62),
                            .init(color: Color.white.opacity(0.00), location: 1.00)
                          ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            // 4. 雾：磨砂会把透上来的颜色洗淡一层。
            //    没有这一层，玻璃会跟着背景一起发蓝，像塑料而不是灰玻璃。
            shape.fill(
                isDark
                    ? Color(red: 206 / 255, green: 226 / 255, blue: 255 / 255).opacity(0.075)
                    : Color.white.opacity(0.14)
            )

            // 5. 顶棱 + 侧边描边
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isDark ? 0.26 : 1.00),
                        Color.white.opacity(isDark ? 0.09 : 0.62)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )

            // 6. 底边暗线：玻璃的下沿要有厚度，否则像贴纸
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(
                        isDark
                            ? Color(red: 6 / 255, green: 14 / 255, blue: 30 / 255).opacity(0.42)
                            : Color(red: 120 / 255, green: 160 / 255, blue: 210 / 255).opacity(0.22)
                    )
                    .frame(height: 1)
            }
        }
    }
}

private extension View {
    func liquidGlass(cornerRadius: CGFloat = 18) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius))
    }
}

/// 原生分组标题：13pt、secondaryLabel 色，与卡片左边缘对齐。
private struct GlassSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 调用方外层已有 16pt 内缩，这里再补 4pt，合计 20pt，
            // 略多于卡片左边缘 —— 也就是 iOS 分组标题相对卡片的那点缩进。
            // 没有这 4pt，标题会贴着屏幕左边，跟卡片错开一整截。
            .padding(.horizontal, 4)
            .padding(.top, 20)
            .padding(.bottom, 7)
    }
}

// MARK: - Target Selection (跨 Tab 共享已选目标应用)

/// 跨 Tab 共享的「当前已选目标应用」状态。
final class TargetSelection: ObservableObject {
    static let shared = TargetSelection()

    @Published var selectedApp: App?

    private init() {}
}

// MARK: - 收藏置顶 (收藏的 App 自动排最前)

/// 收藏的 App（bundle id）集合，用 UserDefaults 持久化。
/// 收藏的应用在「应用」列表中自动置顶，方便快速找到常用目标。
final class FavoriteApps: ObservableObject {

    static let shared = FavoriteApps()

    private static let defaultsKey = "shiliu.favoriteApps"

    @Published private(set) var bundleIDs: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        bundleIDs = Set(stored)
    }

    func isFavorite(_ bid: String) -> Bool {
        bundleIDs.contains(bid)
    }

    func toggle(_ bid: String) {
        if bundleIDs.contains(bid) {
            bundleIDs.remove(bid)
        } else {
            bundleIDs.insert(bid)
        }
        UserDefaults.standard.set(Array(bundleIDs), forKey: Self.defaultsKey)
    }
}

// MARK: - 背景（柔光底）

/// App 背景：一层干净的柔光，浅色 / 深色各一张。
///
/// 这一层不是为了好看，是为了让磨砂**成立**。
/// `ultraThinMaterial` 模糊的是它背后的像素；背景如果是一整片
/// `systemGroupedBackground` 纯色，模糊纯色还是纯色，卡片就只是一块塑料片。
/// 换成带明暗光斑的柔光底之后，玻璃里透出来的是被糊开的光，
/// 卡片外那片光还保持着清晰的明暗过渡 —— 一虚一实，玻璃才有厚度。
///
/// 只画光斑、不画线条：卡片间隙只有 9pt，任何条纹露出来都是噪点。
///
/// 壁纸由 `FrostWallpaper` 用 CoreGraphics 画一次并缓存，不占资源包体积。
/// 顶部与底部各压一道 scrim，保证状态栏、大标题和 TabBar 上的文字读得清。
private struct LiquidGlassBackground: View {

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(uiImage: isDark ? FrostWallpaper.dark : FrostWallpaper.light)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                LinearGradient(
                    stops: isDark
                        ? [
                            .init(color: Color(red: 2 / 255, green: 5 / 255, blue: 12 / 255).opacity(0.55), location: 0.00),
                            .init(color: Color(red: 2 / 255, green: 5 / 255, blue: 12 / 255).opacity(0.26), location: 0.15),
                            .init(color: Color(red: 2 / 255, green: 5 / 255, blue: 12 / 255).opacity(0.04), location: 0.40),
                            .init(color: Color(red: 2 / 255, green: 5 / 255, blue: 12 / 255).opacity(0.02), location: 0.60),
                            .init(color: Color(red: 2 / 255, green: 5 / 255, blue: 12 / 255).opacity(0.50), location: 1.00)
                          ]
                        : [
                            .init(color: Color.white.opacity(0.82), location: 0.00),
                            .init(color: Color.white.opacity(0.52), location: 0.15),
                            .init(color: Color.white.opacity(0.20), location: 0.38),
                            .init(color: Color.white.opacity(0.14), location: 0.58),
                            .init(color: Color.white.opacity(0.66), location: 1.00)
                          ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 底部液态玻璃 TabBar

/// 自定义底部栏：磨砂玻璃外壳 + 选中态液态玻璃胶囊。
///
/// 为什么不用系统 TabBar：
/// - 系统的选中态只有一层染色，做不出「提亮底 + 透光 + 顶棱 + 投影」的体积；
/// - 系统 TabBar 的选中胶囊位置写死，没法跟着翻页手势滑。
///
/// 选中胶囊用 `matchedGeometryEffect` 在三个槽位之间移动 —— 切换时是同一块
/// 玻璃滑过去，而不是两个色块各自淡入淡出，这就是「液态」的来源。
private struct LiquidTabBar: View {

    @Binding var selection: Int
    let items: [(icon: String, title: String)]

    /// 胶囊当前所在的槽位。与 `selection` 分开是为了动画：
    /// 翻页手势改 `selection` 时没有 `withAnimation` 包裹，
    /// 直接拿它驱动 `matchedGeometryEffect` 会让胶囊瞬移，
    /// 所以在 `onChange` 里统一补一次事务。
    @State private var visual: Int = 0

    /// 手指按下的槽位，用来做按下时的轻微内缩。
    @State private var pressed: Int? = nil

    @Namespace private var indicator

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    init(selection: Binding<Int>, items: [(icon: String, title: String)]) {
        self._selection = selection
        self.items = items
    }

    var body: some View {
        // 整条底栏铺一个 DragGesture，点击和滑动都由它判定：
        // - 位移超过 18pt → 滑动手势，按方向换相邻栏；
        // - 否则按落点横坐标算槽位，当作点击。
        // 不再用 Button —— Button 会把手势吃掉，这正是之前「只能点、滑不动」的原因。
        GeometryReader { geo in
            let inner = max(geo.size.width - 10, 1)          // 减掉左右各 5pt 内边距
            let slot = inner / CGFloat(max(items.count, 1))

            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    tabLabel(index: index)
                }
            }
            .padding(5)
            .liquidGlass(cornerRadius: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = slotIndex(at: value.location.x, slot: slot)
                        if pressed != index {
                            withAnimation(.easeOut(duration: 0.12)) { pressed = index }
                        }
                    }
                    .onEnded { value in
                        withAnimation(.easeOut(duration: 0.12)) { pressed = nil }
                        let dx = value.translation.width
                        if abs(dx) > 18 {
                            select(dx < 0 ? selection + 1 : selection - 1)
                        } else {
                            select(slotIndex(at: value.location.x, slot: slot))
                        }
                    }
            )
        }
        .frame(height: 60)
        // 悬浮在滚动内容之上，再加一道大半径投影把它从列表里"抬"起来
        .shadow(
            color: Color.black.opacity(isDark ? 0.42 : 0.10),
            radius: 18,
            x: 0,
            y: 8
        )
        .onAppear { visual = selection }
        .onChange(of: selection) { newValue in
            withAnimation(.interpolatingSpring(stiffness: 320, damping: 27)) {
                visual = newValue
            }
        }
    }

    /// 把落点横坐标换算成槽位（0 起）。手势坐标相对整条栏，
    /// 先减掉 5pt 内边距，再除以单槽宽度。
    private func slotIndex(at x: CGFloat, slot: CGFloat) -> Int {
        let raw = Int((x - 5) / max(slot, 1))
        return min(max(raw, 0), items.count - 1)
    }

    private func select(_ index: Int) {
        guard index != selection else { return }
        // 页面平移动画；胶囊的滑移由 onChange 里的 spring 单独驱动，
        // 两者一个"稳"一个"弹"，叠起来才像液体被推过去。
        withAnimation(.easeInOut(duration: 0.25)) {
            selection = index
        }
    }

    private func tabLabel(index: Int) -> some View {
        let item = items[index]
        let selected = visual == index
        let held = pressed == index && !selected

        return VStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(height: 19)
            Text(item.title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(selected ? .blue : .secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(selectedCapsule(visible: selected))
        // 按下时轻微内缩，补上原来 Button 的按压反馈
        .scaleEffect(held ? 0.94 : 1.0)
        .contentShape(Rectangle())
    }

    /// 选中态胶囊。和卡片同一套「提亮半透底 → 真模糊 → 透光 → 顶棱」顺序，
    /// 只是曲率更小、阴影更贴，避免在窄条里显得糊成一团。
    @ViewBuilder
    private func selectedCapsule(visible: Bool) -> some View {
        if visible {
            ZStack {
                Capsule()
                    .fill(isDark
                        ? Color(red: 146 / 255, green: 184 / 255, blue: 242 / 255).opacity(0.18)
                        : Color.white.opacity(0.80))

                if #available(iOS 15.0, *) {
                    Capsule().fill(.ultraThinMaterial)
                }

                Capsule()
                    .fill(
                        LinearGradient(
                            stops: isDark
                                ? [
                                    .init(color: Color.white.opacity(0.14), location: 0.00),
                                    .init(color: Color.white.opacity(0.00), location: 0.55),
                                    .init(color: Color.black.opacity(0.16), location: 1.00)
                                  ]
                                : [
                                    .init(color: Color.white.opacity(0.55), location: 0.00),
                                    .init(color: Color.white.opacity(0.05), location: 0.55),
                                    .init(color: Color.white.opacity(0.00), location: 1.00)
                                  ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDark ? 0.40 : 1.00),
                                Color.white.opacity(isDark ? 0.10 : 0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: Color.black.opacity(isDark ? 0.35 : 0.09),
                radius: 7,
                x: 0,
                y: 3
            )
            .matchedGeometryEffect(id: "tabIndicator", in: indicator)
        }
    }
}

// MARK: - Home View (底部三栏：应用 / 注入 / 暂存箱)

struct TempHomeView: View {

    @StateObject private var injector = GameInjector.shared
    @ObservedObject private var engine = ImportEngine.shared
    @State private var selectedTab = 0

    /// 切栏触感。`UISelectionFeedbackGenerator` 是最轻的一档（系统 Haptic Touch
    /// 里"选择器滚过一格"那种），比 `UIImpactFeedbackGenerator` 的 .light 还轻，
    /// 连点三栏也不会觉得吵。
    ///
    /// 生成器要复用同一个实例：每次 new 一个会重新走 Taptic Engine 的唤醒流程，
    /// 首次触发会有几十毫秒延迟，手感发"空"。
    private let haptic = UISelectionFeedbackGenerator()

    private static let tabs: [(icon: String, title: String)] = [
        ("square.grid.2x2.fill", "应用"),
        ("syringe.fill", "注入"),
        ("shippingbox.fill", "暂存箱")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            // 分页式 TabView：左右滑动即可切栏，底部圆点由自定义 TabBar 取代。
            TabView(selection: $selectedTab) {
                AppTabView()
                    .tag(0)

                InjectTabView()
                    .tag(1)

                StashTabView()
                    .tag(2)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

            LiquidTabBar(selection: $selectedTab, items: Self.tabs)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .accentColor(.blue)
        .onChange(of: selectedTab) { _ in
            // 点击与滑动都会走到这里 —— 两种切换方式的手感因此一致。
            haptic.selectionChanged()
            // 立刻预热门下一次触发，连续切换时不会掉帧。
            haptic.prepare()
        }
        .onAppear {
            haptic.prepare()
            // cleanupOrphans may synchronously run a full restore via the
            // CLI; keep it off the main thread to avoid blocking the UI.
            DispatchQueue.global(qos: .utility).async {
                TempInjectManager.shared.cleanupOrphans()
            }
            ImportEngine.shared.syncImportFolder()
        }
        .onOpenURL { url in
            // Receive files shared in from Files app / WeChat "open in" etc.
            ImportEngine.shared.log("📩 收到共享文件：\(url.lastPathComponent)")
            ImportEngine.shared.importURLs([url], source: "共享")
        }
        .alert(item: $engine.notice) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
    }

    // MARK: 首项 · 应用

    struct AppTabView: View {

        @StateObject private var appList = AppListModel()
        @StateObject private var targetSelection = TargetSelection.shared
        @StateObject private var favorites = FavoriteApps.shared
        @State private var searchText = ""

        private var filteredApps: [App] {
            let apps = appList.activeScopeApps.values.flatMap { $0 }
            let filtered = searchText.isEmpty
                ? apps
                : apps.filter {
                    $0.name.localizedCaseInsensitiveContains(searchText)
                        || $0.bid.localizedCaseInsensitiveContains(searchText)
                }
            // 收藏的排最前，其余按名称稳定排序
            // （Dictionary.values 顺序不稳定，且 Swift sort 非稳定，必须给出确定性的平局规则）
            return filtered.sorted { a, b in
                let aFav = favorites.isFavorite(a.bid)
                let bFav = favorites.isFavorite(b.bid)
                if aFav != bFav { return aFav }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        var body: some View {
            // 不再套 NavigationView：分页 TabView 里三页各自持有导航栏时，
            // 三个 navigationTitle 会同时生效叠在左上角，而且每页的
            // UIScrollView 会把分页左右滑动的手势吃掉。改成纯内容视图，
            // 由页面自己排布，标题也不再需要。
            VStack(spacing: 0) {
                        // 搜索栏（始终显示，不受列表状态影响）
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("搜索 App 名称或 bundle id", text: $searchText)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .liquidGlass(cornerRadius: 14)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        ScrollView {
                            if filteredApps.isEmpty {
                                // 空态：区分「搜索无结果」和「确实没有可注入 App」
                                VStack(spacing: 8) {
                                    if !searchText.isEmpty {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 28))
                                            .foregroundColor(.secondary.opacity(0.6))
                                        Text("没有找到「\(searchText)」相关的 App")
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                        Text("换个关键词试试，或点搜索框右侧 ✕ 清空搜索。")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 40)
                                    } else {
                                        Text("没有可注入的 App")
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                        Text("请确认 App 已安装，且为可注入类型（App Store / 巨魔商店应用）。")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 40)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                            } else {
                                LazyVStack(spacing: 9) {
                                    ForEach(filteredApps, id: \.bid) { app in
                                        let isSelected = targetSelection.selectedApp?.bid == app.bid
                                        let isFav = favorites.isFavorite(app.bid)
                                        HStack(spacing: 12) {
                                            // 点主体选为目标应用
                                            Button {
                                                targetSelection.selectedApp = app
                                            } label: {
                                                HStack(spacing: 12) {
                                                    Image(uiImage: app.icon ?? UIImage())
                                                        .resizable()
                                                        .frame(width: 40, height: 40)
                                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        HStack(spacing: 4) {
                                                            Text(app.name)
                                                                .font(.body)
                                                                .fontWeight(.medium)
                                                                .foregroundColor(.primary)
                                                                .lineLimit(1)
                                                            if isFav {
                                                                Image(systemName: "star.fill")
                                                                    .font(.system(size: 12))
                                                                    .foregroundColor(.yellow)
                                                            }
                                                        }
                                                        Text(app.bid)
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                    Spacer()
                                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                        .font(.system(size: 22))
                                                        .foregroundColor(isSelected ? .blue : .secondary.opacity(0.4))
                                                }
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(PlainButtonStyle())

                                            // 收藏/取消收藏星标按钮
                                            Button {
                                                favorites.toggle(app.bid)
                                            } label: {
                                                Image(systemName: isFav ? "star.fill" : "star")
                                                    .font(.system(size: 20))
                                                    .foregroundColor(isFav ? .yellow : .secondary.opacity(0.45))
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                        .padding(14)
                                        .liquidGlass()
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                // 自定义 TabBar 悬浮在内容之上，底部留出它的高度，
                                // 否则最后一张卡会被压住（系统 TabBar 原本会自动 inset）
                                .padding(.bottom, 92)
                            }
                        }
            }
            // 壁纸走 background 而不是放进 ZStack：
            // 它内部带 ignoresSafeArea，作为子视图会把整个 VStack 撑到全屏，
            // 页面内容于是从状态栏底下起排。
            .background(LiquidGlassBackground())
        }
    }

    // MARK: 中间项 · 注入

    struct InjectTabView: View {

        @StateObject private var injector = GameInjector.shared
        @StateObject private var targetSelection = TargetSelection.shared
        @ObservedObject private var engine = ImportEngine.shared
        @State private var plugins: [URL] = []
        @State private var groups: [(category: String, items: [StashManager.DeepItem])] = []
        @State private var collapsed: Set<String> = []
        @State private var selected: Set<String> = []
        @State private var pendingSessions: [TempInjectManager.PendingSession] = []

        // 脚本加载器
        @StateObject private var scriptModel = PandoraScriptModel()
        @State private var isScriptImporterPresented = false
        @State private var editorTarget: PandoraEditorTarget?

        var body: some View {
            // 同「应用」页：去掉 NavigationView，避免多页导航栏叠加与分页手势冲突
            ScrollView {
                        VStack(spacing: 0) {
                            // 已选目标应用
                            GlassSectionTitle(text: "目标应用")

                            if let app = targetSelection.selectedApp {
                                HStack(spacing: 12) {
                                    Image(uiImage: app.icon ?? UIImage())
                                        .resizable()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name)
                                            .font(.body)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(app.bid)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.blue)
                                }
                                .padding(16)
                                .liquidGlass()
                            } else {
                                HStack(spacing: 12) {
                                    Image(systemName: "square.grid.2x2")
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary)
                                    Text("尚未选择目标应用，请先到「应用」页选择")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(16)
                                .liquidGlass()
                            }

                            // 待还原会话：自动重试有上限，超过上限后给一个手动入口
                            if !pendingSessions.isEmpty {
                                GlassSectionTitle(text: "待还原的临时注入")

                                VStack(spacing: 9) {
                                    ForEach(pendingSessions, id: \.bid) { session in
                                        HStack(spacing: 12) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundColor(.orange)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(session.appName)
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                Text(session.attempts >= 3
                                                     ? "自动还原已暂停（连续失败 \(session.attempts) 次）"
                                                     : "上次未完成还原（已尝试 \(session.attempts) 次）")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Button("立即还原") {
                                                restoreSession(session.bid)
                                            }
                                            .font(.footnote)
                                            .foregroundColor(.blue)
                                        }
                                        .padding(16)
                                        .liquidGlass()
                                    }
                                }
                            }

                            // 选择插件
                            HStack(alignment: .bottom) {
                                GlassSectionTitle(text: "选择要注入的插件（可多选）")
                                Spacer()
                                if !plugins.isEmpty {
                                    Button(selected.count == plugins.count ? "清空" : "全选") {
                                        if selected.count == plugins.count {
                                            selected.removeAll()
                                        } else {
                                            selected = Set(plugins.map { $0.absoluteString })
                                        }
                                    }
                                    .font(.footnote)
                                    .foregroundColor(.blue)
                                    .padding(.bottom, 8)
                                    .padding(.trailing, 10)
                                }
                            }

                            if plugins.isEmpty {
                                HStack(spacing: 12) {
                                    Image(systemName: "shippingbox")
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary)
                                    Text("暂存箱暂无插件，请先到「暂存箱」页导入")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(16)
                                .liquidGlass()
                            } else {
                                // 按分类分组展示，与暂存箱一致；点分组标题展开/收起
                                VStack(spacing: 18) {
                                    ForEach(groups, id: \.category) { group in
                                        VStack(spacing: 9) {
                                            // 分组标题（可点折叠）
                                            Button {
                                                toggleCollapsed(group.category)
                                            } label: {
                                                HStack(spacing: 10) {
                                                    Image(systemName: collapsed.contains(group.category) ? "chevron.right" : "chevron.down")
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundColor(.secondary)
                                                        .frame(width: 14)
                                                    Image(systemName: "folder.fill")
                                                        .font(.caption)
                                                        .foregroundColor(.blue)
                                                    Text(group.category)
                                                        .font(.subheadline)
                                                        .fontWeight(.semibold)
                                                        .foregroundColor(.primary)
                                                    Spacer()
                                                    Text("\(group.items.count) 个")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(PlainButtonStyle())

                                            if !collapsed.contains(group.category) {
                                                ForEach(group.items, id: \.relPath) { item in
                                                    let url = item.url
                                                    let isSelected = selected.contains(url.absoluteString)
                                                    Button {
                                                        if isSelected {
                                                            selected.remove(url.absoluteString)
                                                        } else {
                                                            selected.insert(url.absoluteString)
                                                        }
                                                    } label: {
                                                        HStack(spacing: 12) {
                                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                                .font(.system(size: 22))
                                                                .foregroundColor(isSelected ? .blue : .secondary.opacity(0.5))
                                                            Image(systemName: "shippingbox.fill")
                                                                .font(.system(size: 16))
                                                                .foregroundColor(.blue)
                                                            VStack(alignment: .leading, spacing: 2) {
                                                                Text(url.lastPathComponent)
                                                                    .font(.body)
                                                                    .fontWeight(.medium)
                                                                    .foregroundColor(.primary)
                                                                    .lineLimit(1)
                                                                Text(url.pathExtension.uppercased())
                                                                    .font(.caption2)
                                                                    .foregroundColor(.secondary)
                                                            }
                                                            Spacer()
                                                        }
                                                        .padding(14)
                                                    }
                                                    .buttonStyle(PlainButtonStyle())
                                                    .liquidGlass()
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // 脚本加载器（可选）
                            GlassSectionTitle(text: "脚本（可选）")
                            scriptSection

                            // 注入按钮
                            Button {
                                startInjection()
                            } label: {
                                HStack {
                                    Spacer()
                                    if injector.isWorking {
                                        ProgressView()
                                            .padding(.trailing, 8)
                                    }
                                    Text(injectButtonTitle)
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(.vertical, 16)
                                .background(
                                    // 主按钮：渐层蓝 + 顶棱白 + 底边暗 + 蓝色外发光。
                                    // 纯色块在磨砂列表里会显得很平，加这三层才有"按下去"的体积。
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(
                                                canInject
                                                    ? LinearGradient(
                                                        colors: [
                                                            Color(red: 0.24, green: 0.55, blue: 1.00),
                                                            Color(red: 0.10, green: 0.37, blue: 0.88)
                                                        ],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                      )
                                                    : LinearGradient(
                                                        colors: [Color(.systemFill), Color(.systemFill)],
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                      )
                                            )

                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(
                                                LinearGradient(
                                                    colors: [
                                                        Color.white.opacity(canInject ? 0.55 : 0.10),
                                                        Color.white.opacity(canInject ? 0.05 : 0.02)
                                                    ],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                ),
                                                lineWidth: 1
                                            )

                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(
                                                Color(red: 0.55, green: 0.75, blue: 1.00)
                                                    .opacity(canInject ? 0.45 : 0),
                                                lineWidth: 1
                                            )
                                    }
                                    .shadow(
                                        color: Color(red: 0.08, green: 0.35, blue: 0.86)
                                            .opacity(canInject ? 0.45 : 0),
                                        radius: 13,
                                        x: 0,
                                        y: 7
                                    )
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(!canInject)
                            .padding(.top, 20)

                            // 版本号取自 Info.plist，避免界面写死 v1.0 与实际包版本（4.3-253）不一致
                            Text("石榴动态注入 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · 基于 TrollFools")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 20)
                                // 给悬浮 TabBar 让位
                                .padding(.bottom, 100)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
            }
                .background(LiquidGlassBackground())
                .onAppear {
                    reloadPlugins()
                    reloadPending()
                    scriptModel.reload(bid: targetSelection.selectedApp?.bid)
                }
                .onChange(of: engine.logRevision) { _ in
                    // 看门狗起失败 / 还原失败都会写日志，这里顺带刷新待还原列表
                    reloadPending()
                }
                .onChange(of: targetSelection.selectedApp?.bid) { bid in
                    // 换了目标 App，脚本选中状态跟着换（绑定是按 bundle id 存的）
                    scriptModel.reload(bid: bid)
                }
                .fileImporter(
                    isPresented: $isScriptImporterPresented,
                    allowedContentTypes: [
                        .init(filenameExtension: "js")!,
                        .init(filenameExtension: "pjs")!,
                        .init(filenameExtension: "lua")!,
                        .plainText,
                    ],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case let .success(urls):
                        let report = PandoraScriptStore.shared.importScripts(from: urls)
                        for name in report.imported {
                            engine.log("📥 导入脚本：\(name)")
                        }
                        for line in report.skipped {
                            engine.log("⏭ 跳过：\(line)")
                        }
                        scriptModel.reload(bid: targetSelection.selectedApp?.bid)
                        if !report.isEmpty {
                            engine.notice = TempAlertItem(
                                title: "脚本导入",
                                message: "新增 / 更新 \(report.imported.count) 个"
                                    + (report.skipped.isEmpty ? "" : "\n跳过 \(report.skipped.count) 个")
                            )
                        }
                    case let .failure(error):
                        engine.log("❌ 选择文件失败：\(error.localizedDescription)")
                    }
                }
                .sheet(item: $editorTarget) { target in
                    PandoraEditorView(name: target.name)
                }
        }

        // MARK: - 插件分组

        private static let collapsedKey = "shiliu.injectCollapsed"

        private func loadCollapsed() {
            let arr = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
            collapsed = Set(arr)
        }

        private func toggleCollapsed(_ category: String) {
            if collapsed.contains(category) {
                collapsed.remove(category)
            } else {
                collapsed.insert(category)
            }
            UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
        }

        /// 刷新插件列表：按分类分组（与暂存箱一致），同时维护全选用的扁平数组。
        private func reloadPlugins() {
            loadCollapsed()
            let items = StashManager.shared.listPluginItems()
            plugins = items.map { $0.url }

            var byCategory: [String: [StashManager.DeepItem]] = [:]
            for item in items {
                let category = StashManager.category(ofPluginAt: item.url)
                byCategory[category, default: []].append(item)
            }
            groups = byCategory
                .sorted { lhs, rhs in
                    if (lhs.key == "未分类") != (rhs.key == "未分类") {
                        return rhs.key == "未分类" // 未分类永远排最后
                    }
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
                .map { (category: $0.key, items: $0.value) }
        }

        /// 刷新“待还原会话”列表（看门狗已死、状态仍在的会话）。
        private func reloadPending() {
            pendingSessions = TempInjectManager.shared.pendingSessions()
        }

        /// 手动还原一个会话，完成后刷新列表。
        private func restoreSession(_ bid: String) {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = TempInjectManager.shared.restoreNow(bid: bid)
                DispatchQueue.main.async {
                    reloadPending()
                }
            }
        }

        private var canInject: Bool {
            guard targetSelection.selectedApp != nil, !injector.isWorking else { return false }
            // 只跑脚本、不注入别的插件也允许
            return !selected.isEmpty || !scriptModel.selected.isEmpty
        }

        /// 注入按钮标题：根据当前状态动态变化。
        private var injectButtonTitle: String {
            if injector.isWorking {
                return injector.statusText
            }
            if targetSelection.selectedApp == nil {
                return "请先选择目标应用"
            }
            if selected.isEmpty && scriptModel.selected.isEmpty {
                return "请选择插件或脚本"
            }
            var parts: [String] = []
            if !selected.isEmpty { parts.append("\(selected.count) 个插件") }
            if !scriptModel.selected.isEmpty { parts.append("\(scriptModel.selected.count) 个脚本") }
            return "注入并启动（\(parts.joined(separator: " + "))）"
        }

        private func startInjection() {
            guard let app = targetSelection.selectedApp else { return }
            let urls = plugins.filter { selected.contains($0.absoluteString) }
            let scripts = scriptModel.scripts
                .filter { scriptModel.selected.contains($0.name) }
                .map { $0.name }

            guard !urls.isEmpty || !scripts.isEmpty else { return }

            let engine = ImportEngine.shared
            engine.log("⚡️ 临时注入：\(app.name) ← \(urls.count) 个插件 / \(scripts.count) 个脚本")
            if !urls.isEmpty {
                engine.log("   - \(urls.map { $0.lastPathComponent }.joined(separator: "\n   - "))")
            }
            if !scripts.isEmpty {
                engine.log("   * \(scripts.joined(separator: "\n   * "))")
            }

            injector.injectAndLaunch(
                appName: app.name,
                bid: app.bid,
                bundleURL: app.url,
                plugins: urls,
                scriptNames: scripts
            )
        }

        // MARK: - 脚本区块

        @ViewBuilder
        private var scriptSection: some View {
            VStack(spacing: 9) {
                // 加载器状态 + 导入入口
                HStack(spacing: 11) {
                    Image(systemName: PandoraLoader.isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(PandoraLoader.isAvailable ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(PandoraLoader.isAvailable ? "加载器已就绪" : "缺少 PandoraLoader.dylib")
                            .font(.footnote)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text(PandoraLoader.isAvailable
                             ? "勾了脚本就自动带上加载器，不用另外选插件"
                             : "把 dylib 放进工程 TrollFools/ 重新打包，或丢进暂存箱")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button {
                        isScriptImporterPresented = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(14)
                .liquidGlass()

                if scriptModel.scripts.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                        Text("脚本库是空的。点右上角下载按钮导入 .js / .pjs / .lua")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(16)
                    .liquidGlass()
                } else {
                    ForEach(scriptModel.scripts) { script in
                        scriptRow(script)
                    }
                }

                if let warning = scriptModel.mixedWarning {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(12)
                    .liquidGlass()
                }

                Text("同一时间只能跑一种语言：JSC(.js) / PuerTS(.pjs) / Lua(.lua)。点选另一种会自动取消前一种。")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }

        private func scriptRow(_ script: PandoraScript) -> some View {
            let isOn = scriptModel.selected.contains(script.name)
            return HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isOn ? .blue : .secondary.opacity(0.5))

                Image(systemName: "doc.plaintext.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(script.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(script.langTitle) · \(script.sizeText) · \(script.langHint)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    editorTarget = PandoraEditorTarget(name: script.name)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture {
                scriptModel.toggle(script, bid: targetSelection.selectedApp?.bid)
            }
            .contextMenu {
                Button {
                    editorTarget = PandoraEditorTarget(name: script.name)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button {
                    PandoraScriptStore.shared.remove(script.name)
                    scriptModel.reload(bid: targetSelection.selectedApp?.bid)
                    ImportEngine.shared.log("🗑 已删除脚本：\(script.name)")
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .liquidGlass()
        }
    }

    // MARK: 第三项 · 暂存箱

    struct StashTabView: View {

        var body: some View {
            StashView()
        }
    }
}

// MARK: - Stash Page (permanent storage)

struct StashView: View {

    @ObservedObject private var engine = ImportEngine.shared
    @State private var groups: [(category: String, items: [StashManager.DeepItem])] = []
    @State private var collapsed: Set<String> = []
    @State private var isCreateCategoryPresented = false
    @State private var newCategoryName = ""
    @State private var reloadWork: DispatchWorkItem?
    @State private var isEditing = false

    private let stash = StashManager.shared

    var body: some View {
        // 去掉了 NavigationView：编辑入口从导航栏右上角挪进内容区
        ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { isEditing.toggle() }
                        } label: {
                            Text(isEditing ? "完成" : "编辑")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(groups.isEmpty ? Color.secondary.opacity(0.35) : .blue)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .liquidGlass(cornerRadius: 12)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(groups.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    Text("暂存箱是「插件导入」文件夹的实时镜像：文件夹里有什么，这里就显示什么；在这里删除，文件夹里的对应文件会一并删除。点分组标题可展开／收起。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 2)

                    if groups.isEmpty {
                        VStack(spacing: 6) {
                            Text("暂无插件")
                                .font(.body)
                                .foregroundColor(.secondary)
                            Text("把 dylib / framework / zip / deb 放进「插件导入」文件夹即可自动同步到这里。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        ForEach(groups, id: \.category) { group in
                            groupBlock(group)
                        }
                    }

                    actionBlock
                }
                .padding(.bottom, 130)
        }
        .background(LiquidGlassBackground())
        .onAppear {
            loadCollapsed()
            reload()
            ImportEngine.shared.syncImportFolder()
        }
        .onChange(of: engine.logRevision) { _ in
            scheduleReload()
        }
        .alert(item: $engine.notice) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
        .sheet(isPresented: $isCreateCategoryPresented) {
            NavigationView {
                ZStack {
                    VStack(spacing: 14) {
                        Text("分类文件夹会创建在「插件导入」目录下，暂存箱同步出现。之后把对应 dylib 拖进该文件夹即可自动归类。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)

                        // 输入框与主界面搜索框同款玻璃：
                        // 系统 Form 那层灰底会从磨砂背景里切出一整块，很突兀。
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                            TextField("分类名称（如：王者荣耀）", text: $newCategoryName)
                                .font(.system(size: 16))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            if !newCategoryName.isEmpty {
                                Button {
                                    newCategoryName = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .liquidGlass(cornerRadius: 14)
                        .padding(.horizontal, 16)

                        // 与「立即同步」「新建分类文件夹」同一套行样式
                        Button {
                            createCategory()
                        } label: {
                            actionRow("folder.badge.plus", "创建分类文件夹")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .opacity(canCreateCategory ? 1 : 0.45)
                        .disabled(!canCreateCategory)

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 14)
                }
                .background(LiquidGlassBackground())
                .navigationTitle("新建分类")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            newCategoryName = ""
                            isCreateCategoryPresented = false
                        }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }

    // MARK: - 新建分类

    /// 名称合法性：非空、不是 . / ..、不含路径分隔符 —— 否则会建到上级目录去。
    private var canCreateCategory: Bool {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private func createCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCreateCategory else { return }
        let folderURL = ImportEngine.importFolderURL
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folderURL, withIntermediateDirectories: true
        )
        ImportEngine.shared.log("📁 已创建分类：\(name)")
        ImportEngine.shared.syncImportFolder()
        reload()
        newCategoryName = ""
        isCreateCategoryPresented = false
    }

    // MARK: - 分组

    /// 一个分类：折叠头 + 该分类下的插件行。
    private func groupBlock(_ group: (category: String, items: [StashManager.DeepItem])) -> some View {
        VStack(spacing: 0) {
            Button {
                toggleCollapsed(group.category)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: collapsed.contains(group.category) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    // 与注入页的分组标题保持一致：折叠箭头 + 蓝色文件夹 + 分类名 + 数量
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text(group.category)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text("\(group.items.count)")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed.contains(group.category) {
                if group.items.isEmpty {
                    Text("这个分类还是空的")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                } else {
                    VStack(spacing: 9) {
                        ForEach(group.items, id: \.relPath) { item in
                            stashRow(item)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func stashRow(_ item: StashManager.DeepItem) -> some View {
        let size = Self.sizeText(of: item.url)

        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 15))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Self.iconGradient(for: item.url))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 16.5))
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(item.relPath)
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !size.isEmpty {
                Text(size)
                    .font(Font.system(size: 14).monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if isEditing {
                Button {
                    delete(item)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 56)
        .liquidGlass()
        .contextMenu {
            // Button(role:) 是 iOS 15 才有的初始化器，项目最低 14，所以做分支
            if #available(iOS 15.0, *) {
                Button(role: .destructive) {
                    delete(item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } else {
                Button {
                    delete(item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isEditing = true }
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }
    }

    // MARK: - 操作区

    private func actionRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.blue)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.blue.opacity(0.14))
                )
            Text(title)
                .font(.system(size: 16.5))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 56)
        .liquidGlass()
    }

    private var actionBlock: some View {
        VStack(spacing: 9) {
            Button {
                ImportEngine.shared.syncImportFolder(force: true)
            } label: {
                actionRow("arrow.triangle.2.circlepath", "立即同步")
            }
            .buttonStyle(.plain)

            Button {
                isCreateCategoryPresented = true
            } label: {
                actionRow("folder.badge.plus", "新建分类文件夹")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    // MARK: - 日志（已不在界面展示）

    private func delete(_ item: StashManager.DeepItem) {
        stash.removePlugin(item.url)
        reload()
    }

    // MARK: - Reload

    /// 图标底色：按文件名做稳定散列取色。
    ///
    /// 不能用 `hashValue` —— Swift 的哈希每个进程带随机种子，重启后同一个插件会换颜色。
    private static func iconGradient(for url: URL) -> LinearGradient {
        let name = url.lastPathComponent
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let palette: [(Color, Color)] = [
            (Color(red: 0.72, green: 0.55, blue: 1.00), Color(red: 0.42, green: 0.20, blue: 0.79)),
            (Color(red: 0.37, green: 0.85, blue: 0.91), Color(red: 0.11, green: 0.56, blue: 0.65)),
            (Color(red: 0.50, green: 0.88, blue: 0.48), Color(red: 0.17, green: 0.62, blue: 0.17)),
            (Color(red: 1.00, green: 0.78, blue: 0.36), Color(red: 0.85, green: 0.54, blue: 0.05)),
            (Color(red: 1.00, green: 0.48, blue: 0.48), Color(red: 0.77, green: 0.17, blue: 0.17))
        ]
        let pair = palette[Int(hash % UInt64(palette.count))]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 行尾显示插件体积（目录/取不到时留空，避免为了显示大小去递归枚举 framework）。
    private static func sizeText(of url: URL) -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return "" }
        let bytes = StashManager.fileSize(of: url)
        guard bytes >= 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static let collapsedKey = "shiliu.stashCollapsed"

    private func loadCollapsed() {
        let arr = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
        collapsed = Set(arr)
    }

    private func toggleCollapsed(_ category: String) {
        if collapsed.contains(category) {
            collapsed.remove(category)
        } else {
            collapsed.insert(category)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
    }

    /// 日志每来一行就整盘递归重扫一次是纯浪费：一次同步会连打十几行，
    /// 而 listDeep 是递归枚举。合并成 0.4 秒一次的尾部触发。
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func reload() {
        // 按分类分组：子文件夹名 = 分类名；根目录插件 = 未分类；空分类也显示。
        // 只把插件类型（dylib/zip/deb 文件与 .framework/.bundle 目录）当条目，
        // 插件 bundle 内部的文件不单独成行。
        let deep = stash.listDeep()
        var byCategory: [String: [StashManager.DeepItem]] = [:]
        var topLevelDirs = Set<String>()
        for item in deep {
            let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
            if item.isDirectory {
                if StashManager.pluginBundleExtensions.contains(ext) {
                    // .framework / .bundle 目录本身就是插件
                    let category = StashManager.category(ofPluginAt: item.url)
                    byCategory[category, default: []].append(item)
                } else if !item.relPath.contains("/") {
                    topLevelDirs.insert(item.relPath) // 顶层分类文件夹（可能为空）
                }
                continue
            }
            // 文件：仅插件扩展名，且不在插件 bundle 内部
            guard StashManager.pluginFileExtensions.contains(ext) else { continue }
            let ancestors = item.relPath.split(separator: "/").dropLast().map(String.init)
            guard !ancestors.contains(where: {
                StashManager.pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }) else { continue }
            let category = StashManager.category(ofPluginAt: item.url)
            byCategory[category, default: []].append(item)
        }
        for dir in topLevelDirs where byCategory[dir] == nil {
            byCategory[dir] = [] // 空分类也展示
        }
        groups = byCategory
            .sorted { lhs, rhs in
                if (lhs.key == "未分类") != (rhs.key == "未分类") {
                    return rhs.key == "未分类" // 未分类永远排最后
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { (category: $0.key, items: $0.value) }
    }
}
