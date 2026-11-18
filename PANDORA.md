# 脚本加载器（PandoraLoader）

在 SLTrollFools 里加的一层能力：**注入 dylib 的同时，把选中的 js / lua 脚本部署到目标 App 的沙盒里**。
一个 tipa 就够，不用再装第二个 App，也不用导出 dylib 手动丢进 TrollFools。

---

## 1. 它解决什么

原来跑脚本要两步：TrollFools 注入 `PandoraLoader.dylib` → 另外把脚本拷进游戏沙盒。
现在合成一步：**注入页勾脚本 → 点「注入并启动」**，dylib 和脚本一起进去。

```
[SLTrollFools] 选目标 App
      ↓
   勾脚本 (.js / .pjs / .lua)
      ↓
   注入并启动
      ├─ ① 脚本写进 <目标沙盒>/Documents/Pandora/scripts/ + _manifest.json
      ├─ ② 自动追加 PandoraLoader.dylib 到注入列表
      ├─ ③ InjectorV3 原位注入（备份 / LC_LOAD_DYLIB / 重签 / CoreTrust 补丁）
      ├─ ④ 起看门狗（退出即还原）
      └─ ⑤ 跳转目标 App
```

注入端（dylib）每秒比对 `_manifest.json` 的 `ver`，变了就重新加载。
所以**改脚本只要重新部署一次「脚本」，不用重新注入、不用重启游戏**。

---

## 2. 前置：把 dylib 放进包里

`PandoraLoader.dylib` 的源码在 `E:\桌面\PandoraLoader`，用那边的 `build.sh` 或 GitHub Actions 编出来，
然后：

```bash
unzip -o Pandora.tipa 'Payload/Pandora.app/PandoraLoader.dylib' -d /tmp/pd
cp /tmp/pd/Payload/Pandora.app/PandoraLoader.dylib  SLTrollFools/TrollFools/
```

**也可以完全不用手动拷**：`.github/workflows/build-tipa.yml` 里加了一步
`Fetch PandoraLoader.dylib (optional)` —— 工程里没有这个文件时，会从
`xiaoshiliu0918/PandoraLoader` 的最新 Release 按名字拉 `PandoraLoader.dylib`。

要让这一步生效，需要：

1. `E:\桌面\PandoraLoader` 推到 `xiaoshiliu0918/PandoraLoader`（私有库也行）；
2. 给它打个 tag（`git tag v1 && git push --tags`），那边的 workflow 会把
   `Pandora.tipa` 和 `PandoraLoader.dylib` 一起发到 Release；
3. 如果那个库是私有的，在 SLTrollFools 的仓库设置里加 secret `PANDORA_TOKEN`
   （有 `repo` 权限的 PAT）—— 默认的 `GITHUB_TOKEN` 跨仓库读不到私有内容。

拉不到不会让构建失败，只是打出一个不含加载器的包（注入页会显示「缺少 PandoraLoader.dylib」）。

`devkit/tipa.sh` 会检测到这个文件并把它拷进 `Payload/TrollFools.app/`：

```
==> 打包脚本加载器 PandoraLoader.dylib
```

没有这个文件也能打包，只是注入页会显示「缺少 PandoraLoader.dylib」，此时只能注入普通插件。
（也可以把 dylib 丢进暂存箱，`PandoraLoader.payloadURL()` 会去那里找 —— 但不推荐，容易注错版本。）

为什么放在 `.app` 根目录而不是 Xcode 的 Resources：`payloadURL()` 的查找顺序是
`Bundle.main` 资源 → 可执行文件同目录 → 暂存箱。tipa.sh 拷到可执行文件同目录，
不依赖 pbxproj，换 dylib 版本只要重新打包，不用动工程文件。

---

## 3. 脚本放哪

```
/var/mobile/Library/TrollFools/Pandora/
├── Scripts/                ← 脚本仓库（.js / .pjs / .lua）
│   ├── 绘制.pjs
│   └── demo.lua
└── bindings.json           ← 每个 App 绑定了哪些脚本
```

三个入口都能改这个目录：

| 方式 | 说明 |
| --- | --- |
| 注入页的下载按钮 | 从「文件」App 选，支持多选；重名按内容覆盖，内容没变就跳过 |
| 点脚本行 | 内置编辑器直接改，等宽字体，保存即成 |
| Filza | 直接编辑 `Scripts/` 下的文件 |

部署时**目录会被对齐**：不在本次名单里的旧脚本会被删掉，避免加载器把上次残留的也跑一遍。

---

## 4. 三种运行时，选一种

脚本按扩展名分三条路，**同一个 App 只能跑一种**（加载器只按第一个文件的 lang 起运行时）：

| 扩展名 | 运行时 | 能拿到什么 | 适合 |
| --- | --- | --- | --- |
| `.js` | 自带 JavaScriptCore | `console` / `setTimeout` / `onTick` / `Native.*` | 纯计算、日志、定时任务 |
| `.pjs` | **游戏自己的 PuerTS** | 上面这些 **+ `CS.*`（Unity 全量 API）** | 要画 UI、读 Actor、调游戏方法 |
| `.lua` | 自带 Lua 5.4（需打包时内置） | `print` / `onTick` / `onUnload` | 轻量脚本、低开销长挂 |

