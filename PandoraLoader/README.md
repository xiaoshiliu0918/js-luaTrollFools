# Pandora 加载器

一个 iOS 上的 **JS / Lua 运行时加载器**：容器 App 里管脚本，注入到目标 App 的 dylib 负责执行，改脚本不用重启目标 App。

不是 il2cpp 桥，不带 `CS.*` / `puerts`，不做内存读写 —— 它就是一个「把脚本塞进别人进程里跑」的壳。要挂 Unity 的 API，是在这个壳上再加一层，跟加载器本身是两件事。

---

## 一、结构

```
┌─────────────────────────────┐        ┌──────────────────────────────┐
│  容器 App（Pandora.app）      │        │  目标 App（如王者荣耀）        │
│                             │        │                              │
│  Documents/Scripts/*.js     │        │  PandoraLoader.dylib          │
│         │                   │        │        │                     │
│         ▼                   │        │        ▼                     │
│  脚本服务器 127.0.0.1:38999  │◀───────│  PdClient 每秒轮询 manifest   │
│                             │  HTTP  │        │                     │
│  注入按钮 ── task_for_pid ───┼───────▶│  JavaScriptCore / Lua 执行   │
└─────────────────────────────┘        └──────────────────────────────┘
```

**为什么走 socket 而不是共享目录**：注入进去的 dylib 跑在目标 App 的沙盒里，读不到容器 App 的 `Documents`。回环 TCP 不受文件沙盒限制，是唯一稳的通道。

**第二条通道（静态注入时更稳）**：容器 App 也能把脚本直接拷进目标沙盒的
`Documents/Pandora/scripts/`，注入端每秒比对该目录的 `_manifest.json`。这样**完全不依赖容器 App 在线**——
拷完就可以把它杀掉。socket 只是让热更新更快一点。

**为什么容器 App 要放静音音频**：它一进后台就被挂起，服务器就断了。`UIBackgroundModes: audio` + 一条静音循环把进程钉住（`PDKeepAlive`）。

---

## 二、构建

需要 macOS + Xcode 命令行工具：

```bash
brew install ldid
./build.sh
# → Pandora.tipa
```

`build.sh` 做四件事：编译 `payload/` 成 `PandoraLoader.dylib`（arm64 + arm64e fat），编译容器 App，用 `app/entitlements.plist` 签名，打包成 tipa。

**Lua 是可选的**。iOS 没有系统 Lua，要支持 `.lua` 得自己带源码：

```bash
git clone -b v5.4.6 --depth 1 https://github.com/lua/lua third_party/lua
./build.sh          # 自动检测并编译，日志会打印「内置 Lua：N 个对象」
```

不带也能用，只是 `.lua` 文件会被拒绝并提示「本包不含 Lua」。

---

## 三、安装与使用

1. TrollStore 装 `Pandora.tipa`（或越狱环境 `dpkg -i` 后 `uicache`）。
2. 打开 App，「脚本」页 → `+` 新建或右上角导入 `.js` / `.lua`。第一次启动会自动生成一个 `main.js` 示例。
3. 「注入」页 → 目标 App 右边 **「部署」** → 「注入并同步」。
   TrollStore 走这条路（会改包重签，自动备份可还原）；越狱设备也可以点整行做 attach 注入。
4. 「日志」页看 `[注入端]` 开头的行；有 `脚本环境就绪` 就说明脚本跑起来了。
5. 之后**改脚本、保存、「部署」→「同步脚本」**，1 秒内自动生效，不用重启游戏。

> 目标 App 的注入端日志也写在它自己的沙盒里：
> `<目标App容器>/Documents/Pandora/pandora.log`（Filza 可看）。

---

## 四、注入权限（这一节决定你能不能跑通）

注入 = `task_for_pid` 拿端口 + 远程 `dlopen`。iOS 16.2 / A16 上分三种情况：

