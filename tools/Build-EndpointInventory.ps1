#Requires -Version 7.0
<#
.SYNOPSIS
    Regenerates SDK/endpoint-inventory.json from the server source of truth.
    从服务端源码重新生成 SDK/endpoint-inventory.json。

.DESCRIPTION
    The inventory is the machine-readable half of SDK/CONTRACT.md: the list of every
    [WebSocket] endpoint the gateway exposes, its request and response payload shapes, the
    ship tier it belongs to, and which of the five client SDKs types it today.

    Why a generator and not a hand-written list: five SDK teams implement against this file,
    and a hand-written list of 107 endpoints is wrong the first time someone adds an
    endpoint and does not update it. The list is derived from src/IM.Server/WsControllers,
    so it cannot drift from the server; only the tier assignment is human judgement, and
    that lives in endpoint-tiers.json, which this script *requires* to be exhaustive — a new
    server endpoint fails the build until somebody decides which tier it is in.
    为什么用生成器而不是手写清单：五个 SDK 团队照着这个文件实现，而 107 条端点的手写清单
    在别人第一次新增端点却忘了更新时就已经错了。清单从服务端源码推导，因此不可能与服务端漂移；
    唯一属于人的判断是分层，它放在 endpoint-tiers.json 里，本脚本要求它完备——
    新增一个服务端端点会让生成失败，直到有人决定它属于哪一层。

.PARAMETER Check
    Do not write. Regenerate in memory, compare with the file on disk, and exit 1 if they
    differ. This is the CI gate: it makes "someone added an endpoint and did not tier it" and
    "someone changed a payload shape and did not tell the SDKs" both fail the build.
    只校验不写入：内容不一致则以 1 退出。CI 用这个门禁。

.EXAMPLE
    pwsh -File SDK/tools/Build-EndpointInventory.ps1
    pwsh -File SDK/tools/Build-EndpointInventory.ps1 -Check
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

# The backend moved under IM.Server/ when the git root came back to the workspace (2026-08-28).
# These two paths were missed by that move, so this generator threw on its first line of work and
# the inventory could not be rebuilt at all — silently, because CI has never run it. Anchored on the
# solution file rather than on a fixed depth, so the next reorganisation moves it without breaking it.
# 后端在 2026-08-28 那次目录整理里挪到了 IM.Server/ 下，而这两条路径被漏掉了：
# 生成器因此在第一步就抛异常、清单根本重建不了——而且是静默的，因为 CI 从未跑过它。
# 现在按 IM.slnx 定位而不是按固定层级，下一次搬目录不会再打断它。
$serverRoot = Join-Path $repoRoot 'IM.Server'
if (-not (Test-Path -LiteralPath (Join-Path $serverRoot 'IM.slnx'))) {
    throw "the .NET solution is not where this script expects it (looked for $serverRoot/IM.slnx)"
}

$wsControllerDir = Join-Path $serverRoot 'src/IM.Server/WsControllers'
$abstractionsDir = Join-Path $serverRoot 'src/IM.Abstractions'
$errorCodeFile = Join-Path $abstractionsDir 'Errors/ImErrorCode.cs'
$pushTargetFile = Join-Path $abstractionsDir 'Protocol/ServerPush.cs'
$tierFile = Join-Path $toolsDir 'endpoint-tiers.json'
$outputFile = Join-Path $sdkDir 'endpoint-inventory.json'

foreach ($required in @($wsControllerDir, $abstractionsDir, $errorCodeFile, $pushTargetFile, $tierFile)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required input not found: $required"
    }
}

# ---------------------------------------------------------------------------------------------
# 1. Type table: every DTO the endpoints can reference.
#    类型表：端点可能引用的每一个 DTO。
#
#    A regex parser rather than Roslyn on purpose. Roslyn would mean a csproj, a restore and a
#    build inside a tool that exists to describe the build — and the DTO shapes here are plain
#    `public T Name { get; set; }` declarations with no partial classes and no generics of our
#    own, which is exactly the subset a regex reads correctly. The script proves it read them by
#    failing loudly when a referenced type resolves to nothing (see $unresolved below).
#    刻意用正则而非 Roslyn：这些 DTO 全是最朴素的自动属性声明，正则读得对；
#    而引用不到的类型会显式报错，读错了不会悄悄过去。
# ---------------------------------------------------------------------------------------------

