# UEPP 图形界面: 选择插件 / 引擎 / MSVC 工具集 / 输出位置，在新的控制台窗口中运行 Build-UEPluginBinary.ps1
# 启动: 双击 UEPP.cmd
. "$PSScriptRoot\UEPP.Common.ps1"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[Windows.Forms.Application]::EnableVisualStyles()

function Show-Msg([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    [Windows.Forms.MessageBox]::Show($Text, 'UE 插件打包工具', $Buttons, $Icon)
}

try {
$settings      = Get-UEPPSettings
$toolsets      = @(Get-MsvcToolsets | Sort-Object { [version]$_.Version })
$script:extraEngines = @()   # 从任务文件加载、但未注册的引擎目录
$script:engines      = @()
$script:previewRoot  = $null
$sample = @{ Plugin = 'P'; PluginVersion = '1'; Engine = '5.4'; EngineFull = '5.4.0'; Toolset = '14.38'; Date = '20260101' }

# ---------- 布局
$font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form = New-Object Windows.Forms.Form -Property @{
    Text = 'UE 插件二进制打包工具'; StartPosition = 'CenterScreen'; Font = $font
    AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; FormBorderStyle = 'FixedSingle'; MaximizeBox = $false
    Padding = (New-Object Windows.Forms.Padding(8))
}
$grid = New-Object Windows.Forms.TableLayoutPanel -Property @{ AutoSize = $true; ColumnCount = 4 }
1..4 | ForEach-Object { [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize'))) }
$form.Controls.Add($grid)

function New-Label([string]$Text) {
    New-Object Windows.Forms.Label -Property @{ Text = $Text; AutoSize = $true; Anchor = 'Left'; Margin = (New-Object Windows.Forms.Padding(3, 7, 3, 3)) }
}
function New-Button([string]$Text, [scriptblock]$OnClick) {
    $b = New-Object Windows.Forms.Button -Property @{ Text = $Text; AutoSize = $true; Anchor = 'Left' }
    $b.Add_Click($OnClick)
    $b
}
function Add-Row([string]$Label, $Main, $B1, $B2, [int]$Span = 1) {
    $r = $grid.RowCount; $grid.RowCount++
    if ($Label) { $grid.Controls.Add((New-Label $Label), 0, $r) }
    $grid.Controls.Add($Main, 1, $r)
    if ($Span -gt 1) { $grid.SetColumnSpan($Main, $Span) }
    if ($B1) { $grid.Controls.Add($B1, 2, $r) }
    if ($B2) { $grid.Controls.Add($B2, 3, $r) }
}
function New-TextBox { New-Object Windows.Forms.TextBox -Property @{ Width = 560; Anchor = 'Left' } }
function New-Combo { New-Object Windows.Forms.ComboBox -Property @{ Width = 560; Anchor = 'Left'; DropDownStyle = 'DropDownList' } }
function New-Flow { New-Object Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; WrapContents = $false; Margin = (New-Object Windows.Forms.Padding(0)) } }

# 插件
$txtPlugin = New-TextBox
$btnPlugin = New-Button '浏览...' {
    $dlg = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'UE 插件 (*.uplugin)|*.uplugin'; Title = '选择插件的 .uplugin 文件' }
    if ($txtPlugin.Text -and (Test-Path $txtPlugin.Text)) { $dlg.InitialDirectory = $(if ((Get-Item $txtPlugin.Text).PSIsContainer) { $txtPlugin.Text } else { Split-Path $txtPlugin.Text }) }
    if ($dlg.ShowDialog() -eq 'OK') { $txtPlugin.Text = $dlg.FileName }
}
Add-Row '插件' $txtPlugin $btnPlugin $null

# 引擎
$cboEngine = New-Combo
$btnEngineBrowse = New-Button '浏览目录...' {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = '选择 UE 引擎根目录 (包含 Engine 文件夹的目录)' }
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $info = Get-UEEngineInfo $dlg.SelectedPath
    if (-not $info.Usable) { Show-Msg "$($dlg.SelectedPath)`n不可用: $($info.Problem)" 'Warning'; return }
    $default = Split-Path $info.Root -Leaf
    $alias = [Microsoft.VisualBasic.Interaction]::InputBox("UE $($info.Version)`n$($info.Root)`n`n给这个引擎起个名字，保存到设置里，以后可以直接选择或在命令行用 -Engine <名字>。`n留空则只在本次使用。", '添加引擎', $default)
    if ($alias) {
        if ($alias -match '[\\/:]') { Show-Msg '名字不能包含 \ / :' 'Warning'; return }
        $settings.Engines[$alias] = $info.Root; Save-UEPPSettings $settings
        Refresh-Engines $alias
    } else {
        $info.Name = $info.Root; $info.Source = '本次'
        $script:extraEngines += $info
        Refresh-Engines $info.Root
    }
}
$btnEngineRemove = New-Button '移除' {
    $e = Get-SelectedEngine
    if (-not $e) { return }
    if ($e.Source -ne '自定义') { Show-Msg "'$($e.Name)' 来自$($e.Source)，不是自定义添加的，不能移除。" 'Information'; return }
    if ((Show-Msg "从设置中移除引擎 '$($e.Name)'?`n(只删除名字，不会删除引擎文件)" 'Question' 'YesNo') -ne 'Yes') { return }
    $settings.Engines.Remove($e.Name); Save-UEPPSettings $settings
    Refresh-Engines
}
$engineButtons = New-Flow; $engineButtons.Controls.AddRange(@($btnEngineBrowse, $btnEngineRemove))
Add-Row '引擎' $cboEngine $engineButtons $null

function Get-SelectedEngine { if ($cboEngine.SelectedIndex -ge 0) { $script:engines[$cboEngine.SelectedIndex] } }
function Refresh-Engines([string]$Select) {
    if (-not $Select) { $cur = Get-SelectedEngine; if ($cur) { $Select = $cur.Name } }
    # 自定义的排最前，其余按版本从新到旧
    $script:engines = @(@(Get-UEEngines | Where-Object Usable) + $script:extraEngines | Sort-Object { $_.Source -eq '自定义' }, { [version]($_.Version -replace '\?', '0') } -Descending)
    $cboEngine.Items.Clear()
    foreach ($e in $script:engines) {
        $names = (@($e.Name) + @($e.Aliases)) -join ' / '
        $label = if ($e.Name -eq $e.Root) { "UE $($e.Version)  -  $($e.Root)  [$($e.Source)]" } else { "$names  -  UE $($e.Version)  -  $($e.Root)  [$($e.Source)]" }
        [void]$cboEngine.Items.Add($label)
    }
    $idx = [array]::FindIndex([object[]]$script:engines, [Predicate[object]] { param($x) $x.Name -eq $Select -or $x.Root -eq $Select -or $Select -in @($x.Aliases) })
    $cboEngine.SelectedIndex = $(if ($idx -ge 0) { $idx } elseif ($script:engines) { 0 } else { -1 })
}

# MSVC 工具集
$cboToolset = New-Combo
foreach ($t in $toolsets) { [void]$cboToolset.Items.Add("MSVC $($t.Version)  -  $($t.VS)") }
if ($toolsets) { $cboToolset.SelectedIndex = 0 }
$lblToolHint = New-Label '越老兼容的 VS 越多'
Add-Row 'MSVC' $cboToolset $lblToolHint $null

# 输出位置
$txtOutDir  = New-TextBox
$btnOutDir  = New-Button '浏览...' {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = '选择输出目录 (也可以在输入框中手动加入 {Plugin} 等占位符)' }
    $existing = ($txtOutDir.Text -split '\{')[0]
    if ($existing -and (Test-Path $existing)) { $dlg.SelectedPath = $existing }
    if ($dlg.ShowDialog() -eq 'OK') { $txtOutDir.Text = $dlg.SelectedPath }
}
$btnOutDefault = New-Button '设为默认' {
    try {
        $null = Expand-UEPPTemplate $txtOutDir.Text $sample; $null = Expand-UEPPTemplate $txtOutName.Text $sample
        $settings.DefaultOutputDir = $txtOutDir.Text; $settings.OutputName = $txtOutName.Text; Save-UEPPSettings $settings
        Show-Msg "已保存为默认输出位置:`n$($txtOutDir.Text)\$($txtOutName.Text)"
    } catch { Show-Msg $_.Exception.Message 'Warning' }
}
Add-Row '输出目录' $txtOutDir $btnOutDir $btnOutDefault
$txtOutName = New-TextBox
Add-Row '输出名称' $txtOutName (New-Label "占位符: {$($script:TemplateTokens -join '} {')}") $null 1
$lblPreview = New-Object Windows.Forms.LinkLabel -Property @{ AutoSize = $true; MaximumSize = (New-Object Drawing.Size(900, 0)); Margin = (New-Object Windows.Forms.Padding(3, 3, 3, 8)) }
$lblPreview.Add_LinkClicked({
    $p = $script:previewRoot
    while ($p -and -not (Test-Path $p)) { $p = Split-Path $p }
    if ($p) { Start-Process explorer.exe $p }
})
Add-Row '' $lblPreview $null $null 3