| 环境 | attach 注入 | 说明 |
| --- | --- | --- |
| **已越狱（Dopamine 15.0–16.6.1）** | ✅ 可用 | 内核 `proc_enforce=0` + App 的 `task_for_pid-allow` 才生效。这是最省事的路 |
| **仅 TrollStore** | ❌ 基本不行 | `task_for_pid` 会被内核拒（`KERN_FAILURE`）。第三方签名的 `task_for_pid-allow` 不被采信 |
| **仅 TrollStore + TrollFools** | ⚠️ 一次性 | 用 TrollFools 把 `PandoraLoader.dylib` 静态注入目标 App（改 Mach-O + 重签 + 重装），**之后脚本照样热更新**，只是第一次要重装一次 App |

如果点注入报 `task_for_pid 失败`，就是权限问题，不是代码问题。App 会把这个原因原样弹出来。

**静态注入路线怎么走**：从 `Pandora.tipa` 里解出 `Payload/Pandora.app/PandoraLoader.dylib`，用 TrollFools 选中目标 App、选这个 dylib、注入。目标 App 启动后 `PdEntry` 会自动接管，剩下的和 attach 注入完全一样。

这条路和「98.db 插件」是同一个思路：**不 attach，把 dylib 直接塞进 App 包**。区别只在于 98.db 那种把 JS 明文藏在 `__ASSETS,__dfa` 段里、一次性烤死；这个加载器是从容器 App 拉脚本，能热更新。

### 为什么 kfd 救不了这条路

有人会想：TrollStore 上 `task_for_pid` 被拒，那用 kfd 拿内核读写不就行了？不行，卡在两处：

1. **kfd 只给读写，不给执行**。要让游戏跑你的 JS，必须在**目标进程里执行代码**（`dlopen` 或调 `JsEnvManager.Eval`）。执行代码要么有 task port 去 `thread_create_running`，要么让 dyld 在启动时把 dylib 加载进来。kfd 能把 `proc_enforce` 写成 0 让 `task_for_pid` 放行，但——
2. **拿到 task port 之后还有 AMFI**。App Store 应用带 `CS_REQUIRE_LV`，`dlopen` 只认同 Team 签名的镜像；而放行未签名 dylib 要动 trust cache / 改 `csflags`，那是 PPL + 内核 text 的活（A12 以上有 KTRR，`__TEXT` 写不了）。Dopamine 能行是因为它带整套 PPL bypass + AMFI patch + trust cache 注入，kfd 只是里面的一根读原语。

所以 kfd 的正当用法是**不注入**：像 `ESP_骨架` 那样，独立 App 用内核读原语读游戏内存，外部绘制。要跑 `绘制.js` 这种依赖 Unity 运行时的脚本，必须进进程，那就绕不开下面两条路之一。

另一个已知限制：`dlopen` 还有一道**库校验**（library validation）。App Store 签名的进程默认只加载同 Team 签名的 dylib。越狱环境 AMFI 被绕过没问题；TrollStore 下如果 `dlopen` 失败但 `task_for_pid` 成功，多半是这一关卡住了 —— 同样改用静态注入。

---

## 五、脚本 API

### JavaScript（JavaScriptCore）

```js
console.log('hi', 1, {a: 2});       // 输出到「日志」页
var t = setTimeout(fn, 500);        // 帧驱动，不是真线程
var i = setInterval(fn, 1000);      // 用完 clearInterval(i)

onTick(function (dt) { /* 每帧，约 30fps */ });
onUnload(function () { /* 重载/退出前清理 */ });

Native.info      // { bid, pid, root, ios }
Native.log(...)  // 同 console.log
Native.reload()  // 立刻重拉脚本
Native.read('x.txt') / Native.write('x.txt', '...')   // 相对 <沙盒>/Documents/Pandora
```

一个 bundle 里的文件按 **`main.*` → js → lua → 文件名** 的顺序在同一个全局作用域执行，所以 `main.js` 适合当入口。**一个 bundle 只能是一种语言**（以第一个文件为准）。

脚本死循环有 3 秒上限（`JSContextGroupSetExecutionTimeLimit`），超时会被中断并记一条日志。

