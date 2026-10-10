# 任务配置示例。复制一份改成自己的插件/引擎，用法:
#   .\Build-UEPluginBinary.ps1 -Config .\Jobs\Example.psd1
# 键名与 Build-UEPluginBinary.ps1 的参数相同，命令行上的参数会覆盖这里的值。相对路径相对于本文件所在目录。
# 也可以在图形界面中设置好后点“保存任务...”生成。
@{
    Plugin        = 'D:\MyProject\Plugins\MyPlugin'   # .uplugin 文件或插件目录
    Engine        = '5.4'                             # 引擎名字(-ListEngines 查看)或引擎目录
    Toolset       = '14.38'                           # MSVC 工具集(-ListToolsets 查看)，越老兼容的 VS 越多
    OutputDir     = 'D:\Release\{Plugin}'             # 可用占位符 {Plugin} {PluginVersion} {Engine} {EngineFull} {Toolset} {Date}
    OutputName    = '{Plugin}_UE{Engine}_MSVC{Toolset}'
    EditorConfigs = @('Development', 'DebugGame')
    GameConfigs   = @('Development', 'DebugGame', 'Shipping')
    Platforms     = @('Win64')
    Zip           = $true
    Verify        = $true
}
