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

所以:**这里的 CI 绿,只说明每个 SDK 自己自洽**;跨仓库那半边在平台仓库里跑。

`tools/` 下那两个 PowerShell 生成器也是因此存在的:它们从**服务端源码**生成上面那两份 JSON,
所以只能在平台仓库里跑(子模块会把它们带过去)。在这个仓库里直接执行会抛出
「the .NET solution is not where this script expects it」——那不是坏了,是它在说自己找不到服务端。

## CI

`.github/workflows/ci.yml` 跑五个 job,它们是 `main` 的必需检查。
每个 job 除了跑测试,还断言**测试真的跑了**——Gradle 的 `test` 在一个用例都没发现时也算成功,
`node --test` 前面那步编译也可能以看起来像成功的方式产出空目录。
这类静默绿灯本仓栽过不止一次,所以数量下限写在 CI 里,加测试时往上抬,永远不要为了让某次运行通过而调低。

## 许可

Apache License 2.0,见 [`LICENSE`](LICENSE)。
