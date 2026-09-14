#Requires -Version 7.0
<#
.SYNOPSIS
    Regenerates SDK/catalog.json (and the copy the server embeds) from each SDK's own manifest.
    从各 SDK 自己的清单重新生成 SDK/catalog.json 与服务端嵌入的那一份副本。

.DESCRIPTION
    GET /console/v1/sdks serves this file: the platform matrix the integration guide renders —
    platform, version, package-manager command, docs and demo links (SPEC-05 §6.1).

    Why a generator and not a hand-written list, for the reason Build-EndpointInventory.ps1 gives:
    the version numbers already exist, once each, in package.json / build.gradle.kts /
    pubspec.yaml / Package.swift / the .csproj. A second copy typed into a JSON file is a number
    that is right on the day it is written and wrong the first time an SDK is released without
    anyone remembering this file. Here the manifests are the source and this file is derived.
    为什么用生成器：版本号本来就各存一份在各自的清单里，手抄进 JSON 的第二份，
    在第一次有人发布 SDK 却忘了改它的时候就已经错了。

    TWO outputs, deliberately. deploy/Dockerfile copies only src/ into the image, so the server
    cannot read SDK/catalog.json at run time; the second copy lives beside the class that serves it
    and is embedded into the assembly. SdkCatalogTests fails the build when the two differ, which
    is what stops the embedded one from going stale.
    刻意输出两份：镜像只拷 src/，运行时读不到 SDK/ 下的文件，所以第二份放在服务端类旁边并嵌入程序集；
    两份不一致时 SdkCatalogTests 会让构建变红。

.PARAMETER Check
    Do not write. Regenerate in memory, compare with both files on disk, and exit 1 if either
    differs. This is the CI gate.
    只校验不写入：两份中任何一份不一致即以 1 退出。

.EXAMPLE
    pwsh -File SDK/tools/Build-SdkCatalog.ps1
    pwsh -File SDK/tools/Build-SdkCatalog.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolsDir = $PSScriptRoot
$sdkDir = Split-Path -Parent $toolsDir
$repoRoot = Split-Path -Parent $sdkDir

$outputFile = Join-Path $sdkDir 'catalog.json'
# Same break as Build-EndpointInventory.ps1: the backend moved under IM.Server/ on 2026-08-28 and
# this path did not follow it, so the generator wrote nothing and nobody found out — CI has never
# run it. Anchored on the solution file so the next move is caught rather than silently absorbed.
# 与端点清单生成器同一处断裂：后端挪到 IM.Server/ 下而这条路径没跟上，
# 于是生成器什么都没写出来、也没人发现——因为 CI 从未跑过它。
$serverRoot = Join-Path $repoRoot 'IM.Server'
if (-not (Test-Path -LiteralPath (Join-Path $serverRoot 'IM.slnx'))) {
    throw "the .NET solution is not where this script expects it (looked for $serverRoot/IM.slnx)"
}

$embeddedFile = Join-Path $serverRoot 'src/IM.Server/Console/sdk-catalog.json'
$tierFile = Join-Path $toolsDir 'endpoint-tiers.json'

# ---------------------------------------------------------------------------------------------
# 1. Read each manifest for the one thing only it knows: the version.
#    从各自的清单里读那个只有它知道的东西：版本号。
# ---------------------------------------------------------------------------------------------

function Get-RequiredMatch {
    param([string] $Path, [string] $Pattern, [string] $What)

    $absolute = Join-Path $repoRoot $Path
    if (-not (Test-Path -LiteralPath $absolute)) {
        throw "SDK manifest not found: $Path. The catalogue would publish a version nobody can check."
    }

    $match = [regex]::Match([System.IO.File]::ReadAllText($absolute), $Pattern)
    if (-not $match.Success) {
        throw "Could not read $What out of $Path — the manifest's shape changed and this generator stopped reading it."
    }

    return $match.Groups[1].Value.Trim()
}

