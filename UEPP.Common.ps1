# UEPP (UE Plugin Packager) 公共函数，由 Build-UEPluginBinary.ps1 / Test-UEPluginBinary.ps1 引用
$ErrorActionPreference = 'Stop'
# 该环境变量会让 RunUAT.bat / Build.bat 找不到当前目录下的 exe ("AutomationTool.exe is not recognized")
Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Write-Step([string]$Text) { Write-Host "`n==== $Text" -ForegroundColor Cyan }

function Write-Utf8Bom([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

# 相对路径按当前目录展开为绝对路径(路径不必存在)
function Get-FullPath([string]$Path) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }

# ---------- 用户设置 (UEPP.Settings.json，与脚本同目录；GUI 和命令行共用)
$script:SettingsPath = Join-Path $PSScriptRoot 'UEPP.Settings.json'

function ConvertTo-HashtableDeep($o) {
    if ($o -is [Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
        return $h
    }
    if ($o -is [Array]) { return , @($o | ForEach-Object { ConvertTo-HashtableDeep $_ }) }
    $o
}

function Get-UEPPSettings {
    $s = [ordered]@{}
    if (Test-Path $script:SettingsPath) {
        try { $s = ConvertTo-HashtableDeep (Get-Content $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-Warning "设置文件格式错误，已忽略: $($script:SettingsPath)" ; $s = [ordered]@{} }
    }
    if (-not $s.DefaultOutputDir) { $s.DefaultOutputDir = Join-Path $PSScriptRoot 'Output' }
    if (-not $s.OutputName) { $s.OutputName = '{Plugin}_UE{Engine}_MSVC{Toolset}' }
    if (-not $s.Engines) { $s.Engines = [ordered]@{} }
    $s
}

function Save-UEPPSettings($Settings) { Write-Utf8 $script:SettingsPath ($Settings | ConvertTo-Json -Depth 6) }

# 输出目录/名称模板中可用的占位符
$script:TemplateTokens = 'Plugin', 'PluginVersion', 'Engine', 'EngineFull', 'Toolset', 'Date'
function Expand-UEPPTemplate([string]$Text, [hashtable]$Tokens) {
    foreach ($k in $Tokens.Keys) { $Text = $Text.Replace("{$k}", [string]$Tokens[$k]) }
    $left = [regex]::Matches($Text, '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value }
    if ($left) { throw "未知的占位符: {$($left -join '}, {')}。可用: {$($script:TemplateTokens -join '}, {')}" }
    $Text
}

# ---------- 引擎
# 由引擎目录生成引擎信息；可传引擎根目录或其下的 Engine 目录。不可用时 Usable=$false 并给出原因
function Get-UEEngineInfo([string]$Path, [string]$Name, [string]$Source = '指定路径') {
    $root = $Path.Replace('/', '\').TrimEnd('\')
    if ((Test-Path "$root\Build\Build.version") -and -not (Test-Path "$root\Engine\Build\Build.version")) { $root = Split-Path $root }
    try { $root = [IO.Path]::GetFullPath($root) } catch { }
    if (-not $Name) { $Name = Split-Path $root -Leaf }
    $info = [ordered]@{ Name = $Name; Source = $Source; Root = $root; Aliases = @(); Usable = $false; Problem = $null; Version = '?'; Short = '?' }
    $verFile = "$root\Engine\Build\Build.version"
    if (-not (Test-Path $verFile)) {
        $info.Problem = $(if (Test-Path $root) { '不是 UE 引擎目录(找不到 Engine\Build\Build.version)' } else { '目录不存在(已卸载?)' })
    } else {
        $v = Get-Content $verFile -Raw | ConvertFrom-Json
        $ue5 = $v.MajorVersion -ge 5
        $info.Major        = [int]$v.MajorVersion
        $info.Minor        = [int]$v.MinorVersion
        $info.Version      = "$($v.MajorVersion).$($v.MinorVersion).$($v.PatchVersion)"
        $info.Short        = "$($v.MajorVersion).$($v.MinorVersion)"
        $info.BuildBat     = "$root\Engine\Build\BatchFiles\Build.bat"
        $info.RunUAT       = "$root\Engine\Build\BatchFiles\RunUAT.bat"
        $info.BinDir       = "$root\Engine\Binaries\Win64"
        $info.EditorPrefix = $(if ($ue5) { 'UnrealEditor' } else { 'UE4Editor' })
        $info.StageDir     = $(if ($ue5) { 'Windows' } else { 'WindowsNoEditor' })
        $info.IsSourceBuild = -not (Test-Path "$root\Engine\Build\InstalledBuild.txt")
        if (-not (Test-Path $info.BuildBat)) { $info.Problem = '引擎安装不完整(缺少 Build.bat)' }
        else { $info.Usable = $true }
    }
    [pscustomobject]$info
}

# 本机所有引擎: 设置文件中自定义的 + Launcher 安装的 + 已注册的源码版引擎
function Get-UEEngines {
    $settings = Get-UEPPSettings
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($k in $settings.Engines.Keys) { $found.Add((Get-UEEngineInfo $settings.Engines[$k] $k '自定义')) }
    foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\EpicGames\Unreal Engine' -ErrorAction SilentlyContinue) {
        $dir = (Get-ItemProperty $k.PSPath).InstalledDirectory
        if ($dir) { $found.Add((Get-UEEngineInfo $dir $k.PSChildName 'Launcher')) }
    }
    $builds = Get-ItemProperty 'HKCU:\Software\Epic Games\Unreal Engine\Builds' -ErrorAction SilentlyContinue
    if ($builds) {
        foreach ($p in $builds.PSObject.Properties | Where-Object Name -notlike 'PS*') { $found.Add((Get-UEEngineInfo $p.Value $null '源码版')) }
    }
    # 同一目录只保留一项(自定义优先)，其它来源的名字记为别名；不同目录重名时后者用目录作为名字
    $byRoot = [ordered]@{}; $names = @{}
    foreach ($e in $found) {
        if ($byRoot.Contains($e.Root)) {
            $first = $byRoot[$e.Root]
            if ($e.Name -ne $first.Name -and -not $names.ContainsKey($e.Name)) { $first.Aliases += $e.Name; $names[$e.Name] = $true }
            continue
        }
        if ($names.ContainsKey($e.Name)) { $e.Name = $e.Root }
        $names[$e.Name] = $true
        $e | Add-Member -NotePropertyName Aliases -NotePropertyValue @() -Force
        $byRoot[$e.Root] = $e
    }
    $byRoot.Values
}

# 引擎: 可传名字(Launcher 版本号如 4.27、自定义名字、源码版引擎文件夹名)或引擎目录
function Resolve-UEEngine([string]$Engine) {
    if (-not $Engine) { throw '没有指定引擎' }
    $all = @(Get-UEEngines)
    $e = $all | Where-Object { $_.Name -eq $Engine -or $Engine -in $_.Aliases } | Select-Object -First 1
    if (-not $e -and (Test-Path $Engine)) {
        $info = Get-UEEngineInfo (Resolve-Path $Engine).Path
        # 指定的目录如果已经登记过，用登记的名字
        $e = $all | Where-Object Root -eq $info.Root | Select-Object -First 1
        if (-not $e) { $e = $info }
    }
    if (-not $e) {
        $names = ($all | Where-Object Usable | ForEach-Object { @($_.Name) + $_.Aliases } | Select-Object -Unique) -join ', '
        throw "找不到引擎 '$Engine'。可用的引擎: $names (也可以直接传引擎目录)"
    }
    if (-not $e.Usable) { throw "引擎 '$($e.Name)' ($($e.Root)) 不可用: $($e.Problem)" }
    $e
}

# 本机已安装的 MSVC 工具集 (所有 VS 版本，含 VS2022 内装的 v142 等旧工具集)
function Get-MsvcToolsets {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw '找不到 vswhere.exe，未安装 Visual Studio?' }
    $installs = & $vswhere -all -products * -format json | ConvertFrom-Json
    $seen = @{}
    foreach ($i in $installs) {
        $dir = Join-Path $i.installationPath 'VC\Tools\MSVC'
        if (-not (Test-Path $dir)) { continue }
        foreach ($t in Get-ChildItem $dir -Directory) {
            if ($seen.ContainsKey($t.Name)) { continue }
            $seen[$t.Name] = $true
            $minor = [int]($t.Name.Split('.')[1])
            # UBT 的编译器分类: 14.1x=2017, 14.2x=2019, 14.3x 及以上=2022 (VS18 的 14.5x 在 UE 里也按 2022 处理)
            $compiler = if ($minor -lt 20) { 'VisualStudio2017' } elseif ($minor -lt 30) { 'VisualStudio2019' } else { 'VisualStudio2022' }
            [pscustomobject]@{ Version = $t.Name; Compiler = $compiler; VS = $i.displayName; Path = $t.FullName }
        }
    }
}

function Select-MsvcToolset([string]$Toolset) {
    $all = @(Get-MsvcToolsets | Sort-Object { [version]$_.Version })
    if (-not $all) { throw '本机没有找到任何 MSVC 工具集' }
    if ($Toolset) {
        $m = @($all | Where-Object { $_.Version -eq $Toolset -or $_.Version.StartsWith("$Toolset.") })
        if (-not $m) { throw "找不到 MSVC 工具集 '$Toolset'。已安装: $(($all.Version) -join ', ')" }
        return $m[0]
    }
    # 默认选最老的: 产出的 .obj 能被更多版本的 VS 链接
    Write-Warning "未指定 -Toolset，使用本机最老的 MSVC $($all[0].Version)"
    return $all[0]
}

# 运行命令并把输出写到日志；失败时打印日志里的错误行
function Invoke-Logged([string]$Exe, [string[]]$ArgList, [string]$Log) {
    New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
    & $Exe @ArgList *> $Log
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Get-Content $Log | Where-Object { $_ -match '(?i)\berror\b|failed' -and $_ -notmatch 'BuildConfiguration\.xml' } |
            Select-Object -First 25 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "命令失败 (exit $code)，完整日志: $Log"
    }
}

function Get-UPlugin([string]$Path) { Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json }

# 插件参数可以是 .uplugin 文件或插件目录
function Resolve-UPluginFile([string]$Plugin) {
    if (-not $Plugin -or -not (Test-Path $Plugin)) { throw "插件路径不存在: $Plugin" }
    if ((Get-Item $Plugin).PSIsContainer) {
        $f = @(Get-ChildItem $Plugin -Filter *.uplugin)
        if (-not $f) { throw "在 $Plugin 中找不到 .uplugin" }
        return $f[0].FullName
    }
    (Resolve-Path $Plugin).Path
}

# 计算最终输出目录 (OutputDir 和 OutputName 都支持占位符)
function Get-UEPPOutputRoot([string]$OutputDir, [string]$OutputName, $UPlugin, [string]$PluginName, $UE, $Tool) {
    $tokens = @{
        Plugin        = $PluginName
        PluginVersion = $(if ($UPlugin.VersionName) { $UPlugin.VersionName } else { "$($UPlugin.Version)" })
        Engine        = $UE.Short
        EngineFull    = $UE.Version
        Toolset       = $Tool.Version
        Date          = (Get-Date).ToString('yyyyMMdd')
    }
    $dir  = Get-FullPath (Expand-UEPPTemplate $OutputDir $tokens)
    $name = Expand-UEPPTemplate $OutputName $tokens
    if (-not $name -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "输出名称不合法: '$name'" }
    Join-Path $dir $name
}

# 把哈希表写成 .psd1 (任务配置文件)
function ConvertTo-Psd1Value($v) {
    if ($null -eq $v) { return '$null' }
    if ($v -is [bool] -or $v -is [Management.Automation.SwitchParameter]) { return '$' + ([bool]$v).ToString().ToLower() }
    if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return "$v" }
    if ($v -is [Collections.IEnumerable] -and $v -isnot [string]) { return '@(' + ((@($v) | ForEach-Object { ConvertTo-Psd1Value $_ }) -join ', ') + ')' }
    "'" + ("$v" -replace "'", "''") + "'"
}
function ConvertTo-Psd1($Table, [string]$Header = '') {
    $lines = @()
    if ($Header) { $lines += ($Header -split "`n" | ForEach-Object { "# $_" }) }
    $lines += '@{'
    $width = ($Table.Keys | Measure-Object -Maximum Length).Maximum
    foreach ($k in $Table.Keys) { $lines += "    $($k.PadRight($width)) = $(ConvertTo-Psd1Value $Table[$k])" }
    $lines += '}'
    ($lines -join "`r`n") + "`r`n"
}

function Set-JsonProp($Obj, [string]$Name, $Value) { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }

# 分发用 uplugin: 写入引擎版本、标记已安装、限定平台
# EnabledByDefault=false 很关键: 否则纯蓝图工程打包时 UAT 认为插件已在引擎自带的 exe 里，不会生成临时 target，插件代码不会被打进包
function New-DistUPlugin($Src, $UE, [string[]]$Platforms) {
    $d = $Src | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    Set-JsonProp $d 'EngineVersion' "$($UE.Short).0"
    Set-JsonProp $d 'Installed' $true
    Set-JsonProp $d 'EnabledByDefault' $false
    Set-JsonProp $d 'SupportedTargetPlatforms' $Platforms
    $d
}

# 按 uplugin 中的模块类型分组: Game(运行时) / Editor(编辑器和开发工具) / Program(忽略)
function Get-PluginModules($UPlugin) {
    foreach ($m in @($UPlugin.Modules)) {
        if (-not $m) { continue }
        $kind = if ($m.Type -match '^(Editor|Developer|UncookedOnly)') { 'Editor' } elseif ($m.Type -match 'Program|ServerOnly') { 'Skip' } else { 'Game' }
        [pscustomobject]@{ Name = $m.Name; Type = $m.Type; Kind = $kind }
    }
}

# 在 ModuleRules 构造函数开头注入设置，并把原有的同名赋值注释掉，保证注入值生效
function Set-BuildCsRules([string]$Path, [string[]]$Lines) {
    $text = [IO.File]::ReadAllText($Path)
    foreach ($l in $Lines) {
        $field = ($l -split '=')[0].Trim()
        $text = [regex]::Replace($text, "(?m)^([ \t]*)((?:this\.)?$field\s*=[^\r\n]*)", '$1// [UEPP] $2')
    }
    $m = [regex]::Match($text, ':\s*base\s*\([^)]*\)\s*\{')
    if (-not $m.Success) { throw "无法在 $Path 中找到 ModuleRules 构造函数" }
    $inject = "`r`n`t`t// [UEPP] 由插件打包工具注入`r`n" + (($Lines | ForEach-Object { "`t`t$_" }) -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($Path, $text.Insert($m.Index + $m.Length, $inject), $script:Utf8NoBom)
}

# 宿主工程的 Target.cs (构建设置与引擎默认一致，否则 UE5 会拒绝与引擎共享构建产物)
function New-TargetCs([string]$Name, [string]$Type, [string[]]$Modules, $UE) {
    $v = $UE.Major * 100 + $UE.Minor
    $settings = if ($v -ge 501) { "DefaultBuildSettings = BuildSettingsVersion.Latest;`n`t`tIncludeOrderVersion = EngineIncludeOrderVersion.Latest;" }
                elseif ($v -ge 424) { 'DefaultBuildSettings = BuildSettingsVersion.Latest;' } else { '' }
    $mods = ($Modules | ForEach-Object { "`"$_`"" }) -join ', '
@"
using UnrealBuildTool;
public class ${Name}Target : TargetRules
{
	public ${Name}Target(TargetInfo Target) : base(Target)
	{
		Type = TargetType.$Type;
		$settings
		ExtraModuleNames.AddRange(new string[] { $mods });
	}
}
"@
}

# 宿主工程的主模块 (只为了让工程成为 C++ 工程)；可依赖插件模块，编辑器模块只在编辑器目标里依赖
function New-HostModule([string]$Root, [string]$Name, [string[]]$GameDeps = @(), [string[]]$EditorDeps = @(), [string]$ExtraCpp = '') {
    $q = { param($list) ($list | ForEach-Object { "`"$_`"" }) -join ', ' }
    $gameList = & $q (@('Core', 'CoreUObject', 'Engine') + $GameDeps)
    $editorLine = if ($EditorDeps) { "`n`t`tif (Target.bBuildEditor) { PublicDependencyModuleNames.AddRange(new string[] { $(& $q $EditorDeps) }); }" } else { '' }
    Write-Utf8 "$Root\Source\$Name\$Name.Build.cs" "using UnrealBuildTool;`npublic class $Name : ModuleRules`n{`n`tpublic $Name(ReadOnlyTargetRules Target) : base(Target)`n`t{`n`t`tPCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;`n`t`tPublicDependencyModuleNames.AddRange(new string[] { $gameList });$editorLine`n`t}`n}`n"
    Write-Utf8 "$Root\Source\$Name\$Name.cpp" "#include `"Modules/ModuleManager.h`"`n$ExtraCpp`nIMPLEMENT_PRIMARY_GAME_MODULE(FDefaultGameModuleImpl, $Name, `"$Name`");`n"
}
