//
//  InjectView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import CocoaLumberjackSwift
import SwiftUI

struct InjectView: View {
    struct SuccessPayload {
        let logFileURL: URL?
        let didUseFallback: Bool
    }

    @EnvironmentObject var appList: AppListModel

    let app: App
    let urlList: [URL]
    let tempMode: Bool

    @State var injectResult: Result<SuccessPayload, Error>?
    @StateObject fileprivate var viewControllerHost = ViewControllerHost()

    @AppStorage var useWeakReference: Bool
    @AppStorage var preferMainExecutable: Bool
    @AppStorage var useFrameworkEnumerationFallback: Bool
    @AppStorage var injectStrategy: InjectorV3.Strategy

    init(_ app: App, urlList: [URL], tempMode: Bool = false) {
        self.app = app
        self.urlList = urlList
        self.tempMode = tempMode
        _useWeakReference = AppStorage(wrappedValue: true, "UseWeakReference-\(app.bid)")
        _preferMainExecutable = AppStorage(wrappedValue: false, "PreferMainExecutable-\(app.bid)")
        _useFrameworkEnumerationFallback = AppStorage(wrappedValue: true, "UseFrameworkEnumerationFallback-\(app.bid)")
        _injectStrategy = AppStorage(wrappedValue: .lexicographic, "InjectStrategy-\(app.bid)")
    }

    var body: some View {
        if appList.isSelectorMode {
            bodyContent
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(NSLocalizedString("Done", comment: "")) {
                            viewControllerHost.viewController?.navigationController?
                                .dismiss(animated: true)
                        }
                    }
                }
        } else {
            bodyContent
        }
    }

    var bodyContent: some View {
        VStack {
            if let injectResult {
                switch injectResult {
                case let .success(payload):
                    SuccessView(
                        title: NSLocalizedString("Completed", comment: ""),
                        subtitle: tempMode
                            ? NSLocalizedString("TempInjectSuccessHint", comment: "")
                            : payload.didUseFallback
                                ? NSLocalizedString("Completed with compatibility mode. The plug-in may start working after opening some app features.", comment: "")
                                : nil,
                        logFileURL: payload.logFileURL
                    )
                    .onAppear {
                        app.reload()
                    }
                case let .failure(error):
                    FailureView(
                        title: NSLocalizedString("Failed", comment: ""),
                        error: error
                    )
                    .onAppear {
                        app.reload()
                    }
                }
            } else {
                if #available(iOS 16, *) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.all, 20)
                        .controlSize(.large)
                } else {
                    // Fallback on earlier versions
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.all, 20)
                        .scaleEffect(2.0)
                }

                Text(NSLocalizedString("Injecting", comment: ""))
                    .font(.headline)
            }
        }
        .padding()
        .animation(.easeOut, value: injectResult == nil)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onViewWillAppear { viewController in
            viewController.navigationController?
                .view.isUserInteractionEnabled = false
            viewControllerHost.viewController = viewController
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = inject()

                DispatchQueue.main.async {
                    injectResult = result
                    app.reload()
                    viewControllerHost.viewController?.navigationController?
                        .view.isUserInteractionEnabled = true
                }
            }
        }
    }

    private func inject() -> Result<SuccessPayload, Error> {
        var logFileURL: URL?

        do {
            let injector = try InjectorV3(app.url)
            logFileURL = injector.latestLogFileURL

            if injector.appID.isEmpty {
                injector.appID = app.bid
            }

            if injector.teamID.isEmpty {
                injector.teamID = app.teamID
            }

            injector.useWeakReference = useWeakReference
            injector.preferMainExecutable = preferMainExecutable
            injector.useFrameworkEnumerationFallback = useFrameworkEnumerationFallback
            injector.injectStrategy = injectStrategy

            try injector.inject(urlList, shouldPersist: !tempMode)

            if tempMode {
                let manager = TempInjectManager.shared
                // 状态先落盘：它决定下次启动能不能自愈，写失败必须整体失败。
                try manager.writeState(bid: app.bid, assetURLs: urlList)
                // 看门狗起不来 ≠ 注入失败：插件已生效，退化为“下次打开本 App 时
                // 由 cleanupOrphans 还原”。旧实现把它当致命错误，用户会看到
                // “注入失败”但其实注入已经成功，反而更迷惑。
                do {
                    try manager.spawnWatchdog(bid: app.bid)
                } catch {
                    DDLogError("watchdog spawn failed: \(error)", ddlog: InjectorV3.main.logger)
                    ImportEngine.shared.log("⚠️ 自动还原看门狗启动失败：\(error.localizedDescription)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [bid = app.bid] in
                    TempInjectManager.shared.launchApp(bid: bid)
                }
            }

            return .success(SuccessPayload(
                logFileURL: injector.latestLogFileURL,
                didUseFallback: injector.didUseMachOEnumerationFallback
            ))

        } catch {
            DDLogError("\(error)", ddlog: InjectorV3.main.logger)

            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: error.localizedDescription,
            ]

            if let logFileURL {
                userInfo[NSURLErrorKey] = logFileURL
            }

            let nsErr = NSError(domain: Constants.gErrorDomain, code: 0, userInfo: userInfo)

            return .failure(nsErr)
        }
    }
}

