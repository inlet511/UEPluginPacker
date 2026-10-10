<#
.SYNOPSIS
把一个 UE 插件用指定引擎版本、指定 MSVC 工具集编译成无源码的二进制分发包。

.DESCRIPTION
在临时目录建一个 C++ 宿主工程，用 UBT 编译插件的 Editor(Development/DebugGame) 和
Game(Development/DebugGame/Shipping)，再按 UBT 输出的构建产物清单组装分发包:
  - 二进制: 编辑器 dll/pdb/.modules，单体打包用的 .obj + .precompiled，导入库 .lib，UHT 生成的头文件
  - 源码: 只保留 Build.cs(设为 bUsePrecompiled=true) 和 Public 头文件，删除所有 .cpp 和 Private 头文件
  - uplugin: 写入引擎版本，Installed=true，EnabledByDefault=false，限定平台
  - BuildInfo.json: 记录引擎/工具集/配置/源码 git 版本

.EXAMPLE
.\Build-UEPluginBinary.ps1 -ListEngines
.EXAMPLE
.\Build-UEPluginBinary.ps1 -ListToolsets
.EXAMPLE
.\Build-UEPluginBinary.ps1 -Plugin D:\MyProj\Plugins\Foo -Engine 5.4 -Toolset 14.38 -Zip -Verify
.EXAMPLE
.\Build-UEPluginBinary.ps1 -Plugin D:\MyProj\Plugins\Foo -Engine F:\UnrealEngine -OutputDir 'D:\Release\{Plugin}' -OutputName '{Plugin}-{PluginVersion}-UE{Engine}'
.EXAMPLE
.\Build-UEPluginBinary.ps1 -Config .\Jobs\Example.psd1 -Engine 5.8 -OutputDir D:\Release
.EXAMPLE
.\Build-UEPluginBinary.ps1 -AddEngine MyUE5 -EnginePath F:\UnrealEngine-Angelscript
.EXAMPLE
.\Build-UEPluginBinary.ps1 -SetDefaultOutputDir 'E:\Dist\{Plugin}'
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')][string]$Config,    # 任务配置文件(.psd1)，键名与本脚本参数相同；命令行参数优先
    [Parameter(ParameterSetName = 'Build')][string]$Plugin,    # .uplugin 路径或插件目录
    # 引擎: 名字(Launcher 版本号 4.27/5.4、-AddEngine 注册的名字、源码版引擎文件夹名)或引擎目录。-ListEngines 查看
    [Parameter(ParameterSetName = 'Build')][string]$Engine,
    [Parameter(ParameterSetName = 'Build')][string]$Toolset,   # MSVC 工具集版本(14.29 / 14.38 / 14.38.33130)；不填用本机最老的
    # 输出目录和输出名称，都可用占位符 {Plugin} {PluginVersion} {Engine} {EngineFull} {Toolset} {Date}
    # 不填时用设置文件中的默认值(初始为 <工具目录>\Output 和 {Plugin}_UE{Engine}_MSVC{Toolset})
    [Parameter(ParameterSetName = 'Build')][string]$OutputDir,
    [Parameter(ParameterSetName = 'Build')][string]$OutputName,
    [Parameter(ParameterSetName = 'Build')][string[]]$EditorConfigs = @('Development', 'DebugGame'),
    [Parameter(ParameterSetName = 'Build')][string[]]$GameConfigs = @('Development', 'DebugGame', 'Shipping'),
    [Parameter(ParameterSetName = 'Build')][string[]]$Platforms = @('Win64'),
    [Parameter(ParameterSetName = 'Build')][switch]$UsePCH,              # 默认不用 PCH/Unity 编译插件: 单体链接时不依赖 PCH 的 obj，也能暴露缺失的 include
    [Parameter(ParameterSetName = 'Build')][switch]$KeepPrivateHeaders,  # 默认删除 Private 目录下的头文件
    [Parameter(ParameterSetName = 'Build')][switch]$Zip,                 # 额外生成 zip
    [Parameter(ParameterSetName = 'Build')][switch]$Force,               # 覆盖已存在的同名输出
    [Parameter(ParameterSetName = 'Build')][switch]$Verify,              # 打包完成后调用 Test-UEPluginBinary.ps1 验证(编辑器+打包，耗时较长)
    [Parameter(ParameterSetName = 'Build')][switch]$KeepWorkDir,         # 成功后保留临时编译目录
    [Parameter(ParameterSetName = 'Build')][string]$SaveConfig,          # 把本次的设置保存为任务配置文件(.psd1)后退出，不编译
    [Parameter(ParameterSetName = 'Build')][switch]$DryRun,              # 只检查设置并显示输出位置，不编译

    [Parameter(ParameterSetName = 'ListEngines', Mandatory)][switch]$ListEngines,     # 列出本机可用的引擎
    [Parameter(ParameterSetName = 'ListToolsets', Mandatory)][switch]$ListToolsets,   # 列出本机 MSVC 工具集
    [Parameter(ParameterSetName = 'AddEngine', Mandatory)][string]$AddEngine,         # 给引擎目录起个名字，之后 -Engine 可以用这个名字
    [Parameter(ParameterSetName = 'AddEngine', Mandatory)][string]$EnginePath,
    [Parameter(ParameterSetName = 'RemoveEngine', Mandatory)][string]$RemoveEngine,   # 删除 -AddEngine 注册的名字
    [Parameter(ParameterSetName = 'SetOutput', Mandatory)][string]$SetDefaultOutputDir,  # 修改默认输出目录(可含占位符)
    [Parameter(ParameterSetName = 'SetOutput')][string]$SetDefaultOutputName,            # 修改默认输出名称(可含占位符)
    [Parameter(ParameterSetName = 'ShowSettings', Mandatory)][switch]$ShowSettings       # 显示当前设置
)
. "$PSScriptRoot\UEPP.Common.ps1"