$sourceFiles = @(
    Get-ChildItem -LiteralPath $wsControllerDir -Filter '*.cs' -File
    Get-ChildItem -LiteralPath $abstractionsDir -Filter '*.cs' -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/](obj|bin)[\\/]' }
) | Sort-Object FullName

# Kept as ordered dictionaries so the emitted JSON is byte-stable across runs.
# 用有序字典，保证多次运行产生逐字节一致的 JSON。
$types = [ordered]@{}
$enums = [ordered]@{}

$typeDeclaration = '^\s*public\s+(?:sealed\s+|abstract\s+|static\s+)*(?<kind>class|record|enum)\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)'
$propertyDeclaration = '^\s*public\s+(?:required\s+)?(?<type>[A-Za-z_][A-Za-z0-9_<>,\.\?\[\]\s]*?)\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\{\s*get;'
$enumMember = '^\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*(?<value>-?\d+)\s*)?,?\s*(?://.*)?$'

foreach ($file in $sourceFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $current = $null
    $currentKind = $null
    $depth = 0
    $nextEnumValue = 0

    foreach ($line in $lines) {
        $match = [regex]::Match($line, $typeDeclaration)
        if ($match.Success -and $depth -le 1) {
            $currentKind = $match.Groups['kind'].Value
            $current = $match.Groups['name'].Value
            $nextEnumValue = 0

            if ($currentKind -eq 'enum') {
                if (-not $enums.Contains($current)) {
                    $enums[$current] = [ordered]@{}
                }
            }
            elseif (-not $types.Contains($current)) {
                $types[$current] = [ordered]@{
                    file       = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\', '/')
                    properties = [System.Collections.Generic.List[object]]::new()
                }
            }
        }
        elseif ($null -ne $current) {
            if ($currentKind -eq 'enum') {
                $memberMatch = [regex]::Match($line, $enumMember)
                if ($memberMatch.Success -and $memberMatch.Groups['name'].Value -notin @('public', 'private', 'internal')) {
                    $name = $memberMatch.Groups['name'].Value
                    if ($memberMatch.Groups['value'].Success) {
                        $nextEnumValue = [int]$memberMatch.Groups['value'].Value
                    }
                    $enums[$current][$name] = $nextEnumValue
                    $nextEnumValue++
                }
            }
            else {
                $propertyMatch = [regex]::Match($line, $propertyDeclaration)
                if ($propertyMatch.Success) {
                    $declared = $propertyMatch.Groups['type'].Value.Trim()
                    $types[$current].properties.Add([ordered]@{
                        # camelCase because the gateway sets PropertyNamingPolicy.CamelCase.
                        # 网关设置了 CamelCase 命名策略，线上字段名是小驼峰。
                        name     = $propertyMatch.Groups['name'].Value.Substring(0, 1).ToLowerInvariant() +
                                   $propertyMatch.Groups['name'].Value.Substring(1)
                        type     = $declared
                        nullable = $declared.EndsWith('?')
                    })
                }
            }
        }

        $depth += ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
        if ($depth -le 1 -and $line -match '^\s*\}\s*$') {
            $current = $null
            $currentKind = $null
        }
    }
}

# ---------------------------------------------------------------------------------------------
# 2. Endpoints: [WebSocket("name")] plus the signature on the following lines.
#    端点：[WebSocket("name")] 加上紧随其后的方法签名。
#
#    The target is <controller class name minus "Controller", lowercased> + "." + <attribute
#    argument>. Two files hold two controllers each (FriendController lives in UserController.cs,
#    MediaController in RoomController.cs), so the prefix tracks the last *Controller class seen
#    rather than the file name — using the file name would silently mis-prefix 11 endpoints.
#    目标名 = 类名去掉 Controller 后小写 + "." + 特性参数。
#    有两个文件各含两个控制器，所以前缀跟踪"最近出现的 *Controller 类"而不是文件名。
# ---------------------------------------------------------------------------------------------

$endpoints = [System.Collections.Generic.List[object]]::new()

