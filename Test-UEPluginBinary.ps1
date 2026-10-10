<#
.SYNOPSIS
验证一个无源码插件分发包: 在临时的纯蓝图工程和 C++ 工程中，分别在编辑器中运行和打包后运行。

.DESCRIPTION
对每个 Editor 配置: 编译 C++ 测试工程(依赖插件全部模块，并 include 插件全部 Public 头文件)，
  再用编辑器 -game 模式启动两个工程，检查插件加载成功。
对每个 Game 配置: 两个工程分别 BuildCookRun 打包，检查工程自己的 exe 被打出来(说明插件代码被链接进去)，
  再运行打包结果检查插件加载成功。Shipping 不输出日志，只检查能正常运行不崩溃。

.EXAMPLE
.\Test-UEPluginBinary.ps1 -Plugin .\Output\Foo_UE5.4_MSVC14.38.33130\Foo -Engine 5.4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Plugin,   # 分发包中的插件目录
    [Parameter(Mandatory)][string]$Engine,
    [string[]]$EditorConfigs = @('Development', 'DebugGame'),
    [string[]]$GameConfigs = @('Development', 'DebugGame', 'Shipping'),
    [switch]$SkipPackage,                    # 只测编辑器，不打包
    [switch]$NoHeaderCheck,                  # 不在 C++ 测试工程中 include 插件的 Public 头文件
    [int]$RunTimeoutSec = 180,
    [switch]$KeepWorkDir
)
. "$PSScriptRoot\UEPP.Common.ps1"

$plugDir  = (Resolve-Path $Plugin).Path
$upFile   = @(Get-ChildItem $plugDir -Filter *.uplugin)[0].FullName
$name     = [IO.Path]::GetFileNameWithoutExtension($upFile)
$modules  = @(Get-PluginModules (Get-UPlugin $upFile))
$gameMods = @($modules | Where-Object Kind -eq 'Game' | ForEach-Object Name)
$edMods   = @($modules | Where-Object Kind -eq 'Editor' | ForEach-Object Name)
$UE       = Resolve-UEEngine $Engine
$work     = Join-Path $env:TEMP "UEPP\Test_${name}_$($UE.Short)"
$logs     = Join-Path $work 'Logs'
$results  = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Step, [string[]]$Problems, [switch]$Skip) {
    $r = if ($Skip) { 'SKIP' } elseif ($Problems) { 'FAIL' } else { 'PASS' }
    $results.Add([pscustomobject]@{ Step = $Step; Result = $r; Detail = ($Problems -join '; ') })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'Yellow' }[$r]
    Write-Host "  [$r] $Step $(if ($Problems) { '- ' + ($Problems -join '; ') })" -ForegroundColor $color
}

# 运行 exe 并检查日志，返回问题列表(空 = 通过)。ExpectExit=false 用于 Shipping: 只要求运行一段时间不崩溃
function Test-Run([string]$Exe, [string[]]$ArgList, [string]$LogFile, [bool]$ExpectExit = $true) {
    $problems = @()
    if ($LogFile) { Remove-Item $LogFile -ErrorAction SilentlyContinue }
    $p = Start-Process $Exe -ArgumentList $ArgList -PassThru -WindowStyle Hidden
    $null = $p.Handle   # 保证进程结束后能取到 ExitCode
    $limit = if ($ExpectExit) { $RunTimeoutSec } else { 20 }
    if ($p.WaitForExit($limit * 1000)) {
        if ($p.ExitCode -ne 0) { $problems += "exit=$($p.ExitCode)" }
    } else {
        $p.Kill()
        if ($ExpectExit) { $problems += "超过 $limit 秒没有退出" }
    }
    if ($LogFile) {
        if (-not (Test-Path $LogFile)) { return $problems + "没有日志 $LogFile" }
        $log = Get-Content $LogFile -Raw
        $n = [regex]::Escape($name)
        if ($log -notmatch "Mounting (\w+ )?plugin $n\b") { $problems += '日志中没有插件挂载记录' }
        $modPattern = ($modules.Name | ForEach-Object { [regex]::Escape($_) }) -join '|'
        foreach ($m in [regex]::Matches($log, "(?im)^.*(Unable to load module '($modPattern)'|Plugin '$n' failed to load|Fatal error).*$")) {
            $problems += $m.Value.Trim()
        }
    }
    $problems
}