### pjs —— 跑在游戏自己的 PuerTS 里（能用 `CS.*`）

把文件命名成 `.pjs`。加载器不会建自己的 JS VM，而是用 `il2cpp` 找到游戏的
`com.tencent.pandora.JsEnvManager`，调 `GetJsEnv()` → `Eval(js, chunk)`，
脚本直接进游戏现成的 PuerTS 虚拟机。

```js
const U = CS.UnityEngine;                 // 白拿，不需要任何桥
const go = new U.GameObject('probe');
console.log(Native.info.bid);             // 落到游戏沙盒 Pandora/js.log，自动转发到日志页
onTick(function (dt) { /* 由 PuerTS 的 setInterval 驱动 */ });
onUnload(function () { /* 重载前调用 */ });
```

**前提**：游戏内置 PuerTS（王者 S45 有，`JsEnvManager` 在 `Scripts.Plugins.dll` 里）。
找不到会明确报 `没找到 com.tencent.pandora.JsEnvManager`。

**注意**：这条路上没有真正的“卸载”。重载 = 再 `Eval` 一次，旧脚本的定时器、画布要
脚本自己在 `onUnload` 里清掉，否则会叠。

### Lua（需要内置 Lua 5.4）

```lua
native.log("hi from " .. (native.bid or "?"))
function on_tick(dt) end
function on_unload() end
print = native.log
```

Lua 侧有指令数 hook，单次执行超过 500ms 直接报错，不会把游戏卡死。

---

## 六、协议（可以直接 curl 调试）

```bash
curl 'http://127.0.0.1:38999/ping'
curl 'http://127.0.0.1:38999/manifest?bid=test&ver=0'
curl 'http://127.0.0.1:38999/file?name=main.js'
```

```
GET /manifest?bid=&ver=&token=   → {"proto":1,"ver":1731999999123,"files":[{name,lang,size,mtime}]}
GET /file?name=                  → 原始字节
GET /log?msg=                    → 注入端日志回传
GET /state?bid=&ver=&pid=&msg=   → 心跳
GET /ping                        → pong
```

`ver` 是「所有脚本 mtime 的最大值 × 1000 + 文件数」。客户端比对不上才去拉文件，所以平时开销就是一个几百字节的响应。

---

## 七、代码地图

| 文件 | 作用 |
| --- | --- |
| `common/PdProtocol.h` | 线协议（端口、token、路径） |
| `payload/PdEntry.mm` | dylib 构造函数：判断进程、等 UI 起来、启动 |
| `payload/PdClient.mm` | 轮询 / 拉取 / 应用 / 帧循环 / 缓存 |
| `payload/PdJS.mm` | JavaScriptCore 宿主 + 原生函数 |
| `payload/prelude.js` | console / 定时器 / onTick / Native（生成 `PdPrelude.h` 嵌入） |
| `payload/PdPandora.mm` | pjs 运行时：il2cpp 反射调游戏自己的 `JsEnvManager.Eval` |
| `payload/PdLua.mm` | Lua 5.4 宿主（`#if __has_include("lua.h")`） |
| `payload/PdHttp.m` | 极简 HTTP 客户端（带超时） |
| `inject/remote.c` | task_for_pid + 远程 dlopen（ARM64 桩） |
| `app/PDStore.m` | 脚本仓库 + 版本号 |
| `app/PDHostServer.m` | 回环 HTTP 服务器 |
| `app/PDTargets.m` | App 列表 + 脚本同步（按 App 绑定过滤） |
| `app/PDPatch.m` | 静态注入：备份 / LC_LOAD_DYLIB / 重签 / ct_bypass / 回滚 |
| `app/PDTools.m` | 借 TrollFools 的工具链（libiosexec 的 ie_posix_spawn） |
| `app/PDUI.m` | 三个页签：脚本 / 注入 / 日志 + 后台保活 |

改 `prelude.js` 之后要重新生成嵌入头：

```bash
python3 tools/embed.py
```

---

## 八、已知限制