# ---------- 设置类命令
switch ($PSCmdlet.ParameterSetName) {
    'ListEngines' {
        Get-UEEngines | Sort-Object Usable, Name -Descending |
            Format-Table @{ n = '名字(-Engine)'; e = { (@($_.Name) + $_.Aliases) -join ' / ' } }, @{ n = '版本'; e = { $_.Version } }, @{ n = '来源'; e = { $_.Source } },
                         @{ n = '状态'; e = { if ($_.Usable) { '可用' } else { $_.Problem } } }, @{ n = '路径'; e = { $_.Root } } -AutoSize -Wrap
        return
    }
    'ListToolsets' { Get-MsvcToolsets | Sort-Object { [version]$_.Version } | Format-Table Version, Compiler, VS -AutoSize; return }
    'AddEngine' {
        if ($AddEngine -match '[\\/:]') { throw '引擎名字不能包含 \ / :' }
        $info = Get-UEEngineInfo (Get-FullPath $EnginePath) $AddEngine '自定义'
        if (-not $info.Usable) { throw "$EnginePath 不可用: $($info.Problem)" }
        $s = Get-UEPPSettings; $s.Engines[$AddEngine] = $info.Root; Save-UEPPSettings $s
        Write-Host "已添加引擎 '$AddEngine' = UE $($info.Version) ($($info.Root))"
        return
    }
    'RemoveEngine' {
        $s = Get-UEPPSettings
        if (-not $s.Engines.Contains($RemoveEngine)) { throw "设置中没有名为 '$RemoveEngine' 的自定义引擎" }
        $s.Engines.Remove($RemoveEngine); Save-UEPPSettings $s
        Write-Host "已删除引擎 '$RemoveEngine'"
        return
    }
    'SetOutput' {
        $s = Get-UEPPSettings
        # 用示例值检查模板是否合法
        $sample = @{ Plugin = 'P'; PluginVersion = '1'; Engine = '5.4'; EngineFull = '5.4.0'; Toolset = '14.38'; Date = '20260101' }
        $null = Expand-UEPPTemplate $SetDefaultOutputDir $sample
        $s.DefaultOutputDir = $SetDefaultOutputDir
        if ($SetDefaultOutputName) { $null = Expand-UEPPTemplate $SetDefaultOutputName $sample; $s.OutputName = $SetDefaultOutputName }
        Save-UEPPSettings $s
        Write-Host "默认输出: $(Join-Path $s.DefaultOutputDir $s.OutputName)"
        return
    }
    'ShowSettings' {
        $s = Get-UEPPSettings
        Write-Host "设置文件:     $($script:SettingsPath)"
        Write-Host "默认输出目录: $($s.DefaultOutputDir)"
        Write-Host "默认输出名称: $($s.OutputName)"
        Write-Host '自定义引擎:'
        if ($s.Engines.Count) { $s.Engines.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) = $($_.Value)" } } else { Write-Host '  (无)' }
        return
    }
}