# 配置
function New-CheckGroup([string[]]$Items, [string[]]$Checked) {
    $f = New-Flow
    foreach ($i in $Items) { $f.Controls.Add((New-Object Windows.Forms.CheckBox -Property @{ Text = $i; AutoSize = $true; Checked = ($i -in $Checked) })) }
    $f
}
function Get-Checked($Group) { @($Group.Controls | Where-Object Checked | ForEach-Object Text) }
function Set-Checked($Group, [string[]]$Items) { foreach ($c in $Group.Controls) { $c.Checked = $c.Text -in $Items } }
$grpEditor = New-CheckGroup @('Development', 'DebugGame') @('Development', 'DebugGame')
Add-Row '编辑器配置' $grpEditor $null $null 3
$grpGame = New-CheckGroup @('Development', 'DebugGame', 'Shipping', 'Test') @('Development', 'DebugGame', 'Shipping')
Add-Row '游戏配置' $grpGame $null $null 3

# 选项
$chkZip     = New-Object Windows.Forms.CheckBox -Property @{ Text = '生成 zip'; AutoSize = $true; Checked = $true }
$chkVerify  = New-Object Windows.Forms.CheckBox -Property @{ Text = '编译后验证 (编辑器+打包，约 10 分钟)'; AutoSize = $true; Checked = $true }
$chkForce   = New-Object Windows.Forms.CheckBox -Property @{ Text = '覆盖已有输出'; AutoSize = $true }
$chkPrivate = New-Object Windows.Forms.CheckBox -Property @{ Text = '保留 Private 头文件'; AutoSize = $true }
$chkPCH     = New-Object Windows.Forms.CheckBox -Property @{ Text = '使用 PCH/Unity 编译'; AutoSize = $true }
$opts = New-Flow; $opts.Controls.AddRange(@($chkZip, $chkVerify, $chkForce, $chkPrivate, $chkPCH))
Add-Row '选项' $opts $null $null 3

