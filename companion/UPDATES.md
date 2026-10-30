# Android 伴生端更新

当前伴生端：**3.7.1（Android version code 8）**。Kilo 配额恢复现在
接受所有 Kilo 免费模型写法：以 `free` 结尾的模型 ID，位于
`:`、`/` 或 `-` 分隔符之后，因此 `reflection/beam-free` 和 `openrouter/free`
会像 `:free` 路由一样通过隧道恢复。回复仍限制在
8 MiB，过大的回复仍返回状态 413，而不会重新提交推理。APK 保留现有的生产签名
身份和应用程序 ID。

伴生端会在启动时以及其应用或中继进程存活期间每 15 分钟检查官方
`Project-Ptolemy/ProjectUAI` GitHub 发布。兼容的更新默认会自动下载。关闭
**Download updates automatically** 会保留元数据检查；**Check now** 或
**Download update** 会执行一次显式下载。经过校验的下载在应用重启后仍然保留，
并在安装前再次校验。

**Install update** 会把经过校验的 APK 放入一个由 UAI Relay 拥有的 Android 安装
会话中。Android 要求用户允许从 UAI Relay 安装并确认更新；普通的侧载应用无法
静默替换自身。如果仍有活动请求或保留的回复，请在空闲时再次尝试 Install。
检查和下载不会停止推理。

安装一旦开始，新的提交会被临时拒绝，而不会被转发。待处理的会话会在进程重启后
保留。如果应用处于后台时 Android 的确认已就绪，**Continue installation** 会在
你返回时打开它。**Resume relay** 会通过放弃其拥有的 Android 会话，在重新开放
准入之前取消一次被中断的尝试。如果 Android 无法放弃该会话，准入会保持暂停。
经过校验的下载仍可用于另一次尝试。如果进程死亡丢失了 Android 的待定确认提示，
请使用 Resume relay，然后再次尝试 Install。在 Android 报告成功之后，旧进程会
保持暂停，直到匹配的已更新应用启动。安装前正在运行的中继可以在被替换后恢复；
显式的 Stop 会被保留。

## 签名连续性

每个生产 APK 都必须保留应用程序 ID `dev.projectuai.relay` 和
同一个签名密钥。经过审查的公开证书固定记录在
[`release-policy.json`](release-policy.json) 中。发布打包器会拒绝调试
APK 以及任何与该固定记录不同的签名者。已安装的应用还会检查
下载的 APK 证书是否与其自身已安装的证书匹配。本发布约定不支持密钥轮换。

已签有 Android 调试密钥的现有 APK 无法把首个生产签名 APK 作为原地更新接收。
这一次性过渡需要卸载调试应用并手动安装生产 APK。卸载会
清除应用的设置和配对令牌，因此请启动中继并重新配对。
此后使用同一生产密钥签名的更新通常会保留应用数据。不要仅仅为了应用常规更新
而卸载生产应用。

请把私有密钥库及其可恢复的密码安全地备份到代码仓库之外。
Windows DPAPI 加密的密码与其 Windows 用户和机器绑定；仅复制该加密文件并不能
形成可移植的备份。丢失签名密钥会阻止未来的原地更新。永远不要把私钥、密码、
提供方凭据或本地凭据路径放入源码、发布资产、命令行参数或日志中。

## 官方发布资产

请使用稳定的 `relay-vVERSION` 标签，例如 `relay-v3.5.6`。当其中包含伴生端资产时，
稳定的 `vVERSION` 标签也可接受。草稿和预发布版本会被排除。每个发布必须同时包含
这些资产：

- `relay-release.json`
- `UAI-Relay-VERSION.apk`
- `UAI-Relay-VERSION.apk.sha256`（供手动下载使用的便捷校验和）

3.5.6 发布在共享的 `v3.5.6` 标签下引入这些伴生端资产。生成
本地资产并不会使更新可用；把全部三个资产发布到官方 release 才会让更新器
发现它们。

清单具有以下结构。所显示的大小和 APK 摘要仅为示例；
打包器会根据已签名 APK 计算真实值。