if ($Config) {
    $cfgPath = (Resolve-Path $Config).Path
    $cfg = Import-PowerShellDataFile $cfgPath
    foreach ($k in $cfg.Keys) {
        if ($PSBoundParameters.ContainsKey($k)) { continue }
        $v = $cfg[$k]
        # 配置文件里的相对路径相对于配置文件所在目录
        if ($k -in 'Plugin', 'OutputDir' -and $v -and -not [IO.Path]::IsPathRooted($v)) { $v = Join-Path (Split-Path $cfgPath) $v }
        if ($k -eq 'Engine' -and $v -match '^\.\.?[\\/]') { $v = Join-Path (Split-Path $cfgPath) $v }
        Set-Variable -Name $k -Value $v
    }
}

if ($SaveConfig) {
    if (-not $Plugin -or -not $Engine) { throw '保存任务配置至少需要 -Plugin 和 -Engine' }
    $job = [ordered]@{ Plugin = (Get-FullPath $Plugin); Engine = $Engine }
    foreach ($k in 'Toolset', 'OutputDir', 'OutputName') { $v = Get-Variable $k -ValueOnly; if ($v) { $job[$k] = $v } }
    $job.EditorConfigs = $EditorConfigs; $job.GameConfigs = $GameConfigs; $job.Platforms = $Platforms
    foreach ($k in 'UsePCH', 'KeepPrivateHeaders', 'Zip', 'Verify') { if (Get-Variable $k -ValueOnly) { $job[$k] = $true } }
    Write-Utf8Bom (Get-FullPath $SaveConfig) (ConvertTo-Psd1 $job "任务配置。用法: .\Build-UEPluginBinary.ps1 -Config <本文件>`n命令行参数会覆盖这里的值。相对路径相对于本文件所在目录。")
    Write-Host "已保存任务配置: $(Get-FullPath $SaveConfig)"
    return
}

# ---------- 解析输入
if (-not $Plugin -or -not $Engine) { throw '必须指定 -Plugin 和 -Engine (或在 -Config 中提供)。可用 -ListEngines 查看引擎' }
$srcFile  = Resolve-UPluginFile $Plugin
$srcDir   = Split-Path $srcFile
$name     = [IO.Path]::GetFileNameWithoutExtension($srcFile)
$uplugin  = Get-UPlugin $srcFile
$modules  = @(Get-PluginModules $uplugin | Where-Object Kind -ne 'Skip')
if (-not $modules) { throw "$name 没有 C++ 模块，不需要编译" }
$UE       = Resolve-UEEngine $Engine
$tool     = Select-MsvcToolset $Toolset
$settings = Get-UEPPSettings
if (-not $OutputDir) { $OutputDir = $settings.DefaultOutputDir }
if (-not $OutputName) { $OutputName = $settings.OutputName }

$outRoot  = Get-UEPPOutputRoot $OutputDir $OutputName $uplugin $name $UE $tool
$dist     = Join-Path $outRoot $name
$work     = Join-Path $env:TEMP "UEPP\${name}_$($UE.Short)"
$workPlug = Join-Path $work "Plugins\$name"
$logs     = Join-Path $work 'Logs'
if ($outRoot.StartsWith($srcDir, 'OrdinalIgnoreCase')) { throw '输出目录不能在插件源码目录里面' }

Write-Host "插件:   $name ($srcDir)"
Write-Host "引擎:   UE $($UE.Version) [$($UE.Name)] ($($UE.Root))"
Write-Host "工具集: MSVC $($tool.Version) [$($tool.Compiler)] ($($tool.VS))"
Write-Host "模块:   $(($modules | ForEach-Object { "$($_.Name)($($_.Type))" }) -join ', ')"
Write-Host "输出:   $dist"