# ---------- 收集界面参数 (用于运行和保存任务)
function Get-FormJob {
    $e = Get-SelectedEngine
    $t = if ($cboToolset.SelectedIndex -ge 0) { $toolsets[$cboToolset.SelectedIndex] }
    $job = [ordered]@{
        Plugin        = $txtPlugin.Text.Trim()
        Engine        = $(if ($e) { if ($e.Source -eq '本次') { $e.Root } else { $e.Name } })
        Toolset       = $(if ($t) { $t.Version })
        OutputDir     = $txtOutDir.Text.Trim()
        OutputName    = $txtOutName.Text.Trim()
        EditorConfigs = Get-Checked $grpEditor
        GameConfigs   = Get-Checked $grpGame
        Platforms     = @('Win64')
    }
    if ($chkZip.Checked) { $job.Zip = $true }
    if ($chkVerify.Checked) { $job.Verify = $true }
    if ($chkPrivate.Checked) { $job.KeepPrivateHeaders = $true }
    if ($chkPCH.Checked) { $job.UsePCH = $true }
    $job
}

# 输出位置预览
function Update-Preview {
    $script:previewRoot = $null
    $lblPreview.LinkArea = New-Object Windows.Forms.LinkArea(0, 0)
    try {
        $e = Get-SelectedEngine
        $t = if ($cboToolset.SelectedIndex -ge 0) { $toolsets[$cboToolset.SelectedIndex] }
        if (-not $e -or -not $t) { $lblPreview.Text = '请选择引擎和 MSVC 工具集'; return }
        if (-not $txtPlugin.Text -or -not (Test-Path $txtPlugin.Text)) {
            $lblPreview.Text = '→ ' + (Get-UEPPOutputRoot $txtOutDir.Text $txtOutName.Text ([pscustomobject]@{ VersionName = '[版本]' }) '[插件名]' $e $t)
            return
        }
        $f = Resolve-UPluginFile $txtPlugin.Text
        $up = Get-UPlugin $f
        $n = [IO.Path]::GetFileNameWithoutExtension($f)
        $script:previewRoot = Get-UEPPOutputRoot $txtOutDir.Text $txtOutName.Text $up $n $e $t
        $exists = if (Test-Path $script:previewRoot) { '   (已存在，需勾选“覆盖已有输出”)' } else { '' }
        $lblPreview.Text = "→ $($script:previewRoot)\$n$exists"
        $lblPreview.LinkArea = New-Object Windows.Forms.LinkArea(2, $script:previewRoot.Length)
    } catch {
        $lblPreview.Text = "⚠ $($_.Exception.Message)"
    }
}
foreach ($c in $txtPlugin, $txtOutDir, $txtOutName) { $c.Add_TextChanged({ Update-Preview }) }
foreach ($c in $cboEngine, $cboToolset) { $c.Add_SelectedIndexChanged({ Update-Preview }) }
$chkForce.Add_CheckedChanged({ Update-Preview })

