# 权限与安全边界

## 监控与网络

CPU、内存、网络、温度及风扇读数在本机采集。普通监控无需 root。Clash 模块只访问本机控制接口，不切换代理配置；凭证只在运行时内存中使用，不写入偏好或诊断日志。

手动检查更新访问 GitHub 发布 API；“发布页”使用浏览器打开 GitHub。没有遥测，也不静默下载、安装或执行更新。发布页检查和 SHA-256 是完整性措施，不是 Apple 公证。

## 管理员助手安装

自定义调速需要 root 专用助手，首次应用才请求安装。助手只实现固定的目标设置、恢复和心跳协议，不提供任意 shell、任意文件写入或任意 SMC 键操作。

以下是固定产品路径，其中标识是产品历史标识，不是当前登录用户的主目录：

| 内容 | 路径 |
| --- | --- |
| 助手可执行文件 | `/Library/PrivilegedHelperTools/local.dingyuxuan.StateLite.FanHelper` |
| 身份 manifest | `/Library/PrivilegedHelperTools/local.dingyuxuan.StateLite.FanHelper.plist` |
| 恢复标记 | `/Library/PrivilegedHelperTools/local.dingyuxuan.StateLite.FanHelper.dirty` |
| launchd 配置 | `/Library/LaunchDaemons/local.dingyuxuan.StateLite.FanHelper.plist` |
| Unix socket | `/private/var/run/local.dingyuxuan.StateLite.fan.sock` |
| 排他锁 | `/private/var/run/statelite-fan.lock` |

安装文件由 root 所有。安装器在 root-owned 目录中暂存、核对运行代码与复制文件的身份，然后替换固定文件；失败时尝试回滚。回滚失败会保留恢复目录并报告位置，不能盲删。

系统原生 `/private/var/run` 可为 `root:daemon`、0775；代码仅对此精确目录及系统组做兼容，不放宽其他安装路径或文件的写权限，也不修改系统目录权限。

## 客户端身份与升级

socket 可连接不代表可控制。服务使用内核 audit token 检查实际对端用户和运行进程，再核对动态代码签名与固定 cdhash。应用及助手必须启用 Hardened Runtime，不允许动态库注入、禁用库验证、调试或可写可执行内存等例外。

manifest 绑定安装时的用户与代码身份。同一构建可复用安装；新构建或更换用户需要明确授权更新，不能依赖版本号绕过检查。它不是所有版本、所有用户都永久免密的通用服务。

初次安装、身份升级和卸载仍使用已弃用的 `AuthorizationExecuteWithPrivileges`。这条授权启动路径与用户可写应用包有边界，不能宣称首次安装可完全防御同用户恶意篡改；未来 macOS 也可能移除兼容。应用为 ad-hoc 签名，尚未经过 Apple 公证或建立 Developer ID 发行者信任链。

## 会话与恢复

客户端约每 2 秒发送心跳，助手维护约 10 秒失联期限，检查父进程身份，并进行跨实例排他。有效心跳可持续续租，没有旧版两分钟绝对上限。主应用不自动开机启动，也不在重新打开后自动恢复自定义目标。

助手按 socket 请求启动，闲置退出；启动时也检查遗留恢复标记。会话开始前落盘标记，确认恢复后删除。异常退出重启、再次启动或安装／卸载流程遇到标记时，会先尝试恢复；恢复未确认时拒绝继续接管。

目标先在助手校验范围，再执行模式和目标写入。只有全部风扇模式与目标读回连续匹配才确认应用。恢复时请求系统控制，等待全局状态与每只风扇模式连续匹配；不通过无条件写零目标掩盖失败。

助手监听睡眠请求，尝试恢复后才回应；客户端退出、屏幕休眠和系统睡眠也结束会话。这些是已实现机制，**真实睡眠、跨系统重启、崩溃恢复及卸载流程尚未完成验收**。

IOKit 阻塞可能越过循环预算。SIGKILL、断电、硬件或固件异常不受普通恢复代码控制；失联期限不是硬件级保证。恢复未确认时，应检查实际转速并保留诊断，不能仅凭面板未接管或程序已退出判断硬件状态。

## 报告问题

普通故障可提交 [Issue](https://github.com/ARMANDSnow/StateLite/issues)，注明应用版本、macOS 版本、机型、操作步骤和脱敏诊断。不要上传代理 secret、完整配置、个人路径或未经检查的原始日志。

对于可能导致越权的漏洞，优先使用仓库在 GitHub 上提供的私密漏洞报告入口（若已启用）；没有可用私密渠道时，先用不含利用细节的方式联系维护者，不要直接公开敏感数据。当前不承诺专门响应时限。