- **注入权限**：见第四节，非越狱环境 attach 走不通，只能静态注入一次。
- **一个 bundle 一种语言**：不支持 js 和 lua 混跑（两个 VM 各自独立）。
- **没有模块系统**：多文件靠执行顺序 + 全局变量。
- **定时器是帧驱动的**：目标 App 进后台、没有渲染帧时不走。
- **`.js` 没有 il2cpp 桥**：自建 JSC 里拿不到 `CS.UnityEngine`。要挂 Unity API，用 `.pjs` 走游戏自己的 VM，或者另加一层反射桥。
- **`.pjs` 依赖游戏内置 PuerTS**：没有 `JsEnvManager` 的游戏用不了；而且脚本与游戏共享一个 VM，写坏了会影响同一个上下文。
- **容器 App 被杀 = 服务器断**：注入端会退回本地缓存，但热更新停摆，直到容器 App 再次打开。

---

## 九、TrollStore：一个包搞定

不需要手动导出 dylib，也不需要切到 TrollFools 里挑文件。注入这件事 Pandora 自己会做。

### 前提

设备上**装着 TrollFools**（不用打开它）。Pandora 借它的四个工具：
`insert_dylib`、`ldid`、`ct_bypass`、`libiosexec.1.dylib`。
这比你手动操作更可靠——参数和顺序都是从 TrollFools 的实现里对齐的。

> 想彻底不依赖 TrollFools：把那四个文件放进工程的 `tools_bin/` 再打包，
> `build.sh` 会把它们塞进 `Pandora.app/tools/`，`PDTools` 优先用自带的。

### 操作

1. TrollStore 装 `Pandora.tipa`。
2. 「脚本」页准备好要跑的 `.js` / `.pjs` / `.lua`。
3. 「注入」页 → 目标 App 右边 **「部署」**。
4. 选 **「注入并同步」** → 确认。它会依次做：

   ```
   备份可执行文件 → .pandora.bak
   ldid -e            取出原 entitlements
   cp dylib           → Target.app/Frameworks/
   insert_dylib       → 加一条 LC_LOAD_DYLIB
   ldid -S<ent>       → 重签
   ct_bypass -a       → 打 CoreTrust 补丁（不打这个，改过的 App 一启动就闪退）
   syncScripts        → 把绑定给这个 App 的脚本写进它的沙盒
   ```

5. 启动游戏。日志页出现 `[注入端]` 即成功。
6. 之后改脚本：**「部署」→「同步脚本」**，游戏不用重启。

### 选择这个游戏加载哪些脚本

「部署」→「选择脚本…」，勾选后保存。绑定按 bundle id 存，多开几个游戏各用各的脚本。
全选等于不记录绑定，以后新增的脚本会自动带上。

### 还原

「部署」→「还原（撤销注入）」。用 `.pandora.bak` 覆盖回去（原始字节含原签名），
再删掉 `Frameworks/PandoraLoader.dylib`。游戏回到注入前的状态。

注入过程中任何一步失败都会**自动回滚**，不会留下打不开的包。

### 三件必须知道的事

| 事项 | 说明 |
| --- | --- |
| 游戏更新 | 更新会替换整个包，注入和备份一起没了，重新部署一次即可 |
| 完整性检测 | 改过包的 App 可能被游戏自己的校验拦下；这一步没有通用解 |
| 签名失败 | 报 `ct_bypass` 失败通常是原 binary 不是 adhoc 签名，把输出发我 |

---

## 十、排错

| 现象 | 看这里 |
| --- | --- |
| 注入报 `task_for_pid 失败` | 没越狱 / 没权限，见第四节 |
| 注入报 `dlopen 没有生效` | 库校验或路径不可读，改用静态注入 |
| 日志里没有 `[注入端]` | 容器 App 在后台被挂起，确认「后台保活已开启」那行 |
| `等容器 App（connect 超时）` | 目标连不上 38999，检查容器 App 是否在运行 |
| 脚本没输出 | 「日志」页确认 `main.js` 是否在列表里；`console.log` 打到 `[注入端]` 行 |