$typescriptVersion = Get-RequiredMatch 'SDK/typescript/package.json' '"version"\s*:\s*"([^"]+)"' 'the npm version'
$unityVersion      = Get-RequiredMatch 'SDK/unity/package.json'      '"version"\s*:\s*"([^"]+)"' 'the UPM version'
$kotlinVersion     = Get-RequiredMatch 'SDK/kotlin/build.gradle.kts' '(?m)^\s*version\s*=\s*"([^"]+)"' 'the Gradle version'
$flutterVersion    = Get-RequiredMatch 'SDK/flutter/pubspec.yaml'    '(?m)^version:\s*([^\s#]+)' 'the pub version'

# Swift Package Manager carries no version in Package.swift — a Swift package IS its git tag — so
# the CHANGELOG's newest heading is the authority there, and it is checked against the others below.
# Swift 包的版本就是 git tag，Package.swift 里没有版本号，因此以 CHANGELOG 最新标题为准，并与其它 SDK 对齐。
$swiftVersion = Get-RequiredMatch 'SDK/swift/CHANGELOG.md' '(?m)^##\s*\[?v?(\d+\.\d+\.\d+)' 'the newest released version'

$clientVersions = [ordered]@{
    typescript = $typescriptVersion
    kotlin     = $kotlinVersion
    swift      = $swiftVersion
    flutter    = $flutterVersion
    unity      = $unityVersion
}

# SDK/CONTRACT.md: "the version number is shared across all five client SDKs — one number
# identifies a contract, not a platform". If that stops being true, the catalogue must not be the
# place where it is quietly papered over.
# CONTRACT 明说五个客户端 SDK 共用一个版本号——它一旦不再成立，也不该由这份目录悄悄抹平。
$distinct = @($clientVersions.Values | Sort-Object -Unique)
if ($distinct.Count -ne 1) {
    $detail = ($clientVersions.Keys | ForEach-Object { "$_=$($clientVersions[$_])" }) -join ', '
    throw ("The five client SDKs no longer share one version ($detail). SDK/CONTRACT.md says one " +
        "number identifies a contract, not a platform — reconcile them, or change the contract first.")
}

$sdkVersion = $distinct[0]

# The server SDK is versioned on its own: it is a different audience (tenant backends) and a
# different release cadence, and it implements the REST contract rather than the socket one.
# 服务端 SDK 单独版本：受众与节奏都不同，实现的是 REST 契约而不是 socket 契约。
$dotnetCsproj = Join-Path $repoRoot 'SDK/dotnet/Cyaim.Im.ServerSdk/Cyaim.Im.ServerSdk.csproj'
$dotnetMatch = [regex]::Match([System.IO.File]::ReadAllText($dotnetCsproj), '<Version>([^<]+)</Version>')

# No fallback here. This line read `else { $sdkVersion }` until 2026-09-14, and the csproj declared
# no <Version>, so the branch that ran was the fallback one: the catalogue told every trial customer
# through GET /console/v1/sdks that Cyaim.Im.ServerSdk was on 0.9.0 while `dotnet pack` produced
# Cyaim.Im.ServerSdk.1.0.0.nupkg. The number was not read from anywhere — it was invented, out of the
# client SDKs' version, by a regex that had failed. Nothing reported the failure.
#
# That is this repository's own rule broken inside its own tooling: a number nobody measured must be
# drawn as unmeasured, never as a plausible default. There is no "unmeasured" to draw here — the
# catalogue's version field is asserted non-empty by SdkCatalogTests, and a customer cannot install a
# blank — so the only honest action left is to refuse to write the file.
# 这正是本仓「拿不到的数字画未测量，不画 0」在它自己的工具里被犯的那一次；而这里没有「未测量」可画，
# 于是唯一正确的动作是拒绝生成。
if (-not $dotnetMatch.Success) {
    throw ('SDK/dotnet/Cyaim.Im.ServerSdk/Cyaim.Im.ServerSdk.csproj declares no <Version>, so MSBuild ' +
        'defaults it to 1.0.0 and the package this catalogue advertises cannot be built under the ' +
        'number it advertises. Pin <Version> in that csproj — not here. Filling it in from the client ' +
        'SDKs would publish a version that has never existed, through GET /console/v1/sdks, to every ' +
        'trial customer, and NuGet cannot delete a published version once the two disagree in public.')
}

$dotnetVersion = $dotnetMatch.Groups[1].Value.Trim()

