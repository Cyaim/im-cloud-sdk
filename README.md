# IM 云平台 · 客户端 SDK

即时通讯 PaaS 的官方 SDK。五个客户端 + 一个服务端库,共读同一份协议契约。

| 目录 | 语言 / 平台 | 说明 |
|---|---|---|
| [`typescript/`](typescript) | TypeScript / JavaScript | 浏览器与 Node |
| [`kotlin/`](kotlin) | Kotlin | Android 与 JVM(库目标 JVM 11) |
| [`swift/`](swift) | Swift | iOS / macOS(Swift 6 语言模式) |
| [`flutter/`](flutter) | Dart / Flutter | 移动与桌面 |
| [`unity/`](unity) | C# / Unity | 游戏内聊天 |
| [`dotnet/`](dotnet) | C# | **服务端** SDK,用于从你自己的后端调用平台 |

每个目录下有它自己的 README 与安装说明。

## 先读这一份

[`CONTRACT.md`](CONTRACT.md) 是协议契约:帧格式、请求/响应管线、推送目标、错误码、
重连与补洞的语义。**五个 SDK 的行为都以它为准**,任何一个与它不一致都是那个 SDK 的缺陷。

另外两份是生成的,不要手改:

- [`endpoint-inventory.json`](endpoint-inventory.json) —— 端点清单,由服务端源码生成
- [`catalog.json`](catalog.json) —— SDK 目录
- [`signature-vectors.json`](signature-vectors.json) —— 签名测试向量,C# 与 TypeScript 共读同一份

## 这个仓库与平台仓库的关系

这里是 SDK 的**权威副本**。平台仓库(私有)以 git 子模块的形式把它挂在 `SDK/` 下,
因为有两类检查必须同时看到服务端源码和 SDK 源码,在这里跑不了:

- **端点清单与目录的生成器** —— 从服务端的路由、错误码、推送目标重新生成,再与仓库里的
  文件比对。它回答的是「有人加了端点却没重新生成」。
- **推送目标一致性** —— 读五份 SDK 的推送目标表,与服务端的枚举穷举比对。
  服务端加了字段而 SDK 不认,等于没加。
- **错误码一致性**(2026-09-09 新增)—— 读五份 SDK 的错误码表,与服务端的 `ImErrorCode` 比对。
  加这条的当天它就抓到:`unity/` 只有另外四份都有的 66 个码里的 42 个,少 24 个,
  其中 19 个由 Unity 自己已经有类型的调用抛出。客户端是按数字分支的,
  没被命名的码只能硬编码或猜——`1406 DuplicateClientMessageId` 是幂等键**成功**了,
  当成失败换个键重试,就正好造出那个键本来要防的重复消息。

- **Unity 自己那套测试**(2026-09-09 新增)—— 见下一节。

所以:**这里的 CI 绿,只说明四个客户端 SDK 各自自洽**;跨仓库那半边在平台仓库里跑。

`tools/` 下那两个 PowerShell 生成器也是因此存在的:它们从**服务端源码**生成上面那两份 JSON,
所以只能在平台仓库里跑(子模块会把它们带过去)。在这个仓库里直接执行会抛出
「the .NET solution is not where this script expects it」——那不是坏了,是它在说自己找不到服务端。

## CI

`.github/workflows/ci.yml` 跑五个 job,它们是 `main` 的必需检查:
`typescript`、`kotlin`、`dart`、`swift`,加上服务端库的 `dotnet-package`。

**这是四个客户端加一个服务端库,不是五个客户端:`unity` 没有 job。**
上面那张表里有六个目录,而这里只有五个 job——数字接近,读起来像对上了,实际差了一整个平台。
runner 上没有 Unity 授权,盒子里也没有无头编译器,所以这个仓库跑不了它。
Unity 是这里最大的客户端 SDK(约 1.75 万行),而 `unity/Tests/Runtime` 下那 **172 条断言**
**到 2026-09-09 为止在任何地方都没有执行过一次**。

现在它们在平台仓库里跑:`IM.Server/tests/IM.Tests.UnitySdk` 把这些测试源码对着一个
手写的 UnityEngine shim 编译并执行,不需要 Unity 授权、编辑器或 runner 镜像
(测试源码本身不 import UnityEngine,`UnityEngine.TestRunner` 只写在 asmdef 上)。
**所以改 `unity/` 下的东西时,这个仓库的 CI 不会告诉你它坏没坏。**
第一次跑起来就抓到两处:一处是四个赋值把 `long` 赋给了已经改成 `string` 的 messageId
(那份测试连编译都过不了),另一处是 harness 只答复了一次连接所触发的一半请求。

每个 job 除了跑测试,还断言**测试真的跑了**——Gradle 的 `test` 在一个用例都没发现时也算成功,
`node --test` 前面那步编译也可能以看起来像成功的方式产出空目录。
这类静默绿灯本仓栽过不止一次,所以数量下限写在 CI 里,加测试时往上抬,永远不要为了让某次运行通过而调低。

## 许可

Apache License 2.0,见 [`LICENSE`](LICENSE)。