foreach ($file in (Get-ChildItem -LiteralPath $wsControllerDir -Filter '*.cs' -File | Sort-Object Name)) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $prefix = $null

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $classMatch = [regex]::Match($lines[$i], '^\s*public\s+sealed\s+class\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)Controller\b')
        if ($classMatch.Success) {
            $prefix = $classMatch.Groups['name'].Value.ToLowerInvariant()
            continue
        }

        $attributeMatch = [regex]::Match($lines[$i], '^\s*\[WebSocket\("(?<name>[^"]+)"\)\]')
        if (-not $attributeMatch.Success) { continue }

        if ($null -eq $prefix) {
            throw "[WebSocket] attribute at $($file.Name):$($i + 1) precedes any *Controller class declaration."
        }

        $signature = $null
        for ($j = $i + 1; $j -lt [Math]::Min($i + 6, $lines.Length); $j++) {
            $signatureMatch = [regex]::Match(
                $lines[$j],
                '^\s*public\s+(?:async\s+)?Task<(?<result>ApiResult(?:<(?<payload>.+)>)?)>\s+(?<method>[A-Za-z_][A-Za-z0-9_]*)\s*\((?<args>[^)]*)\)')
            if ($signatureMatch.Success) { $signature = $signatureMatch; break }
        }

        if ($null -eq $signature) {
            throw "No recognised endpoint signature follows [WebSocket] at $($file.Name):$($i + 1)."
        }

        $requestType = $null
        $args = $signature.Groups['args'].Value.Trim()
        if ($args) {
            # The `\??` is outside the capture group on purpose: an endpoint may take its request
            # nullable (`DeskCannedRequest? request`, for a call whose body is entirely optional),
            # and the inventory names the TYPE — five SDKs generate a model from it, and
            # `DeskCannedRequest?` is not a type name in any of their languages. Without this the
            # generator threw on desk.canned and the inventory could not be rebuilt at all, which
            # is how it came to be three endpoints and several source lines out of date.
            # `\??` 刻意放在捕获组外：端点可以把请求体声明成可空，而清单里写的是**类型名**——
            # 五个 SDK 照它生成模型，而 `DeskCannedRequest?` 在它们任何一门语言里都不是类型名。
            # 少了这一处，生成器会在 desk.canned 上抛异常、整个清单根本重建不了。
            $argMatch = [regex]::Match($args, '^(?<type>[A-Za-z_][A-Za-z0-9_<>,\.]*)\??\s+[A-Za-z_]')
            if (-not $argMatch.Success) {
                throw "Cannot parse the request parameter of $prefix.$($attributeMatch.Groups['name'].Value): '$args'."
            }
            $requestType = $argMatch.Groups['type'].Value
        }

        $endpoints.Add([ordered]@{
            target       = "$prefix.$($attributeMatch.Groups['name'].Value)"
            controller   = "$($prefix.Substring(0,1).ToUpperInvariant())$($prefix.Substring(1))Controller"
            method       = $signature.Groups['method'].Value
            source       = "src/IM.Server/WsControllers/$($file.Name):$($i + 1)"
            requestType  = $requestType
            responseType = if ($signature.Groups['payload'].Success) { $signature.Groups['payload'].Value.Trim() } else { $null }
        })
    }
}

$endpoints = @($endpoints | Sort-Object -Property target)

# ---------------------------------------------------------------------------------------------
# 3. Tiering — the one human judgement in this file, and the one the SDK plan is ordered by.
#    分层——本文件里唯一属于人的判断，也是 SDK 实施顺序的依据。
# ---------------------------------------------------------------------------------------------

$tierData = Get-Content -LiteralPath $tierFile -Raw | ConvertFrom-Json -AsHashtable
$tierDefinitions = $tierData['tiers']
$assignments = $tierData['endpoints']

$declaredTargets = [System.Collections.Generic.HashSet[string]]::new([string[]]$assignments.Keys)
$actualTargets = [System.Collections.Generic.HashSet[string]]::new([string[]]($endpoints | ForEach-Object { $_.target }))

$untiered = @($actualTargets | Where-Object { -not $declaredTargets.Contains($_) } | Sort-Object)
$stale = @($declaredTargets | Where-Object { -not $actualTargets.Contains($_) } | Sort-Object)

if ($untiered.Count -gt 0) {
    throw ("The server exposes endpoints that endpoint-tiers.json does not tier. " +
        "Decide which shipping tier each belongs to and add it (see SDK/CONTRACT.md §3):`n  " +
        ($untiered -join "`n  "))
}
if ($stale.Count -gt 0) {
    throw ("endpoint-tiers.json tiers endpoints the server no longer exposes. " +
        "Removing a published endpoint is a breaking change — see SDK/CONTRACT.md §9:`n  " +
        ($stale -join "`n  "))
}