UI 里点选另一语言的脚本会自动取消前一种，不会让你选出一个跑不了组合。

> `.pjs` 走 `il2cpp` 找 `com.tencent.pandora.JsEnvManager` 再调 `Eval`，
> 前提是目标游戏内置 PuerTS（王者 S45 有）。找不到会在日志里明确写出来。

脚本 API：

```js
console.log(...)                 // 落到 <沙盒>/Documents/Pandora/pandora.log，回传到日志页
setTimeout(fn, ms) / setInterval(fn, ms)
onTick(function (dt) { })        // 每帧，dt 秒
onUnload(function () { })        // 重载前调用，清定时器 / 画布
Native.log(msg)                  // 同上
Native.reload()                  // 强制重载
Native.read(path) / Native.write(path, text)
Native.info                      // { bid, root, pid, ios }
```

`.js` 有 3 秒执行上限，`.lua` 有 500ms 指令 hook —— 死循环不会把游戏卡死。

---

## 5. 绑定：每个 App 用哪些脚本

勾选状态按 **bundle id** 存在 `bindings.json`（勾一下就写，取消干净就删掉该键）：

```json
{ "com.tencent.smoba": ["绘制.pjs", "camp.lua"] }
```

- **部署的就是勾中的那些**，没勾的一律不动
- 一个都不勾 = 不写脚本、不注入加载器，和原来的插件注入完全一样
- 绑了但文件被删 → 部署时自动忽略，不会报错
- 换目标 App 时勾选状态跟着切（按 bid 读）

> `PandoraScriptStore.effectiveScripts(bid:)` 还有一套「没绑定就用数量最多的那一组」的默认值，
> 目前只给以后可能的 CLI 用，UI 不走它 —— UI 永远是显式勾选。

---

## 6. 临时注入 vs 持久注入

默认走**临时注入**（`shouldPersist: false`）：退出目标 App 后看门狗自动还原，
App 回到干净原版，想再跑就回 SLTrollFools 点一次。

这对脚本加载器反而更合适：

- 脚本留在沙盒里不碍事（dylib 被摘了就不会执行）
- 下次部署会覆盖 `_manifest.json`，版本号一变立刻重载
- 不会因为忘了清理，让游戏长期带着一个改过的包

要长期挂着的，用「应用」页 → 选 App → 普通「注入」（持久），
但那样每次改脚本都得重新部署脚本目录 —— 见下一节。

---

## 7. 只更新脚本（不重新注入）

注入已经生效、游戏还开着的时候，只想换脚本：

1. 注入页勾新的脚本组合
2. 点「注入并启动」

它会重新走一遍注入。**这会杀掉正在运行的游戏**（`InjectorV3` 注入前必须终止进程）。

如果不想断游戏，就直接写文件 —— 加载器每秒扫一次：

```bash
# 在设备上（Filza / SSH）
DOCS=/var/mobile/Containers/Data/Application/<UUID>/Documents/Pandora/scripts
cp 新脚本.pjs "$DOCS/"
# 然后把 _manifest.json 的 ver 改成任意新数字
```

改完 1 秒内生效。`ver` 是唯一的触发条件，不认识文件变化本身。

---

## 8. 排错

| 现象 | 原因 |
| --- | --- |
| 「缺少 PandoraLoader.dylib」 | dylib 没放进 `TrollFools/` 就打包了，见第 2 节 |
| 「拿不到目标数据容器」 | 目标 App 从没启动过，系统还没建容器。先手动启动一次再部署 |
| 注入成功但日志没有 `[注入端]` | dylib 没被加载。看 `<沙盒>/Documents/Pandora/pandora.log`，或确认注入的确实是 `PandoraLoader.dylib` |
| 有日志但脚本没跑 | `_manifest.json` 里的 `files` 为空，或 `lang` 与文件实际类型不符 |
| 脚本报语法错误 | 看日志页的 `[js] xxx 执行失败` / `[lua] xxx 执行失败`，会带原始异常 |
| `.pjs` 报找不到 `JsEnvManager` | 这个游戏没有内置 PuerTS，只能用 `.js` 或 `.lua` |
| 改脚本没反应 | 没重新部署，也没手动改 `ver`。加载器只认 `ver` 变化 |

日志位置：

```
<目标沙盒>/Documents/Pandora/pandora.log   注入端自己的日志
<目标沙盒>/Documents/Pandora/js.log       .pjs 的 console 输出（PuerTS 里没有原生通道）
```

两个都会通过 socket 回传到 SLTrollFools 的日志页（容器 App 在后台时）。

---

## 9. 代码位置

| 文件 | 内容 |
| --- | --- |
| `TrollFools/PandoraLoader.swift` | 脚本仓库 / 绑定 / 部署 / 编辑器 / 选择模型 |
| `TrollFools/TempHome.swift` | `GameInjector.injectAndLaunch(... scriptNames:)` + 注入页的脚本区块 |
| `devkit/tipa.sh` | 把 `TrollFools/PandoraLoader.dylib` 打进 `.app` |

注入本身完全复用 `InjectorV3`（备份 / 回滚 / LC / 重签 / ct_bypass / 看门狗），
这一层没有改动，只是多传一个文件、多写一个目录。