```json
{
  "format": "project-uai-relay-release",
  "schema": 1,
  "version": "3.5.6",
  "versionCode": 3,
  "platform": "android",
  "applicationId": "dev.projectuai.relay",
  "minSdk": 26,
  "protocol": 2,
  "package": {
    "name": "UAI-Relay-3.5.6.apk",
    "bytes": 123,
    "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
    "signerSha256": "ad7d215b8ad67ce70ae2ce89ad3ea959b68202b5c38e72141a68f7d54331f4b5"
  }
}
```

应用会从确切的官方仓库、发布标签和资产名称推导下载 URL。
它不接受清单提供的 URL。下载有
150 MiB 上限。在暂存之前以及再次在安装之前，应用会检查
字节数、SHA-256、包 ID、版本名称/代码、最低 SDK 和签名
证书。语义版本和 Android version code 都必须更新。
每个发布的构建都要递增 `versionCode`；使用三个数字版本
分量，不带前导零或预发布后缀。每个分量最多六位数字，且 `versionCode`
必须不超过 2,100,000,000。

公开清单和校验和是完整性元数据，不能替代
APK 的签名。请把签名密钥与对 GitHub release 的访问权限分开保管。

## 准备发布

需要 JDK 17、Node.js、Android SDK platform 37.1 和 SDK build-tools。
Gradle wrapper 固定并校验 Gradle 9.6.0；AGP 9.4.1 提供 Kotlin 2.2.10。
较新的 compile API 支持 Tor Android，而最低和目标 Android
版本仍为 26 和 36。设置 `ANDROID_HOME`，或
向打包器传入 `--sdk`。在 Windows 上它还会检查常规的本地 Android
SDK 目录。Gradle 签名配置只从构建进程读取这些环境
变量：

| 变量 | 值 |
| --- | --- |
| `UAI_ANDROID_KEYSTORE` | 仓库之外的私有密钥库文件名 |
| `UAI_ANDROID_STORE_PASSWORD` | 密钥库密码 |
| `UAI_ANDROID_KEY_ALIAS` | 稳定的发布密钥别名 |
| `UAI_ANDROID_KEY_PASSWORD` | 密钥密码 |

请从发布机器的密钥存储把这些值载入进程
环境。四项必须同时存在。全部省略会产生一个
未签名的本地发布 APK，它无法通过打包器。不要使用 Gradle
`-P` 参数、shell 历史或已提交的 properties 来承载签名密钥。

遵循项目的审查顺序：

1. 更新版本元数据，并人工审查每一处源码、文档和
   测试改动，包括签名配置和打包器输入。
2. 在准备好的环境中从 `companion/` 使用
   `./gradlew --no-daemon :app:assembleRelease` 构建已签名 APK。
3. 检查生成的 APK、其清单和签名证书。Android
   SDK 的 `aapt dump badging` 和 `apksigner verify --verbose --print-certs` 会暴露
   这些公开信息。
4. 从仓库根目录生成本地资产：

   ```powershell
   node tools/build_companion.js --apk companion/app/build/outputs/apk/release/app-release.apk
   ```

5. 检查 `companion/release/` 下全部三个生成文件。打包器
   原样复制已签名 APK，生成确定性的清单/校验和文件，
   并根据已提交的固定记录校验证书。它会检查一个私有
   快照，因此并发的 Gradle 构建无法替换经过校验的输入。
6. 只有在该检查之后才运行验证：

   ```powershell
   node --test test/build_companion.test.js
   node tools/build_companion.js --apk companion/app/build/outputs/apk/release/app-release.apk --check
   ```

   同时从 `companion/` 使用
   `./gradlew --no-daemon :app:testDebugUnitTest` 运行伴生端 JVM 测试套件，并执行适用的
   原生设备验收检查。在重建或重新测试之前，请人工审查每一处修复。
7. 把三个经过审查的资产一起发布到一个获得授权的官方 release。
   在每个资产都上传之前，不要把发布标记为公开。永远不要就地编辑
   已发布的 APK；请发布更新的版本和 version code。