// MARK: - TempInject Manager

final class TempInjectManager {
    static let shared = TempInjectManager()

    private init() {}

    private var stateRootURL: URL { Constants.tempInjectRootURL }

    private func stateDirURL(for bid: String) -> URL {
        stateRootURL.appendingPathComponent(bid, isDirectory: true)
    }

    private func stateFileURL(for bid: String) -> URL {
        stateDirURL(for: bid).appendingPathComponent("state.json")
    }

    private func plugInListURL(for bid: String) -> URL {
        stateDirURL(for: bid).appendingPathComponent("plugins.list")
    }

    private struct TempEntry: Codable {
        let name: String
        let kind: String
    }

    /// Record the temporary injection session state, and remember the chosen
    /// plugin paths so that the next run can be one-tap.
    func writeState(bid: String, assetURLs: [URL]) throws {
        let fileManager = FileManager.default
        let dirURL = stateDirURL(for: bid)
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let entries = assetURLs.map { url -> TempEntry in
            let ext = url.pathExtension.lowercased()
            let kind: String
            switch ext {
            case "bundle":
                kind = "bundle" // copied to the app bundle root
            case "framework":
                kind = "framework" // copied to Frameworks/
            default:
                kind = "dylib" // copied to Frameworks/
            }
            return TempEntry(name: url.lastPathComponent, kind: kind)
        }
        // 合并上一次会话的条目，而不是整份覆盖。
        // 场景：同一个 App 先临时注入 A、退出后再注入 B。若 state.json 被 B 覆盖，
        // 看门狗只会摘掉 B —— A 的 dylib 就永久留在 App 里（既不属于任何会话状态，
        // 也不会被下一次还原带走），只能重装 App 才能清掉。
        var merged = Self.readEntries(bid: bid)
        for entry in entries where !merged.contains(where: { $0.name == entry.name && $0.kind == entry.kind }) {
            merged.append(entry)
        }
        let data = try JSONEncoder().encode(merged)
        try data.write(to: stateFileURL(for: bid), options: .atomic)

        // plugins.list 同样合并去重，保留“上次选择”的完整性
        var paths = Self.readPluginList(bid: bid)
        for url in assetURLs.map(\.path) where !paths.contains(url) {
            paths.append(url)
        }
        try paths.joined(separator: "\n")
            .write(to: plugInListURL(for: bid), atomically: true, encoding: .utf8)
    }