# ---------- 创建测试工程
Write-Step "创建测试工程 (UE $($UE.Version))"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
$projects = @{}
foreach ($pn in 'TestBP', 'TestCpp') {
    $root = Join-Path $work $pn
    $desc = [ordered]@{ FileVersion = 3; EngineAssociation = $(if ($UE.IsSourceBuild) { '' } else { $UE.Short }) }
    if ($pn -eq 'TestCpp') { $desc.Modules = @(@{ Name = 'TestCpp'; Type = 'Runtime'; LoadingPhase = 'Default' }) }
    $desc.Plugins = @(@{ Name = $name; Enabled = $true })
    Write-Utf8 "$root\$pn.uproject" ($desc | ConvertTo-Json -Depth 5)
    Write-Utf8 "$root\Config\DefaultEngine.ini" "[/Script/EngineSettings.GameMapsSettings]`nGameDefaultMap=/Engine/Maps/Entry`nEditorStartupMap=/Engine/Maps/Entry`n"
    Write-Utf8 "$root\Config\DefaultGame.ini" "[/Script/UnrealEd.ProjectPackagingSettings]`n+MapsToCook=(FilePath=`"/Engine/Maps/Entry`")`n"
    robocopy $plugDir "$root\Plugins\$name" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    $projects[$pn] = "$root\$pn.uproject"
}
# TestCpp: 依赖插件全部模块；include 运行时模块的全部 Public 头文件，检查头文件能独立编译
$cppRoot = Split-Path $projects.TestCpp
$includes = ''
if (-not $NoHeaderCheck) {
    foreach ($m in $gameMods) {
        $modDir = Split-Path @(Get-ChildItem "$plugDir\Source" -Recurse -Filter "$m.Build.cs")[0].FullName
        foreach ($sub in 'Public', 'Classes') {
            if (-not (Test-Path "$modDir\$sub")) { continue }
            Get-ChildItem "$modDir\$sub" -Recurse -File -Include *.h | ForEach-Object {
                $includes += "#include `"$($_.FullName.Substring($modDir.Length + $sub.Length + 2).Replace('\', '/'))`"`n"
            }
        }
    }
}
Write-Utf8 "$cppRoot\Source\TestCpp.Target.cs" (New-TargetCs 'TestCpp' 'Game' @('TestCpp') $UE)
Write-Utf8 "$cppRoot\Source\TestCppEditor.Target.cs" (New-TargetCs 'TestCppEditor' 'Editor' @('TestCpp') $UE)
New-HostModule $cppRoot 'TestCpp' $gameMods $edMods $includes

# ---------- 编辑器
foreach ($cfg in $EditorConfigs) {
    Write-Step "编辑器 $cfg"
    try {
        Invoke-Logged $UE.BuildBat @('TestCppEditor', 'Win64', $cfg, "-Project=$($projects.TestCpp)", '-WaitMutex') (Join-Path $logs "ubt-TestCppEditor-$cfg.log")
        Add-Result "Editor $cfg / TestCpp 编译" @()
    } catch {
        Add-Result "Editor $cfg / TestCpp 编译" @("$($_.Exception.Message)$(if ($includes) { ' (若是插件头文件不能独立编译，可加 -NoHeaderCheck)' })")
    }
    $exeName = if ($cfg -eq 'Development') { "$($UE.EditorPrefix)-Cmd.exe" } else { "$($UE.EditorPrefix)-Win64-$cfg-Cmd.exe" }
    $exe = Join-Path $UE.BinDir $exeName
    foreach ($pn in 'TestBP', 'TestCpp') {
        if (-not (Test-Path $exe)) { Add-Result "Editor $cfg / $pn 运行" @("引擎中没有 $exeName"); continue }
        $runArgs = @($projects[$pn], '-game', '-nullrhi', '-unattended', '-nosplash', '-nosound', '-log', '-ExecCmds="quit"')
        if ($cfg -eq 'DebugGame') { $runArgs += '-debug' }
        Add-Result "Editor $cfg / $pn 运行" (Test-Run $exe $runArgs "$(Split-Path $projects[$pn])\Saved\Logs\$pn.log")
    }
}
# ---------- 打包
if ($SkipPackage) {
    Add-Result '打包' @() -Skip
} elseif (-not $gameMods) {
    Add-Result '打包 (插件没有运行时模块)' @() -Skip
} else {
    foreach ($pn in 'TestBP', 'TestCpp') {
        $cooked = $false
        foreach ($cfg in $GameConfigs) {
            Write-Step "打包 $pn $cfg"
            $arch = Join-Path $work "Pkg\$pn-$cfg"
            $uatArgs = @('BuildCookRun', "-project=$($projects[$pn])", '-noP4', '-platform=Win64', "-clientconfig=$cfg", '-build',
                         $(if ($cooked) { '-skipcook' } else { '-cook' }), '-stage', '-pak', '-archive', "-archivedirectory=$arch", '-unattended', '-utf8output')
            try { Invoke-Logged $UE.RunUAT $uatArgs (Join-Path $logs "uat-$pn-$cfg.log"); $cooked = $true }
            catch { Add-Result "打包 $pn $cfg" @($_.Exception.Message); continue }

            # 工程自己的 exe 被打出来，才说明插件代码被链接进去了(否则 UAT 会直接用引擎自带的 exe)
            $exeName = if ($cfg -eq 'Development') { "$pn.exe" } else { "$pn-Win64-$cfg.exe" }
            $exe = Join-Path $arch "$($UE.StageDir)\$pn\Binaries\Win64\$exeName"
            if (-not (Test-Path $exe)) { Add-Result "打包 $pn $cfg" @("没有打出 $exeName，插件代码没有被链接进包"); continue }
            Add-Result "打包 $pn $cfg" @()

            $runArgs = @('-nullrhi', '-unattended', '-nosplash', '-nosound', '-log', '-ExecCmds="quit"')
            if ($cfg -eq 'Shipping') {
                Add-Result "运行 $pn $cfg (Shipping 无日志，只检查运行不崩溃)" (Test-Run $exe $runArgs $null $false)
            } else {
                Add-Result "运行 $pn $cfg" (Test-Run $exe $runArgs "$arch\$($UE.StageDir)\$pn\Saved\Logs\$pn.log")
            }
        }
    }
}

# ---------- 汇总
Write-Step '验证结果'
$results | Format-Table -AutoSize -Wrap | Out-Host
$failed = @($results | Where-Object Result -eq 'FAIL')
if ($failed) { throw "$($failed.Count) 项验证失败。测试工程和日志保留在 $work" }
if (-not $KeepWorkDir) {
    try { Remove-Item $work -Recurse -Force } catch { Write-Warning "临时目录没删干净(可能有进程占用): $work" }
}
Write-Host '全部验证通过' -ForegroundColor Green