# ---------------------------------------------------------------------------------------------
# 4. Per-SDK coverage, measured rather than claimed.
#    逐 SDK 覆盖率——测出来的，不是声称的。
#
#    An SDK "covers" a target when the target string appears literally in its published source.
#    That is deliberately generous: it counts a target used only for internal gap repair the same
#    as a typed public method, so the number can only ever overstate coverage. A coverage report
#    that flatters the SDKs and still reads 11/107 makes the point without argument.
#    判定标准刻意宽松（源码中出现该目标字面量即算覆盖），只会高估不会低估；
#    即便如此仍然只有 11/107，结论就无需再争。
# ---------------------------------------------------------------------------------------------

$sdkSources = [ordered]@{
    typescript = @('SDK/typescript/src')
    kotlin     = @('SDK/kotlin/src/main/kotlin')
    swift      = @('SDK/swift/Sources')
    flutter    = @('SDK/flutter/lib')
    unity      = @('SDK/unity/Runtime')
}

function Remove-Comments {
    <#
        .SYNOPSIS
        Strips comments so a documented example cannot be counted as an implementation.

        .DESCRIPTION
        Coverage is measured by looking for the quoted target name in an SDK's sources, and a doc
        comment quotes target names constantly — to show what an untyped endpoint looks like through
        the escape hatch, to point at a neighbour, to explain what a method wraps. Counting those
        does not merely add noise, it inverts the file's meaning: `group.setRole` was reported as
        implemented in TypeScript on the strength of a JSDoc line reading
        "// group.setRole is T3 and not typed yet", so the one document that exists to say what is
        left to do claimed the work was done, in the exact place the author had written that it
        was not.

        The five languages share `//`, `/* */` and a doc form built on them (`///`, `/** */`), so
        one pass covers all of them. String contents are left alone, which is the point — a target
        name inside a string literal is what an implementation looks like.

        用注释判定覆盖率会把「文档里的反例」算成「已实现」：
        `group.setRole` 曾因为一行写着「它还没有类型化」的 JSDoc 而被报成 TypeScript 已实现——
        唯一一份说明「还剩什么没做」的文档，在作者亲手写下「没做」的那一行上声称做完了。
    #>
    param([string] $Source)

    $withoutBlocks = [regex]::Replace($Source, '/\*.*?\*/', '', 'Singleline')
    return [regex]::Replace($withoutBlocks, '(?m)^\s*//.*$', '')
}

$sdkText = [ordered]@{}
foreach ($sdk in $sdkSources.Keys) {
    $builder = [System.Text.StringBuilder]::new()
    foreach ($relative in $sdkSources[$sdk]) {
        $absolute = Join-Path $repoRoot $relative
        if (-not (Test-Path -LiteralPath $absolute)) {
            throw "SDK source directory not found: $relative. Coverage would silently read 0."
        }
        foreach ($sdkFile in (Get-ChildItem -LiteralPath $absolute -File -Recurse | Sort-Object FullName)) {
            [void]$builder.AppendLine((Remove-Comments ([System.IO.File]::ReadAllText($sdkFile.FullName))))
        }
    }
    $sdkText[$sdk] = $builder.ToString()
}

$coverageTotals = [ordered]@{}
foreach ($sdk in $sdkSources.Keys) { $coverageTotals[$sdk] = 0 }