# ---------- 任务文件 加载/保存
$jobsDir = Join-Path $PSScriptRoot 'Jobs'
function Load-Job([string]$Path) {
    $j = Import-PowerShellDataFile $Path
    $base = Split-Path $Path
    $abs = { param($v) if ($v -and -not [IO.Path]::IsPathRooted($v)) { Join-Path $base $v } else { $v } }
    if ($j.Plugin) { $txtPlugin.Text = & $abs $j.Plugin }
    if ($j.Engine) {
        $eng = if ($j.Engine -match '^\.\.?[\\/]') { & $abs $j.Engine } else { $j.Engine }
        if (-not ($script:engines | Where-Object { $_.Name -eq $eng -or $_.Root -eq $eng -or $eng -in @($_.Aliases) })) {
            if (Test-Path $eng) {
                $info = Get-UEEngineInfo $eng; $info.Name = $info.Root; $info.Source = '本次'; $script:extraEngines += $info
            } else { Show-Msg "任务中的引擎 '$eng' 在本机找不到，请重新选择。" 'Warning' }
        }
        Refresh-Engines $eng
    }
    if ($j.Toolset) {
        $i = [array]::FindIndex([object[]]$toolsets, [Predicate[object]] { param($t) $t.Version -eq $j.Toolset -or $t.Version.StartsWith("$($j.Toolset).") })
        if ($i -ge 0) { $cboToolset.SelectedIndex = $i } else { Show-Msg "任务中的 MSVC $($j.Toolset) 在本机找不到，请重新选择。" 'Warning' }
    }
    $txtOutDir.Text  = $(if ($j.OutputDir) { & $abs $j.OutputDir } else { $settings.DefaultOutputDir })
    $txtOutName.Text = $(if ($j.OutputName) { $j.OutputName } else { $settings.OutputName })
    if ($j.EditorConfigs) { Set-Checked $grpEditor $j.EditorConfigs }
    if ($j.GameConfigs) { Set-Checked $grpGame $j.GameConfigs }
    $chkZip.Checked = [bool]$j.Zip; $chkVerify.Checked = [bool]$j.Verify
    $chkPrivate.Checked = [bool]$j.KeepPrivateHeaders; $chkPCH.Checked = [bool]$j.UsePCH
    $form.Text = "UE 插件二进制打包工具 - $(Split-Path $Path -Leaf)"
}
$btnLoad = New-Button '加载任务...' {
    $dlg = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = '任务配置 (*.psd1)|*.psd1'; InitialDirectory = $jobsDir }
    if ($dlg.ShowDialog() -eq 'OK') { try { Load-Job $dlg.FileName } catch { Show-Msg "加载失败: $($_.Exception.Message)" 'Error' } }
}
$btnSave = New-Button '保存任务...' {
    $job = Get-FormJob
    if (-not $job.Plugin -or -not $job.Engine) { Show-Msg '请先选择插件和引擎' 'Warning'; return }
    New-Item -ItemType Directory -Force $jobsDir | Out-Null
    $n = try { [IO.Path]::GetFileNameWithoutExtension((Resolve-UPluginFile $job.Plugin)) } catch { 'Job' }
    $e = Get-SelectedEngine
    $dlg = New-Object Windows.Forms.SaveFileDialog -Property @{ Filter = '任务配置 (*.psd1)|*.psd1'; InitialDirectory = $jobsDir; FileName = "$n-UE$($e.Short).psd1" }
    if ($dlg.ShowDialog() -ne 'OK') { return }
    Write-Utf8Bom $dlg.FileName (ConvertTo-Psd1 $job "任务配置。用法: .\Build-UEPluginBinary.ps1 -Config <本文件>`n命令行参数会覆盖这里的值。相对路径相对于本文件所在目录。")
    $form.Text = "UE 插件二进制打包工具 - $(Split-Path $dlg.FileName -Leaf)"
}

