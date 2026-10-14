# 开发与验证

## 准备环境

构建目标为 macOS 14+、arm64。需要 Apple Command Line Tools（Swift、Clang、codesign）以及 Python 3；不依赖第三方 Swift 包。

```sh
xcode-select --install
# 已安装时无需重复执行上一步
swift --version
clang --version
python3 --version
git clone https://github.com/ARMANDSnow/StateLite.git
cd StateLite
./test.sh
./build.sh
```

构建产生 `StateLite.app` 和 `StateLite.zip`；本地 ZIP 名称与正式发布的版本化资产名称不同。生成物和 `.build/` 不应提交。`build.sh` 在私有临时目录构建、签名，最后复制应用和 ZIP；运行构建不会安装系统助手或写风扇。

应用与助手启用 Hardened Runtime，使用 ad-hoc 签名，不开启动态库注入或调试例外。主程序摘要与助手身份绑定，修改源码后必须完整重建，不能混用两个构建的主程序和助手。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `Sources/main.swift` | AppKit 生命周期、采样调度、菜单栏、集成和 CLI 入口 |
| `Sources/PanelViewController.swift` / `PanelComponents.swift` | 面板、设置、目标草稿与状态展示 |
| `Sources/Metrics.swift` | CPU tick、内存和网络差值计算 |
| `Sources/Temperature.swift` / `TemperatureBridge.c` | 只读温度接口 |
| `Sources/UpdateChecker.swift` | 手动查询正式发布，校验版本与发布资产 URL |
| `Sources/ProxyMonitor.swift` | 本地 Clash 状态与响应解析 |
| `Sources/Fan.swift` | 只读风扇采样、授权客户端、请求与回执匹配 |
| `Sources/FanBridge.c` / `FanServiceClient.c` | SMC 数据接口、客户端连接及安装授权入口 |
| `Sources/FanHelper.c` | 有界目标协议、读回确认、租约和系统恢复 |
| `Sources/FanService.c` | root-owned 安装、身份固定、按需服务、回滚与卸载 |
| `Sources/FanLease.h` | 租约有效性条件 |
| `Resources/Info.plist` | 应用标识、版本及最低系统要求 |
| `Tests/` | 指标、偏好、代理、协议、签名和失败路径测试 |

系统助手使用固定产品标识；修改标识或路径属于安装迁移，不能仅改应用名称就假定旧助手随之更新。

## 无硬件测试

```sh
./test.sh
```

测试使用 mock SMC、临时 socket、测试进程及 ad-hoc 签名验证，包含计数重置、请求编号隔离、转速范围、配对读回、失败恢复和代码身份检查。部分失败用例会刻意输出 `ERROR`；应以断言和进程退出状态判断测试结果。测试不安装系统服务，也不对真实风扇写入。

不要把 `--fan-verify` 加入普通 CI。真实安装、睡眠、卸载、重启和调速各自需要独立验收；目前已记录的硬件结果见 [CHANGELOG](../CHANGELOG.md)。

## 视觉与只读验证

```sh
codesign --verify --deep --strict StateLite.app
StateLite.app/Contents/MacOS/StateLite --fan-install-preflight
StateLite.app/Contents/MacOS/StateLite --snapshot
StateLite.app/Contents/MacOS/StateLite --preview --appearance=light
# 关闭预览后再检查深色
StateLite.app/Contents/MacOS/StateLite --preview --appearance=dark
```

预览窗口与真实弹出面板共享界面，但普通窗口验证不能证明菜单栏定位或刘海附近可见性。预览不会自动写风扇，**其中的风扇按钮仍是可用操作，不是隔离的假界面**。

修改面板时检查：一项／两项菜单指标、深浅色、设置返回、滚动、键盘导航、错误全文、未应用草稿、关闭重置。主线程不应执行授权等待或网络请求；硬件调用按串行采样管理。

## 风扇开发边界

- 用户明确点击应用后才发送目标。限制在全部已发现风扇 ID 及各自硬件范围内。
- 只有对应请求的模式／目标读回确认后才显示已应用；实际 RPM 达标是另外的证据。
- 退出、失联和失败统一尝试恢复。恢复未确认时保留错误与标记，不写虚假的“系统已恢复”。
- 固定目标不是自动温控。不要把合法 RPM 范围或当前温度读数当成未来负载下的安全保证。
- 权限变更需检查安装身份、磁盘所有权、socket 对端身份、升级回滚和卸载路径。
- IOKit 同步调用可能阻塞；循环中的预算并不能中断单次系统调用。

实机验收命令、退出码和独立 watchdog 见 [INSTALL.md](INSTALL.md)。先审阅变更并确认目标机器与用户意图，不能因测试脚本通过就自动执行硬件验收。

## 提交与发布

公开仓库不包含本机原始测量文件、代理配置、用户偏好或含个人路径的验收日志。提交前检查新增文件和文档中的绝对路径及凭证。版本发布、CI 与用户升级步骤见 [UPDATING.md](UPDATING.md)。

仓库暂未授予开源许可。第三方算法、代码或素材引入时，应单独核对来源和许可；公开源码不表示可以省略许可审核。

## 发布包与可选 Apple 签名

```sh
RELEASE_OUTPUT_DIR="$PWD/dist" RELEASE_TAG=v0.5.0 ./build.sh
```

发布构建不覆盖本地 `StateLite.app`，生成版本化 ZIP、`SHA256SUMS`、`release-metadata.json`。元数据记录源码提交、工作树是否有改动、应用/助手签名身份、主程序配对摘要和公证验证结果。`notarization: not-verified` 不等于已公证；只有 `stapled-valid` 表示已验证附带票据。检查脚本不运行硬件控制。

默认无需秘密配置，产生 ad-hoc 包。若维护者以后具备 Apple Developer ID，可在仓库 Actions secrets 中同时配置：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_BASE64` | Developer ID Application 证书及私钥的 P12 文件，Base64 编码 |
| `MACOS_CERTIFICATE_PASSWORD` | P12 导出密码 |
| `MACOS_SIGNING_IDENTITY` | 完整 Developer ID Application 签名身份 |
| `NOTARY_APPLE_ID` | Apple 公证账号，仅在启用公证时提供 |
| `NOTARY_TEAM_ID` | 对应开发团队 ID |
| `NOTARY_APP_PASSWORD` | 对应账号的 app-specific password |

前三项须完整配置；后三项启用公证时须完整配置，且必须先配置签名。凭证仅进入标签发布 job 的临时钥匙串，清理步骤在失败时也执行；不要提交 P12 或凭证到仓库。普通 PR / main CI 始终使用 ad-hoc 构建。此可选签名、公证分支尚未用真实 Developer ID 凭证端到端验收。

本机签名可用 `SIGNING_IDENTITY`；公证可用预先通过 `xcrun notarytool store-credentials` 配置的 `NOTARY_KEYCHAIN_PROFILE`，可选 `NOTARY_KEYCHAIN` 指定钥匙串路径。不要把密码放在命令历史或公开日志里。
