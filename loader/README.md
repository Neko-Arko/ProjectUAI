# 国内网络下的加载方式

GitHub 的 `raw.githubusercontent.com` 在国内经常被阻断，加载器会直接超时。下面是几条
实测可用的路子，按「省事程度」排序。

## 方式一：换成镜像域名（一行搞定）

把 GitHub 域名换掉即可，其余不用动：

```lua
loadstring(game:HttpGet("https://testingcf.jsdelivr.net/gh/Neko-Arko/ProjectUAI-zh-CN@14330e3/dist/uai.lua"))()
```

备用地址（前一个不通就换下一个）：

```lua
-- ghfast.top 的 raw 代理
loadstring(game:HttpGet("https://ghfast.top/https://raw.githubusercontent.com/Neko-Arko/ProjectUAI-zh-CN/14330e3/dist/uai.lua"))()

-- 想永远取 main 上的最新版（jsDelivr 对分支有约 12 小时缓存）
loadstring(game:HttpGet("https://testingcf.jsdelivr.net/gh/Neko-Arko/ProjectUAI-zh-CN@main/dist/uai.lua"))()
```

`@14330e3` 是提交号，内容固定、不会被缓存串味；`@main` 永远取最新，但可能有延迟。

## 方式二：带缓存的加载器（推荐日常用）

`loader/uai-zh-loader.lua` 会按「本地缓存 → 四个镜像依次重试」取包，并校验文件头和
长度——镜像挂掉时返回的 HTML 错误页、只下了一半的包都会被跳过，不会把半截代码跑起来。

第一次运行约 3.6 MB，之后直接读 `UAI/uai-zh.lua`，秒开且完全不联网。

```lua
-- 第一次：把 loader/uai-zh-loader.lua 的内容整段粘进执行器运行
-- 之后可以把下面这行存成自己的快捷启动
loadstring(readfile("UAI/uai-loader.lua"))()
```

强制更新：

```lua
getgenv().UAI_FORCE_UPDATE = true
loadstring(readfile("UAI/uai-loader.lua"))()
```

## 方式三：手动下载，完全离线

1. 浏览器打开 `https://testingcf.jsdelivr.net/gh/Neko-Arko/ProjectUAI-zh-CN@14330e3/dist/uai.lua`
2. 另存为 `uai-zh.lua`，放进执行器工作区的 `UAI/` 目录
3. 游戏内执行：

```lua
loadstring(readfile("UAI/uai-zh.lua"))()
```

## 手机上能不能用

分执行器看，关键在它有没有文件 API：

| 平台 | 本地方案 | 说明 |
| --- | --- | --- |
| Android（Delta、Arceus X、Fluxus、Codex 等） | ✅ 可以 | 大多数提供 `readfile`/`writefile`；`isfile`、`makefolder` 有的没有，加载器已按「缺了就降级」处理 |
| Android 无文件 API 的版本 | ⚠️ 半可用 | 同一局里靠内存缓存（`getgenv()`）避免重复下载，重开执行器仍需重新下 |
| iOS | ❌ 基本不行 | 执行器普遍不给文件读写，只能用镜像在线加载，或把包存进执行器的「脚本库」 |

手机端要点：

- 第一次仍需联网下载约 3.6 MB；之后走本地文件，完全离线。
- 执行器的 `readfile` 路径通常指向它自己的私有目录，先试 `UAI/uai-zh.lua`，写不进去会自动退到根目录 `uai-zh.lua`。
- 想知道文件到底写哪了，可以在执行器里跑 `print(readfile("uai-zh.lua") ~= nil)`，或翻执行器的文件管理页。
- 如果你把包放到了手机下载目录，用绝对路径指定就行（下面的写法已实测断网可加载）：

```lua
getgenv().UAI_CACHE_PATH = "/sdcard/Download/uai-zh.lua"
loadstring(readfile("UAI/uai-loader.lua"))()
```

- 手机上跑长任务时，Android 端的模型请求会被执行器的超时截断，按项目文档启用 **UAI Relay** 伴生应用即可（与本加载器无关，属运行时能力）。

这条路完全不依赖运行时网络，最稳；缺点是更新要手动重下一次。

## 方式四：自己托管（长期最可控）

把 `dist/uai.lua` 传到任意国内可直连的静态存储，然后加载自己的地址：

| 方案 | 说明 |
| --- | --- |
| 腾讯云 COS / 阿里云 OSS | 开静态网站，绑自定义域名 + CDN，国内速度最好；注意内容合规审核 |
| Cloudflare R2 / Pages | 免费额度够用，无需备案；国内访问速度一般但通常可达 |
| Gitee 仓库 raw | 新建仓库并从 GitHub 导入，`https://gitee.com/<用户名>/ProjectUAI/raw/main/dist/uai.lua`；平台对游戏外挂类内容有审核风险 |
| 自己的服务器 / 对象存储 | 需要你有域名或公网 IP |

自托管时把加载器里的 `SOURCES` 换成你自己的地址即可，其他逻辑不用改。

## 说明

- 镜像只代理下载，不碰代码；包内没有额外改动，内容与本仓库 `dist/uai.lua` 逐字节一致。
- 如果四个源全部失败，加载器会列出每个源的失败原因，并把包该放到哪个路径写清楚。
- 网络环境差异很大：某个镜像在你这里通、在别人那里不一定通，所以加载器是「多源重试」而不是单点依赖。