$contractVersion = (Get-Content -LiteralPath $tierFile -Raw | ConvertFrom-Json -AsHashtable)['contractVersion']

# ---------------------------------------------------------------------------------------------
# 2. The rest of each row is editorial and lives here: the install line a developer pastes, the
#    runtimes the SDK states it supports, and where its docs and demo are.
#    每行的其余部分属于编辑内容，写在这里：可粘贴的安装命令、SDK 自称支持的运行时、文档与示例位置。
# ---------------------------------------------------------------------------------------------

$platforms = @(
    [ordered]@{
        id = 'typescript'; name = 'Web / Node.js'; kind = 'client'; language = 'TypeScript'
        package = '@cyaim/im-client'; version = $typescriptVersion
        install = 'npm install @cyaim/im-client'
        targets = @('browser (ES2020)', 'Node.js 18+')
        docs = 'SDK/typescript/README.md'; changelog = 'SDK/typescript/CHANGELOG.md'
        demo = 'SDK/typescript/test'; source = 'SDK/typescript/src'
    }
    [ordered]@{
        id = 'kotlin'; name = 'Android / JVM'; kind = 'client'; language = 'Kotlin'
        package = 'com.cyaim.im:im-client'; version = $kotlinVersion
        install = "implementation(`"com.cyaim.im:im-client:$kotlinVersion`")"
        targets = @('JVM 11+', 'Android (via the host app, see CONTRACT §6.3)')
        docs = 'SDK/kotlin/README.md'; changelog = 'SDK/kotlin/CHANGELOG.md'
        demo = $null; source = 'SDK/kotlin/src/main/kotlin'
    }
    [ordered]@{
        id = 'swift'; name = 'iOS / macOS'; kind = 'client'; language = 'Swift'
        package = 'CyaimIM'; version = $swiftVersion
        # The mirror repository does not exist yet (measured 2026-09-14: 404), and until it does
        # this line is the future install command, exactly like the other five rows -- not one
        # of the six packages resolves today. What it must not also be is spelled differently
        # in each place it appears: this line spelled the owner in lower case, CONTRACT.md §9.4
        # spelled it `Cyaim/im-swift`, and nobody had compared them. GitHub redirects a wrong-cased
        # owner in a browser, which is exactly why the disagreement survived unnoticed.
        # 镜像仓尚未建立；这一行与其余五行一样是「发布之后」的安装命令，但至少要与另外两处拼法一致。
        install = ".package(url: `"https://github.com/Cyaim/im-swift`", from: `"$swiftVersion`")"
        targets = @('Swift 6.0+', 'iOS', 'macOS')
        docs = 'SDK/swift/README.md'; changelog = 'SDK/swift/CHANGELOG.md'
        demo = $null; source = 'SDK/swift/Sources'
    }
    [ordered]@{
        id = 'flutter'; name = 'Flutter'; kind = 'client'; language = 'Dart'
        package = 'cyaim_im'; version = $flutterVersion
        install = 'dart pub add cyaim_im'
        targets = @('Dart 3', 'iOS', 'Android', 'Web', 'desktop')
        docs = 'SDK/flutter/README.md'; changelog = 'SDK/flutter/CHANGELOG.md'
        demo = 'SDK/flutter/example/main.dart'; source = 'SDK/flutter/lib'
    }
    [ordered]@{
        id = 'unity'; name = 'Unity'; kind = 'client'; language = 'C#'
        package = 'com.cyaim.im'; version = $unityVersion
        # Was `https://github.com/cyaim/im-unity.git` -- a repository that has never existed
        # (404), with no `?path=` and no revision, in a single-quoted string so the version
        # never followed $unityVersion. It also disagreed outright with unity/README.md, which
        # gave a third form; the two were written separately and never read against each other.
        # Shape per docs.unity3d.com/Manual/upm-git.html: the `?path=` query parameter always
        # precedes the revision anchor (the reverse order fails), and the revision should be a
        # tag rather than the default branch, which is a moving target.
        # 形态依 UPM 文档：?path= 必须在 # 之前，# 后面取 tag 而不是默认分支。
        install = "Unity Package Manager → Add package from git URL → " +
            "https://github.com/Cyaim/im-cloud-sdk.git?path=/unity#v$unityVersion"
        targets = @('Unity 2021.3+', 'IL2CPP', 'WebGL')
        docs = 'SDK/unity/README.md'; changelog = 'SDK/unity/CHANGELOG.md'
        demo = 'SDK/unity/Samples~/ChatQuickstart'; source = 'SDK/unity/Runtime'
    }
    [ordered]@{
        id = 'dotnet'; name = '.NET server'; kind = 'server'; language = 'C#'
        package = 'Cyaim.Im.ServerSdk'; version = $dotnetVersion
        install = 'dotnet add package Cyaim.Im.ServerSdk'
        targets = @('net8.0', 'net9.0', 'net10.0')
        docs = 'SDK/dotnet/README.md'; changelog = $null
        demo = $null; source = 'SDK/dotnet/Cyaim.Im.ServerSdk'
    }
)