    /// 读取已有会话条目（不做存在性过滤：还原时必须按记录去摘 LC）。
    private static func readEntries(bid: String) -> [TempEntry] {
        let url = Constants.tempInjectRootURL
            .appendingPathComponent(bid, isDirectory: true)
            .appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TempEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// 读取上次记录的插件路径（原样返回，含已失效路径）。
    private static func readPluginList(bid: String) -> [String] {
        let url = Constants.tempInjectRootURL
            .appendingPathComponent(bid, isDirectory: true)
            .appendingPathComponent("plugins.list")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Plugins remembered from the last temporary injection, for one-tap reuse.
    func recordedPluginURLs(bid: String) -> [URL] {
        let fileManager = FileManager.default
        guard let content = try? String(contentsOf: plugInListURL(for: bid), encoding: .utf8) else {
            return []
        }
        return content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Locate the trollfoolscli binary shipped inside our own .app bundle.
    static var cliBinaryURL: URL? {
        let fileManager = FileManager.default
        let ownBundleURL = Bundle.main.bundleURL.appendingPathComponent("trollfoolscli")
        if fileManager.isExecutableFile(atPath: ownBundleURL.path) {
            return ownBundleURL
        }
        if let proxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let bundleURL = proxy.bundleURL() {
            let url = bundleURL.appendingPathComponent("trollfoolscli")
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Spawn the detached watchdog (trollfoolscli watch). The watchdog survives
    /// even if this app is suspended or killed by the user.
    func spawnWatchdog(bid: String) throws {
        guard let cliURL = Self.cliBinaryURL else {
            throw NSError(
                domain: Constants.gErrorDomain, code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("TempInjectCLIMissing", comment: "")]
            )
        }
        killWatchdog(bid: bid)

        // 用 setPid 确认 posix_spawn 真的成功：旧实现是 fire-and-forget，
        // 失败时照样写 state.json，留下“注入了但没人还原”的会话。
        var spawnedPid: pid_t = 0
        var spawnErr: NSString? = nil
        let spawned = TFExecuteSafely({
            AuxiliaryExecute.spawn(
                command: cliURL.path,
                args: ["watch", bid],
                setPid: { spawnedPid = $0 },
                completionBlock: nil
            )
        }, &spawnErr)
        guard spawned, spawnedPid > 1 else {
            if !spawned {
                // ObjC 异常级别的失败必须以 throw 传达，外层 catch 才能记日志
                throw NSError(
                    domain: Constants.gErrorDomain, code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "看门狗进程启动异常：\(spawnErr ?? "未知")"]
                )
            }
            throw NSError(
                domain: Constants.gErrorDomain, code: -2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("TempInjectCLIStartFailed", comment: "")]
            )
        }
    }

    func killWatchdog(bid: String) {
        let pidFileURL = stateDirURL(for: bid).appendingPathComponent("watchdog.pid")
        guard let content = try? String(contentsOf: pidFileURL, encoding: .utf8) else {
            return
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed), pid > 1 else {
            return
        }
        // pid 文件可能是上一次会话的残留，pid 被系统复用后会误杀无关进程。
        // 只有确认该 pid 仍是 trollfoolscli 才动手。
        if let path = ProcessUtil.executablePath(of: pid), path.hasSuffix("/trollfoolscli") {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Jump to the target app via SpringBoard.
    @discardableResult
    func launchApp(bid: String) -> Bool {
        // LSApplicationWorkspace 抛 ObjC 异常时 Swift 接不住，整个 App 闪退 ——
        // 用 TFExecuteSafely 兜住，失败让用户手动打开游戏。
        var err: NSString? = nil
        let ok = TFExecuteSafely({
            LSApplicationWorkspace.default().openApplication(withBundleID: bid)
        }, &err)
        if !ok {
            ImportEngine.shared.log("⚠️ 跳转失败（\(err ?? "未知")），请手动打开游戏")
        }
        return ok
    }

    /// On app start: restore orphan sessions whose watchdog has died,
    /// so temporary injections never outlive their session.
    private static let restoreQueue = DispatchQueue(label: "wiki.qaq.TrollFools.tempinject.restore")

    func cleanupOrphans() {
        // 两个入口（App.init 与首页 onAppear）都会调。旧实现两边各自起一个
        // global 队列，同一个会话可能被并发还原两次；后一次在 state.json 被删后
        // 走“无状态”分支，先把目录删了再和真正在跑的还原抢文件。这里串行化。
        Self.restoreQueue.sync { restoreOrphansLocked() }
    }

    private func restoreOrphansLocked() {
        let fileManager = FileManager.default
        guard let dirURLs = try? fileManager.contentsOfDirectory(
            at: stateRootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }
        for dirURL in dirURLs {
            guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let bid = dirURL.lastPathComponent

            // watchdog still alive? leave everything to it
            let pidFileURL = dirURL.appendingPathComponent("watchdog.pid")
            if let content = try? String(contentsOf: pidFileURL, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(trimmed), pid > 1, kill(pid, 0) == 0,
                   let path = ProcessUtil.executablePath(of: pid), path.hasSuffix("/trollfoolscli")
                {
                    continue
                }
            }

            // no session state? just clean the folder
            guard fileManager.fileExists(atPath: dirURL.appendingPathComponent("state.json").path) else {
                try? fileManager.removeItem(at: dirURL)
                continue
            }

            // 连续失败上限：每次重试都要阻塞最多 300 秒，而这类失败通常是永久性的
            // （二进制被别的工具改过、.bak 已丢失）。重试 3 次仍不行就停下，
            // 保留 state.json 与 .bak 供人工处理，不再拖慢每一次启动。
            let attemptURL = dirURL.appendingPathComponent("restore-attempts")
            let attemptText = ((try? String(contentsOf: attemptURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let attempts = Int(attemptText) ?? 0
            if attempts >= 3 {
                continue
            }

            // watchdog died without restoring: restore synchronously via CLI.
            // IMPORTANT: use the *blocking* spawn variant (waits via semaphore),
            // otherwise removing state.json below races the CLI startup and the
            // targeted restore degrades into a destructive ejectAll.
            guard let cliURL = Self.cliBinaryURL else {
                ImportEngine.shared.log("⚠️ 缺少 trollfoolscli，\(bid) 的残留注入无法自动还原（状态已保留）")
                continue
            }

            var receipt: AuxiliaryExecute.ExecuteReceipt?
            var restoreErr: NSString? = nil
            // 自动还原跑在 App 启动路径上 —— 这里抛 ObjC 异常就是
            // “每次打开 App 几秒后闪退”的直接原因，必须兜住。
            let spawnedRestore = TFExecuteSafely({
                receipt = AuxiliaryExecute.spawn(
                    command: cliURL.path,
                    args: ["watch", bid, "--timeout", "0"],
                    timeout: 300
                )
            }, &restoreErr)
            guard spawnedRestore, let receipt else {
                ImportEngine.shared.log("⚠️ 还原 \(bid) 时异常：\(restoreErr ?? "未知")（已保留状态，下次再试）")
                continue
            }

            // 只有确认还原成功才删状态。旧实现无论成败都删，
            // 一旦这次 eject 失败（插件已被系统清掉、Mach-O 被别的工具改过），
            // .bak 与 state.json 一起丢失 → 目标 App 留着指向已删 dylib 的
            // LC，启动即 dyld 崩溃，且再无自愈路径。
            var restored = false
            if case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS {
                restored = true
            }
            if restored {
                try? fileManager.removeItem(at: dirURL)
            } else {
                let next = attempts + 1
                try? String(next).write(to: attemptURL, atomically: true, encoding: .utf8)
                let marker = dirURL.appendingPathComponent("restore-pending")
                let stamp = ISO8601DateFormatter().string(from: Date())
                try? stamp.write(to: marker, atomically: true, encoding: .utf8)
                if next >= 3 {
                    ImportEngine.shared.log("❌ \(bid) 自动还原连续失败 \(next) 次，已暂停重试；状态与 .bak 保留")
                } else {
                    ImportEngine.shared.log("⚠️ \(bid) 还原失败（第 \(next) 次），下次启动继续重试")
                }
            }
        }
    }

    // MARK: - 待处理会话（供 UI 展示/手动还原）

    struct PendingSession {
        let bid: String
        let appName: String
        let attempts: Int
    }

    /// 列出“有会话状态、但看门狗已不在跑”的 App。
    /// 自动重试有上限，超过上限后必须留一个手动入口，否则用户只能重装 App。
    func pendingSessions() -> [PendingSession] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: stateRootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var result: [PendingSession] = []
        for dirURL in dirs {
            guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            guard fm.fileExists(atPath: dirURL.appendingPathComponent("state.json").path) else {
                continue
            }
            // 看门狗还活着 = 正在进行的会话，不列入待处理
            let pidFileURL = dirURL.appendingPathComponent("watchdog.pid")
            if let content = try? String(contentsOf: pidFileURL, encoding: .utf8),
               let pid = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 1, kill(pid, 0) == 0,
               let path = ProcessUtil.executablePath(of: pid), path.hasSuffix("/trollfoolscli")
            {
                continue
            }

            let bid = dirURL.lastPathComponent
            let attemptText = ((try? String(contentsOf: dirURL.appendingPathComponent("restore-attempts"), encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = LSApplicationProxy(forIdentifier: bid)?.localizedName() ?? bid
            result.append(PendingSession(
                bid: bid,
                appName: name,
                attempts: Int(attemptText) ?? 0
            ))
        }
        return result.sorted { $0.bid < $1.bid }
    }

    /// 手动还原一个会话：忽略自动重试上限，成功才删状态目录。
    @discardableResult
    func restoreNow(bid: String) -> Bool {
        guard let cliURL = Self.cliBinaryURL else {
            ImportEngine.shared.log("⚠️ 缺少 trollfoolscli，无法手动还原 \(bid)")
            return false
        }
        killWatchdog(bid: bid)
        let receipt = AuxiliaryExecute.spawn(
            command: cliURL.path,
            args: ["watch", bid, "--timeout", "0"],
            timeout: 300
        )
        var restored = false
        if case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS {
            restored = true
        }
        if restored {
            try? FileManager.default.removeItem(at: stateDirURL(for: bid))
            ImportEngine.shared.log("✅ \(bid) 已还原")
        } else {
            // 不重置失败计数：手动重试只给一次机会，避免又回到“每次启动都阻塞”的循环。
            ImportEngine.shared.log("❌ \(bid) 手动还原失败，状态与备份已保留")
        }
        return restored
    }
}