if ($DryRun) {
    if (Test-Path $outRoot) { Write-Warning "输出已存在，正式运行时需要加 -Force: $outRoot" }
    Write-Host '设置检查通过 (DryRun，未编译)' -ForegroundColor Green
    return
}
if (Test-Path $outRoot) {
    if (-not $Force) { throw "输出已存在: $outRoot (加 -Force 覆盖)" }
    Remove-Item $outRoot -Recurse -Force
}

# ---------- 准备宿主工程
Write-Step '准备宿主工程'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
robocopy $srcDir $workPlug /E /NFL /NDL /NJH /NJS /NP /XD "$srcDir\Binaries" "$srcDir\Intermediate" "$srcDir\Saved" .git .vs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "复制插件源码失败 (robocopy $LASTEXITCODE)" }
if (Test-Path "$srcDir\Binaries\ThirdParty") { robocopy "$srcDir\Binaries\ThirdParty" "$workPlug\Binaries\ThirdParty" /E /NFL /NDL /NJH /NJS /NP | Out-Null }

$distUPlugin = New-DistUPlugin $uplugin $UE $Platforms
Write-Utf8 "$workPlug\$name.uplugin" ($distUPlugin | ConvertTo-Json -Depth 20)

# bPrecompile=true: 让 UBT 为插件生成单体链接用的 .precompiled 清单，并把 DebugGame 按工程插件的方式单独编译
$compileRules = @('bPrecompile = true;', 'bUsePrecompiled = false;')
if (-not $UsePCH) { $compileRules += 'PCHUsage = PCHUsageMode.NoPCHs;', 'bUseUnity = false;' }
foreach ($m in $modules) {
    $cs = @(Get-ChildItem "$workPlug\Source" -Recurse -Filter "$($m.Name).Build.cs")
    if ($cs.Count -ne 1) { throw "找不到唯一的 $($m.Name).Build.cs" }
    Set-BuildCsRules $cs[0].FullName $compileRules
}

$hostProj = Join-Path $work 'Builder.uproject'
# 源码版引擎不写 EngineAssociation，避免被关联到别的同版本引擎；编译时始终使用 $UE 自己的 Build.bat
$assoc = if ($UE.IsSourceBuild) { '' } else { $UE.Short }
Write-Utf8 $hostProj (@{ FileVersion = 3; EngineAssociation = $assoc; Modules = @(@{ Name = 'Builder'; Type = 'Runtime'; LoadingPhase = 'Default' }); Plugins = @(@{ Name = $name; Enabled = $true }) } | ConvertTo-Json -Depth 5)
Write-Utf8 "$work\Source\Builder.Target.cs" (New-TargetCs 'Builder' 'Game' @('Builder') $UE)
Write-Utf8 "$work\Source\BuilderEditor.Target.cs" (New-TargetCs 'BuilderEditor' 'Editor' @('Builder') $UE)
New-HostModule $work 'Builder'
# ---------- 编译 (Editor 链接出 dll；Game 只要 .obj + .precompiled，跳过链接 exe)
$jobs = @()
foreach ($c in $EditorConfigs) { $jobs += , @('BuilderEditor', 'Win64', $c, @()) }
foreach ($p in $Platforms) { foreach ($c in $GameConfigs) { $jobs += , @('Builder', $p, $c, @('-NoLink')) } }
$manifests = @()
foreach ($j in $jobs) {
    $target, $plat, $cfgName, $extra = $j
    Write-Step "编译 $target $plat $cfgName"
    $manifest = Join-Path $work "Saved\Manifest-$target-$plat-$cfgName.xml"
    $manifests += $manifest
    $ubtArgs = @($target, $plat, $cfgName, "-Project=$hostProj", "-Manifest=$manifest", '-WaitMutex', "-Compiler=$($tool.Compiler)", "-CompilerVersion=$($tool.Version)") + $extra
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Logged $UE.BuildBat $ubtArgs (Join-Path $logs "ubt-$target-$plat-$cfgName.log")
    Write-Host "  完成 ($([int]$sw.Elapsed.TotalSeconds)s)"
}