构建和打包命令不会发布 release。生成的 APK 资产
会被 Git 忽略。`--out DIR` 选择另一个本地目标；`--check`
会重新校验已签名输入，并要求每个生成的输出字节都匹配。
可选的 `--signer-sha256` 断言必须与已提交的固定记录匹配，且不能
覆盖它。

## 设备验收

JVM 测试覆盖发布选择、校验、下载、持久化以及
篡改检测。成功编译和 JVM 检查并不能确立 Android 的
原生包解析或安装器行为。在真实的 Android 8+ 设备上，请验证
在两个使用生产密钥签名的构建之间进行升级、安装权限的拒绝/授予、
安装器取消、APK 暂存和确认期间的进程死亡、
通过 Resume relay 恢复、空闲准入、数据保留、
服务重启以及被中断的下载。确认进行中的请求
不会仅仅因为有可用更新而被取消。对于此实现，
目前尚未记录任何原生设备更新运行。

## 本地验证 —— 2026 年 10 月 25 日

经过审查的生产构建是 `UAI-Relay-3.7.0.apk`，Android version code 7，
39,830,460 字节。其 SHA-256 为：

```text
fc6c65cf8bbc27c6d701190a14142152c8ca7788c5727ebbc483006a0a876ad4
```

已签名 APK 和全部三个发布资产在验证之前都经过了检查。
SDK 工具确认了应用程序 ID `dev.projectuai.relay`、最低 SDK 26、
目标 SDK 36、不可调试状态，以及一个与生产固定记录匹配的有效 APK Signature
Scheme v2 签名者。APK 包含 Tor 及其针对
`arm64-v8a`、`armeabi-v7a`、`x86` 和 `x86_64` 的声明。所有 64 位原生库都具有
16 KiB ELF LOAD 对齐，并且 `zipalign -c -P 16 4` 对最终 APK 通过。

全部 89 项伴生端 JVM 测试通过，无失败、错误或跳过，其中包括
七个 Kilo 用例，覆盖凭据排除、有界配额恢复、
冷却状态、原始截止时间、取消和不完整拒绝。
打包器的十项测试和 `tools/build_companion.js --check` 均通过。
`lintRelease` 以零错误和 35 个警告完成：target SDK 策略、
电池/唤醒锁行为、依赖更新、图标/标签和 Kotlin API
建议。这些警告仍会显示在生成的 lint 报告中。

本次运行未连接任何 Android 设备。原生 Tor 引导、线路
变更、Android 安装/更新行为和实际移动执行器输入仍属于
设备验收检查；JVM 和静态 APK 检查无法确立它们。

## 本地验证 —— 2026 年 10 月 18 日

经过审查的生产构建是 `UAI-Relay-3.5.6.apk`，Android version code 3，
9,606,374 字节。其 SHA-256 为：

```text
985b0686f53c7cdc868c749a445c26e43e88c8affbdeda95c8b7214a65c44240
```

APK、清单和校验和在验证之前都经过了检查。Android SDK
工具确认了包 `dev.projectuai.relay`、最低 SDK 26、目标 SDK 36、
不可调试状态，以及一个与上述公开固定记录匹配的有效 APK Signature Scheme v2
签名者。安装器接收器是私有的。全部三个打包文件
通过了 `tools/build_companion.js --check`，未改动的打包器的十项测试
也通过了。

全部 68 项伴生端 JVM 测试通过，无失败或跳过。`lintRelease`
以零错误和 24 个警告完成。这些警告覆盖有意的唤醒锁
和电池豁免行为、可用的依赖更新以及呈现或
KTX 建议；它们仍会显示在 lint 报告中。一次初始测试运行
在构造函数变更后暴露了过期的增量测试字节码。在不使用增量编译的情况下重新编译
测试类修正了该构建产物；
新的完整测试套件通过了。对生产类与 DEX 构造函数
引用的检查未在 APK 中发现相应的过期链接。

对公开文件和全部 126 个解包 APK 条目的扫描未发现任何已知的
移交凭据或本地签名密钥。这些是 Windows 构建、JVM 和
静态产物检查。它们不能确立原生 Android 安装、
服务存活、移动执行器兼容性或手机上的 OpenCode 访问。
打包不会发布资产；GitHub 发布需要其自身的 release
验证。
