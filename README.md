# SLTrollFools

基于 [TrollFools](https://github.com/Lessica/TrollFools) 的个人定制分支（石榴动态注入）。

- **画面**：液态磨砂玻璃（柔光壁纸底 + 独立磨砂卡 / 半透提亮 + 雾层 + 顶棱高光），深色与浅色两套主题
- **动效**：HGhubX 弹性体系（主弹簧 `response .42 / damping .62`、按下 0.965、逐条上浮入场）
- **最低系统**：iOS 14.0（玻璃层在 iOS 15+ 才叠加 `ultraThinMaterial`，14 上退化为半透 + 雾层，观感一致）

三栏结构：**应用 / 注入 / 暂存箱**。

## 脚本加载器（可选）

注入页多了一块「脚本」：勾上 `.js` / `.pjs` / `.lua`，注入时会自动带上
`PandoraLoader.dylib`，并把脚本写进目标沙盒的 `Documents/Pandora/scripts/`。
之后改脚本只要重新部署一次，不用重新注入、不用重启游戏。

需要先把编译好的 `PandoraLoader.dylib` 放进 `TrollFools/` 目录（`devkit/tipa.sh` 会自动打进包）。
细节见 [PANDORA.md](PANDORA.md)。

## 磨砂玻璃怎么成立

模糊只对「背后有明暗变化的像素」有效，背后是纯色面板时 `backdrop-filter` / `Material` 等于没开。
所以主界面用 `LiquidGlassBackground` 先铺一张程序化生成的柔光壁纸（线性渐变 + 多个大半径径向光斑，固定种子保证每次启动一致），
卡片再按六层叠加：

| 层 | 作用 |
|---|---|
| ① 提亮半透底 | 深色 `rgba(146,184,242,.085)` / 浅色 `white .52`——**必须比背景亮一档**，压暗会「陷」下去 |
| ② `.ultraThinMaterial` | 真模糊（iOS 15+），采到的是背后壁纸 |
| ③ 透光渐变 | 148° 斜向高光，制造玻璃厚度 |
| ④ 雾层 | 极低透明度冷白，压住壁纸细节、统一色调 |
| ⑤ 顶棱描边 | 顶部白 26% → 底部白 9%，玻璃边缘的反光 |
| ⑥ 底边暗线 | 1px，给卡片一个「压住」的实感 |

注意：卡片**不能**加 `.compositingGroup()`，会切断 Material 对外部背景的采样，磨砂直接失效。

## 下载

在 [Releases](../../releases) 下载 `SLTrollFools-*.tipa`，用 TrollStore 直接安装。

也可以从 Actions 的构建产物 `SLTrollFools-x.y-z` 里取。

## 构建

`.github/workflows/build-tipa.yml` 在 push 到 `main` 时用 macOS runner + Theos 打包：

```bash
make package FINALPACKAGE=1
```

产物落在 `packages/*.tipa`（Theos 输出的中文名会被工作流复制并重命名为 `SLTrollFools-<版本>-<构建号>.tipa`）。

## 目录

| 路径 | 说明 |
|---|---|
| `TrollFools/TempHome.swift` | 主界面三个页面 + 磨砂玻璃组件 + 注入/暂存数据层 |
| `TrollFools/PandoraLoader.swift` | 脚本仓库 / 绑定 / 沙盒部署 / 编辑器（见 PANDORA.md） |
| `TrollFools/TrollFoolsApp.swift` | App 入口（跟随系统深浅色） |
| `TrollFools/Execute.swift` | 进程枚举 / 精确杀进程（`KERN_PROCARGS2` 读 argv[0]，避开 `p_comm` 15 字节截断） |
| `TrollFools/InjectorV3+*.swift` | 注入引擎：备份回滚、Mach-O 处理、持久化 |
| `TrollFoolsTweak/` | 注入用的 Swift 运行时（dylib 侧） |
| `devkit/tipa.sh` | Theos 打包后处理：拼 Payload、签名、zip 成 tipa |

## 相对上游的行为修正

- **杀进程**：旧实现比对 `kinfo_proc.p_comm`，内核截断到 15 字节，`UnityFramework` 或同名 demo 会撞车 → 改读 argv[0] 完整路径精确匹配
- **CLI 持久注入**：`inject` 子命令改为 `shouldPersist: true`，否则 `ejectAll` 无从清理
- **插件路径**：`URL(string:)` 遇到空格/中文/百分号会拿到错误 URL → 改 `URL(fileURLWithPath:)`
- **会话状态**：`state.json` 由覆盖改为合并，避免同一 App 先后注入 A、B 时 A 的 dylib 永久残留
- **看门狗**：启动失败不再判定为注入失败（插件其实已生效），降级为下次打开 App 时由 `cleanupOrphans` 还原
- **备份回滚**：新增 `restoreAllAlternates()`，插件文件被系统清理后可整体回滚 `.bak`，避免目标 App 带着失效 LC 崩溃
- **资源缺失**：`fatalError` 全部改为 `throw`，缺资源时给可读提示而不是闪退

## 上游信息

In-place tweak injection with insert_dylib and ChOma.
Expected to work on all iOS versions supported by opa334's TrollStore (i.e. iOS 14.0 - 17.0).

- [ChOma](https://github.com/opa334/ChOma) by [@opa334](https://github.com/opa334) and [@alfiecg24](https://github.com/alfiecg24)
- [MachOKit](https://github.com/p-x9/MachOKit) by [@p-x9](https://github.com/p-x9)
- [insert_dylib](https://github.com/tyilo/insert_dylib) by [@tyilo](https://github.com/tyilo)

## License

See [LICENSE](LICENSE).