foreach ($endpoint in $endpoints) {
    $assignment = $assignments[$endpoint.target]
    $endpoint['tier'] = $assignment['tier']
    if ($assignment.ContainsKey('feature')) { $endpoint['featureFlag'] = $assignment['feature'] }
    if ($assignment.ContainsKey('note')) { $endpoint['note'] = $assignment['note'] }

    $covered = [ordered]@{}
    foreach ($sdk in $sdkSources.Keys) {
        $hit = $sdkText[$sdk].Contains("`"$($endpoint.target)`"") -or $sdkText[$sdk].Contains("'$($endpoint.target)'")
        $covered[$sdk] = $hit
        if ($hit) { $coverageTotals[$sdk]++ }
    }
    $endpoint['implementedIn'] = $covered
}

# ---------------------------------------------------------------------------------------------
# 5. Transitive payload closure: every type an implementer must declare to type these endpoints.
#    载荷类型闭包：实现这些端点所需声明的每一个类型。
# ---------------------------------------------------------------------------------------------

$scalarTypes = @(
    'string', 'int', 'long', 'bool', 'double', 'float', 'decimal', 'object', 'byte', 'short',
    'DateTime', 'DateTimeOffset', 'TimeSpan', 'Guid', 'JsonElement', 'JsonNode', 'Unit', 'void')

function Get-ReferencedTypeNames {
    param([string] $Declared)

    if ([string]::IsNullOrWhiteSpace($Declared)) { return @() }

    # Strip nullability and array marks, then split every generic argument apart, so
    # `Dictionary<string, List<Message>>?` yields Dictionary, string, List and Message.
    # 去掉可空/数组标记后按泛型参数拆开。
    $cleaned = $Declared -replace '\?', '' -replace '\[\]', ''
    return @($cleaned -split '[<>,\s]+' |
        ForEach-Object { ($_ -split '\.')[-1] } |
        Where-Object { $_ -and $_ -notin $scalarTypes } |
        Where-Object { $_ -notin @('List', 'Dictionary', 'IReadOnlyList', 'IReadOnlyDictionary', 'ApiResult', 'PagedResult', 'IEnumerable', 'ICollection') })
}

$pending = [System.Collections.Generic.Queue[string]]::new()
foreach ($endpoint in $endpoints) {
    foreach ($name in (Get-ReferencedTypeNames $endpoint.requestType)) { $pending.Enqueue($name) }
    foreach ($name in (Get-ReferencedTypeNames $endpoint.responseType)) { $pending.Enqueue($name) }
}

$reachedTypes = [System.Collections.Generic.HashSet[string]]::new()
$reachedEnums = [System.Collections.Generic.HashSet[string]]::new()
$unresolved = [System.Collections.Generic.HashSet[string]]::new()

while ($pending.Count -gt 0) {
    $name = $pending.Dequeue()

    if ($enums.Contains($name)) { [void]$reachedEnums.Add($name); continue }
    if (-not $types.Contains($name)) { [void]$unresolved.Add($name); continue }
    if (-not $reachedTypes.Add($name)) { continue }

    foreach ($property in $types[$name].properties) {
        foreach ($referenced in (Get-ReferencedTypeNames $property.type)) { $pending.Enqueue($referenced) }
    }
}

if ($unresolved.Count -gt 0) {
    throw ("These payload types are referenced by an endpoint but were not found in the scanned " +
        "sources, so the inventory would be incomplete:`n  " + (@($unresolved | Sort-Object) -join "`n  "))
}

$payloadTypes = [ordered]@{}
foreach ($name in ($reachedTypes | Sort-Object)) {
    $payloadTypes[$name] = [ordered]@{
        source     = $types[$name].file
        properties = @($types[$name].properties)
    }
}

$payloadEnums = [ordered]@{}
foreach ($name in ($reachedEnums | Sort-Object)) {
    $payloadEnums[$name] = $enums[$name]
}

# ---------------------------------------------------------------------------------------------
# 6. Error codes and push targets — the other two halves of the contract.
#    错误码与推送事件名——契约的另外两半。
# ---------------------------------------------------------------------------------------------

$errorCodes = [ordered]@{}
foreach ($line in [System.IO.File]::ReadAllLines($errorCodeFile)) {
    $codeMatch = [regex]::Match($line, '^\s*public\s+const\s+int\s+(?<name>[A-Za-z0-9_]+)\s*=\s*(?<value>\d+)\s*;')
    if ($codeMatch.Success) { $errorCodes[$codeMatch.Groups['name'].Value] = [int]$codeMatch.Groups['value'].Value }
}
if ($errorCodes.Count -eq 0) { throw "Parsed no error codes out of $errorCodeFile." }

$pushTargets = [ordered]@{}
foreach ($line in [System.IO.File]::ReadAllLines($pushTargetFile)) {
    $pushMatch = [regex]::Match($line, '^\s*public\s+const\s+string\s+(?<name>[A-Za-z0-9_]+)\s*=\s*"(?<value>[^"]+)"\s*;')
    if ($pushMatch.Success) { $pushTargets[$pushMatch.Groups['name'].Value] = $pushMatch.Groups['value'].Value }
}
if ($pushTargets.Count -eq 0) { throw "Parsed no push targets out of $pushTargetFile." }

# ---------------------------------------------------------------------------------------------
# 7. Emit. No timestamp and no machine name anywhere in the output: this file is committed, and a
#    generator that rewrites a line on every run turns every unrelated PR into a diff.
#    输出不含时间戳与机器名：这个文件要进版本库，每次运行都改一行会把所有无关 PR 变成 diff。
# ---------------------------------------------------------------------------------------------

$byTier = [ordered]@{}
foreach ($tierKey in ($tierDefinitions.Keys | Sort-Object)) {
    $inTier = @($endpoints | Where-Object { $_.tier -eq $tierKey })
    $tierCoverage = [ordered]@{}
    foreach ($sdk in $sdkSources.Keys) {
        $tierCoverage[$sdk] = @($inTier | Where-Object { $_.implementedIn[$sdk] }).Count
    }
    $byTier[$tierKey] = [ordered]@{
        title       = $tierDefinitions[$tierKey]['title']
        titleZh     = $tierDefinitions[$tierKey]['titleZh']
        rule        = $tierDefinitions[$tierKey]['rule']
        endpoints   = $inTier.Count
        implemented = $tierCoverage
        targets     = @($inTier | ForEach-Object { $_.target })
    }
}

$document = [ordered]@{
    '$comment'    = 'GENERATED by SDK/tools/Build-EndpointInventory.ps1 from src/IM.Server. Do not edit by hand; edit the server or SDK/tools/endpoint-tiers.json and regenerate. Normative prose lives in SDK/CONTRACT.md.'
    contractVersion = $tierData['contractVersion']
    envelope      = [ordered]@{
        request       = [ordered]@{ id = 'string, unique per connection'; target = 'string'; body = 'object|null' }
        response      = [ordered]@{ id = 'string, echoes the request'; target = 'string'; status = 'int: 0 routed, 1 endpoint threw, 2 endpoint not found'; msg = 'string|null'; requestTime = 'long ticks'; completeTime = 'long ticks'; body = 'ApiResult' }
        apiResult     = [ordered]@{ code = 'int, see errorCodes'; message = 'string|null'; traceId = 'string|null'; serverTime = 'long, unix ms'; data = 'T|null' }
        jsonPolicy    = 'camelCase property names; nulls omitted on write; numbers may arrive as JSON strings; property matching is case-insensitive on read'
    }
    totals        = [ordered]@{
        endpoints   = $endpoints.Count
        controllers = @($endpoints | ForEach-Object { $_.controller } | Sort-Object -Unique).Count
        implemented = $coverageTotals
    }
    tiers         = $byTier
    endpoints     = $endpoints
    payloadTypes  = $payloadTypes
    payloadEnums  = $payloadEnums
    errorCodes    = $errorCodes
    pushTargets   = $pushTargets
}

$json = ($document | ConvertTo-Json -Depth 12).Replace("`r`n", "`n").TrimEnd() + "`n"

if ($Check) {
    # Write-Host rather than Write-Error: $ErrorActionPreference is Stop, so Write-Error would
    # turn a routine "your inventory is stale" into a PowerShell stack trace and bury the one
    # sentence that tells the reader what to run.
    # 用 Write-Host 而不是 Write-Error：本脚本 ErrorActionPreference = Stop，
    # Write-Error 会把"清单过期了"变成一段调用栈，把唯一有用的那句话埋掉。
    if (-not (Test-Path -LiteralPath $outputFile)) {
        Write-Host "SDK/endpoint-inventory.json is missing." -ForegroundColor Red
        Write-Host "  Run: pwsh -File SDK/tools/Build-EndpointInventory.ps1"
        exit 1
    }

    $onDisk = [System.IO.File]::ReadAllText($outputFile).Replace("`r`n", "`n")
    if ($onDisk -ne $json) {
        Write-Host "SDK/endpoint-inventory.json is stale." -ForegroundColor Red
        Write-Host "  The server surface, SDK/tools/endpoint-tiers.json or an SDK's coverage changed."
        Write-Host "  Run: pwsh -File SDK/tools/Build-EndpointInventory.ps1"
        exit 1
    }

    Write-Host "endpoint-inventory.json is current: $($endpoints.Count) endpoints." -ForegroundColor Green
    exit 0
}

[System.IO.File]::WriteAllText($outputFile, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host "Wrote $([System.IO.Path]::GetRelativePath($repoRoot, $outputFile).Replace('\','/'))" -ForegroundColor Green
Write-Host "  endpoints      $($endpoints.Count)"
Write-Host "  payload types  $($payloadTypes.Count) classes, $($payloadEnums.Count) enums"
Write-Host "  error codes    $($errorCodes.Count)"
Write-Host "  push targets   $($pushTargets.Count)"
foreach ($sdk in $sdkSources.Keys) {
    Write-Host ("  {0,-12} {1,3}/{2} endpoints referenced" -f $sdk, $coverageTotals[$sdk], $endpoints.Count)
}
