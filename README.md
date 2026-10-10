# UE 插件二进制打包工具 (UEPP)

把 UE 插件用指定的引擎版本、指定的 MSVC 工具集编译成**无源码**分发包，可选自动验证（纯蓝图工程 + C++ 工程，在编辑器中运行和打包后运行）。

## 图形界面

双击 `UEPP.cmd`。也可以把任务文件（`.psd1`）拖到 `UEPP.cmd` 上直接加载。

| 项目 | 说明 |
|---|---|
| 插件 | 选择 `.uplugin` |
| 引擎 | 下拉列表包含 Launcher 安装的引擎、已注册的源码版引擎、自己添加的引擎。“浏览目录...”可选择任意引擎目录，并起名字保存，以后直接选 |
| MSVC | 越老的工具集，兼容的 VS 版本越多（产出的 `.obj` 需要同版本或更新的链接器） |
| 输出目录 | 可用占位符，下方实时显示最终输出位置，点击可在资源管理器中打开 |
| 输出名称 | 默认 `{Plugin}_UE{Engine}_MSVC{Toolset}`。“设为默认”保存当前输出目录和名称为默认值 |
| 加载/保存任务 | 把当前界面的设置存为 `Jobs\*.psd1`，下次一键加载 |
| 检查设置 | 只检查设置并显示输出位置，不编译 |
| 开始打包 | 在新的控制台窗口中运行，可同时开多个任务 |

### 占位符

| 占位符 | 含义 |
|---|---|
| `{Plugin}` | 插件名 |
| `{PluginVersion}` | uplugin 中的 VersionName |
| `{Engine}` | 引擎版本，如 `5.4` |
| `{EngineFull}` | 完整引擎版本，如 `5.4.4` |
| `{Toolset}` | MSVC 工具集版本 |
| `{Date}` | 日期，`yyyyMMdd` |

例：输出目录 `D:\Release\{Plugin}\{Date}`，输出名称 `{Plugin}-{PluginVersion}-UE{Engine}`。

## 命令行

```powershell
.\Build-UEPluginBinary.ps1 -ListEngines      # 本机可用的引擎及名字
.\Build-UEPluginBinary.ps1 -ListToolsets     # 本机 MSVC 工具集
.\Build-UEPluginBinary.ps1 -ShowSettings     # 当前默认设置

# 引擎可以用名字(-ListEngines 中列出的)或直接给目录
.\Build-UEPluginBinary.ps1 -Plugin D:\Proj\Plugins\Foo -Engine 5.4 -Toolset 14.38 -Zip -Verify
.\Build-UEPluginBinary.ps1 -Plugin D:\Proj\Plugins\Foo -Engine F:\UnrealEngine -OutputDir 'D:\Release\{Plugin}'

# 任务文件，命令行参数可覆盖其中的值
.\Build-UEPluginBinary.ps1 -Config .\Jobs\Example.psd1 -Engine 5.8 -OutputDir D:\Release
.\Build-UEPluginBinary.ps1 -Plugin ... -Engine ... -SaveConfig .\Jobs\Foo-UE5.4.psd1   # 保存任务
.\Build-UEPluginBinary.ps1 -Config ... -DryRun                                       # 只检查不编译

# 设置 (与图形界面共用 UEPP.Settings.json)
.\Build-UEPluginBinary.ps1 -AddEngine MyUE -EnginePath F:\UnrealEngine
.\Build-UEPluginBinary.ps1 -RemoveEngine MyUE
.\Build-UEPluginBinary.ps1 -SetDefaultOutputDir 'E:\Dist\{Plugin}' -SetDefaultOutputName '{Plugin}_UE{Engine}'

# 单独验证一个已有的分发包
.\Test-UEPluginBinary.ps1 -Plugin .\Output\Foo_UE5.4_MSVC14.38.33130\Foo -Engine 5.4
```

详细参数：`Get-Help .\Build-UEPluginBinary.ps1 -Detailed`

## 文件

| 文件 | 说明 |
|---|---|
| `UEPP.cmd` | 图形界面入口 |
| `UEPP.Gui.ps1` | 图形界面 |
| `Build-UEPluginBinary.ps1` | 编译 + 组装分发包 |
| `Test-UEPluginBinary.ps1` | 验证分发包 |
| `UEPP.Common.ps1` | 公共函数 |
| `UEPP.Settings.json` | 用户设置（自定义引擎、默认输出位置），首次修改设置时生成，不提交到仓库 |
| `Jobs\*.psd1` | 任务文件。仓库中只有 `Example.psd1`，其余为本机任务，不提交 |

## 注意

- 编译临时目录在 `%TEMP%\UEPP`，成功后自动删除；失败时保留，日志在其中的 `Logs` 目录。
- 分发包中的 `BuildInfo.json` 记录引擎、工具集和源码 git 提交。
- 拿到包的开发者需要：同一个引擎小版本；打包游戏时 VS 的 MSVC 版本 >= 打包所用的工具集。
- 兼容 PowerShell 7 和 Windows PowerShell 5.1。脚本文件需保持 UTF-8 带 BOM 编码，否则 5.1 下中文会乱码。