# ---------- 运行 (新开控制台窗口，界面不会卡住；可同时开多个任务)
function Invoke-PackJob([switch]$DryRun) {
    $job = Get-FormJob
    if (-not $job.Plugin -or -not (Test-Path $job.Plugin)) { Show-Msg '请选择插件 (.uplugin)' 'Warning'; return }
    if (-not $job.Engine) { Show-Msg '请选择引擎' 'Warning'; return }
    if (-not $job.Toolset) { Show-Msg '本机没有找到 MSVC 工具集' 'Warning'; return }
    if (-not $job.EditorConfigs -and -not $job.GameConfigs) { Show-Msg '至少选择一个配置' 'Warning'; return }
    try { $null = Expand-UEPPTemplate $job.OutputDir $sample; $null = Expand-UEPPTemplate $job.OutputName $sample } catch { Show-Msg $_.Exception.Message 'Warning'; return }
    if ($chkForce.Checked) { $job.Force = $true }
    if ($DryRun) { $job.DryRun = $true }

    # 通过临时任务文件传参，避免命令行引号问题
    $tmp = Join-Path $env:TEMP "UEPP\gui-job-$([guid]::NewGuid().ToString('N').Substring(0, 8)).psd1"
    Write-Utf8Bom $tmp (ConvertTo-Psd1 $job)
    $script = Join-Path $PSScriptRoot 'Build-UEPluginBinary.ps1'
    $cmd = "& { try { & '$script' -Config '$tmp'; `$ok = `$? } catch { Write-Host `$_.Exception.Message -ForegroundColor Red; `$ok = `$false }; Remove-Item '$tmp' -ErrorAction SilentlyContinue; " +
           "if (`$ok) { Write-Host ''; Write-Host '按回车关闭窗口' } else { Write-Host ''; Write-Host '失败。按回车关闭窗口' -ForegroundColor Red }; [void](Read-Host) }"
    $shell = (Get-Process -Id $PID).Path
    Start-Process $shell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
}
$btnCheck = New-Button '检查设置' { Invoke-PackJob -DryRun }
$btnRun   = New-Button '开始打包' { Invoke-PackJob }
$btnRun.Font = New-Object Drawing.Font($font, [Drawing.FontStyle]::Bold)
$actions = New-Flow; $actions.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
$actions.Controls.AddRange(@($btnLoad, $btnSave, $btnCheck, $btnRun))
Add-Row '' $actions $null $null 3

# ---------- 初始化
$txtOutDir.Text  = $settings.DefaultOutputDir
$txtOutName.Text = $settings.OutputName
Refresh-Engines
if ($args -and $args[0] -and (Test-Path $args[0])) { Load-Job (Resolve-Path $args[0]).Path }
Update-Preview
[void]$form.ShowDialog()
} catch {
    [Windows.Forms.MessageBox]::Show("界面启动失败:`n$($_.Exception.Message)`n$($_.ScriptStackTrace)", 'UE 插件打包工具', 'OK', 'Error') | Out-Null
}