foreach ($platform in $platforms) {
    foreach ($relative in @($platform.docs, $platform.demo, $platform.source, $platform.changelog)) {
        if ($relative -and -not (Test-Path -LiteralPath (Join-Path $repoRoot $relative))) {
            throw ("The catalogue points at '$relative' for '$($platform.id)' and it does not exist. " +
                'A dead link on the integration guide is worse than an absent one.')
        }
    }
}

# ---------------------------------------------------------------------------------------------
# 3. Emit. No timestamp anywhere: this file is committed, and a line that changes on every run
#    turns every unrelated PR into a diff (same rule as the endpoint inventory).
#    输出不含时间戳：每次运行都改一行会把所有无关 PR 变成 diff。
# ---------------------------------------------------------------------------------------------

$document = [ordered]@{
    '$comment'      = 'GENERATED by SDK/tools/Build-SdkCatalog.ps1 from each SDK manifest. Do not edit by hand; bump the SDK and regenerate. Served by GET /console/v1/sdks (SPEC-05 §6.1). The copy at src/IM.Server/Console/sdk-catalog.json is embedded in the server image and must stay identical.'
    contractVersion = $contractVersion
    sdkVersion      = $sdkVersion
    platforms       = $platforms
}

$json = ($document | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd() + "`n"

function Test-Current {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "$([System.IO.Path]::GetRelativePath($repoRoot, $Path)) is missing." -ForegroundColor Red
        return $false
    }

    if ([System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n") -ne $json) {
        Write-Host "$([System.IO.Path]::GetRelativePath($repoRoot, $Path)) is stale." -ForegroundColor Red
        return $false
    }

    return $true
}

if ($Check) {
    # Both, always. `-and` short-circuits in PowerShell, so the earlier form named the first
    # stale file and never looked at the second — and these two are generated from the same data,
    # so they go stale together. A reader who fixed the one file named, re-ran, and saw it fail
    # again on a file that had been stale the whole time would reasonably think the generator was
    # broken. 两个都查。PowerShell 的 -and 会短路，于是它只报第一个过期的文件、
    # 根本不看第二个——而这两份是同一批数据生成的，要过期一起过期。
    $outputCurrent = Test-Current $outputFile
    $embeddedCurrent = Test-Current $embeddedFile
    $ok = $outputCurrent -and $embeddedCurrent
    if (-not $ok) {
        Write-Host '  Run: pwsh -File SDK/tools/Build-SdkCatalog.ps1'
        exit 1
    }

    Write-Host "SDK/catalog.json is current: $($platforms.Count) platforms on SDK $sdkVersion." -ForegroundColor Green
    exit 0
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($outputFile, $json, $utf8)
[System.IO.File]::WriteAllText($embeddedFile, $json, $utf8)

Write-Host "Wrote SDK/catalog.json and IM.Server/src/IM.Server/Console/sdk-catalog.json" -ForegroundColor Green
$clientCount = @($platforms | Where-Object { $_.kind -eq 'client' }).Count
$serverCount = @($platforms | Where-Object { $_.kind -eq 'server' }).Count
Write-Host "  platforms   $($platforms.Count) ($clientCount client, $serverCount server)"
Write-Host "  sdkVersion  $sdkVersion"
Write-Host "  contract    $contractVersion"