# ---------- 收集插件的构建产物 (以 UBT 清单为准)
Write-Step '组装分发包'
$products = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
foreach ($mf in $manifests) {
    $xml = [xml](Get-Content $mf -Raw)
    foreach ($node in $xml.SelectNodes('//BuildProducts/*')) {
        $p = [IO.Path]::GetFullPath($node.InnerText)
        if ($p.StartsWith("$workPlug\", 'OrdinalIgnoreCase') -and $p -notlike '*.suppressed.lib') { [void]$products.Add($p) }
    }
}
if ($products.Count -eq 0) { throw '构建清单中没有插件的产物，请检查日志' }

New-Item -ItemType Directory -Force $dist | Out-Null
Write-Utf8 "$dist\$name.uplugin" ($distUPlugin | ConvertTo-Json -Depth 20)
foreach ($d in 'Resources', 'Content', 'Config', 'Shaders', 'Binaries\ThirdParty') {
    if (Test-Path "$workPlug\$d") { robocopy "$workPlug\$d" "$dist\$d" /E /NFL /NDL /NJH /NJS /NP | Out-Null }
}

# Source: 从原始源码复制(不含注入内容)，删除实现文件
robocopy "$srcDir\Source" "$dist\Source" /E /NFL /NDL /NJH /NJS /NP /XF *.cpp *.c *.cc *.cxx *.mm *.m | Out-Null
if (-not $KeepPrivateHeaders) {
    Get-ChildItem "$dist\Source" -Recurse -Directory | Where-Object Name -eq 'Private' | ForEach-Object {
        Get-ChildItem $_.FullName -Recurse -File -Include *.h, *.hpp, *.inl | Remove-Item
    }
}
Get-ChildItem "$dist\Source" -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
    Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item
foreach ($m in $modules) {
    Set-BuildCsRules @(Get-ChildItem "$dist\Source" -Recurse -Filter "$($m.Name).Build.cs")[0].FullName @('bUsePrecompiled = true;', 'bPrecompile = false;')
}

$missing = @()
foreach ($p in $products) {
    if (-not (Test-Path $p)) { $missing += $p; continue }
    $dst = Join-Path $dist $p.Substring($workPlug.Length + 1)
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $p $dst
}
if ($missing) { $missing | ForEach-Object { Write-Warning "清单中列出但未生成: $_" } }
# ---------- BuildInfo.json: 方便拿到包的人知道它对应什么
$commit = $null; $dirty = $null
if (git -C $srcDir rev-parse --is-inside-work-tree 2>$null) {
    $commit = git -C $srcDir rev-parse --short HEAD
    $dirty = [bool](git -C $srcDir status --porcelain -- . 2>$null)
}
Write-Utf8 "$dist\BuildInfo.json" ([ordered]@{
    Plugin            = $name
    PluginVersion     = $uplugin.VersionName
    EngineVersion     = $UE.Version
    MsvcToolset       = $tool.Version
    Compiler          = $tool.Compiler
    EditorConfigs     = $EditorConfigs
    GameConfigs       = $GameConfigs
    Platforms         = $Platforms
    UsePCH            = [bool]$UsePCH
    SourceGitCommit   = $commit
    SourceHasLocalChanges = $dirty
    BuiltAt           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Note              = "打包游戏时链接器需为 MSVC $($tool.Version) 或更新版本"
} | ConvertTo-Json)
if ($dirty) { Write-Warning '插件源码有未提交的修改，BuildInfo.json 中已标记 SourceHasLocalChanges=true' }

$fileCount = @(Get-ChildItem $dist -Recurse -File).Count
$leaked = @(Get-ChildItem $dist -Recurse -File -Include *.cpp, *.c, *.cc, *.cxx)
if ($leaked) { throw "分发包中仍有源码文件: $($leaked.FullName -join ', ')" }
Write-Host "  $fileCount 个文件 -> $dist"

if ($Zip) {
    $zipPath = "$outRoot.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Compress-Archive -Path $dist -DestinationPath $zipPath
    Write-Host "  zip -> $zipPath"
}

# ---------- 验证
if ($Verify) {
    Write-Step '验证分发包'
    try { & "$PSScriptRoot\Test-UEPluginBinary.ps1" -Plugin $dist -Engine $UE.Root -EditorConfigs $EditorConfigs -GameConfigs $GameConfigs }
    catch { throw "$($_.Exception.Message)`n分发包保留在 $dist，编译临时目录保留在 $work" }
}

if (-not $KeepWorkDir) { Remove-Item $work -Recurse -Force }
Write-Host "`n完成: $dist" -ForegroundColor Green
