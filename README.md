# Baidu Media Guard

用于 Windows 10/11 的百度网盘媒体默认应用防劫持工具。

它会：

- 删除 `BaiduNetdiskImageViewerAssociations` 及图片查看器模块；
- 清除新版“智能播放器”的启动程序、专用资源及更新包；
- 将百度声明的全部视频格式恢复到用户自行选择的播放器；
- 清理百度在 `RegisteredApplications` 和 `OpenWithProgids` 中的媒体入口；
- 登录时以及每隔一段时间自动检查；
- 使用 `wscript.exe` 启动隐藏的 PowerShell，后台检查不会闪出控制台窗口。

## 安装

双击 `install.cmd`，或在 PowerShell 中运行：

```powershell
.\install.ps1
```

安装器会提示输入或拖入播放器的 `.exe` 路径。确认后，它会保存播放器配置、执行一次完整修复，并创建计划任务 `Baidu Media Guard`。

也可以非交互安装：

```powershell
.\install.ps1 -PlayerPath "C:\Path\To\Player.exe" -Yes
```

重新运行安装器并选择另一个 `.exe`，即可更换目标播放器。

## 手动修复

```powershell
.\repair.ps1
```

默认使用安装时保存的播放器。临时指定另一个播放器：

```powershell
.\repair.ps1 -PlayerPath "D:\Apps\Player\player.exe"
```

## 卸载

双击 `uninstall.cmd`，或运行：

```powershell
.\uninstall.ps1
```

卸载会删除计划任务以及 `%LOCALAPPDATA%\BaiduMediaGuard` 中的安装文件，不会改变当前已经恢复好的默认应用。

## 后台机制

计划任务调用 `%SystemRoot%\System32\wscript.exe`，再由 `RunGuardHidden.vbs` 以窗口样式 `0` 启动 PowerShell。无论登录触发还是周期触发，都不会创建可见控制台。

配置和日志位于：

```text
%LOCALAPPDATA%\BaiduMediaGuard\config.json
%LOCALAPPDATA%\BaiduMediaGuard\guard.log
```

## 清理范围

支持旧版 `BaiduNetdiskUniteAssociations`、新版 `BaiduNetdiskPlayerAssociations`，
以及 `Applications\BaiduNetdiskPlayer.open` 和对应播放器可执行文件的打开方式。
清理前收集格式声明、当前默认项及打开方式列表，再将视频格式恢复到配置的播放器。
仅出现在 OpenWith/最近打开历史中的非视频格式只清理百度入口，不改变默认程序。
同时移除这些组件在当前用户下的默认应用注册、ProgID、OpenWith 列表和关联提示。
图片继续使用已保存的基线恢复；未被目标组件接管的图片、音频和 URL 默认项保持原状。

安装位置从百度网盘注册信息发现。图片模块覆盖安装目录与 AppData 中的
`module\ImageViewer`。新版播放器仅删除 `module\BrowserEngine` 下的
`BaiduNetdiskPlayerLaunch.exe`、`resources\video_player.asar`、
`resources\BaiduNetdiskPlayer.ico`、`module\asar\video_player.asar.new` 和
`module\asar\video_player.asar.sig`。保留网盘主程序、共用 BrowserEngine、
`localplayer.dll`、`vastplayer.dll` 和用户文件；不递归删除共用目录或播放器未知数据目录。

删除前校验绝对路径边界并拒绝目录联接/符号链接。仅允许停止安装路径匹配的专用组件进程；
共用 `BaiduNetdiskUnite.exe` 还必须明确以 `--mode=video_player` 启动。
默认项修复或模块清理失败时保留组件注册供下次重试；文件占用、权限不足或注册清理失败会记录错误并返回失败。
不会自动提权或修改权限。百度更新重新释放组件后，后续定时检查会再次清理。

## 第三方组件

`SFTA.ps1` 来自 [DanysysTeam/PS-SFTA](https://github.com/DanysysTeam/PS-SFTA)，使用 MIT License。详情见 `THIRD_PARTY_NOTICES.txt`。

## 开发检查

项目包含 Windows PowerShell 5.1 语法检查、机器相关硬编码检查，以及 UTF-8 BOM 检查：含非 ASCII 文案的 PowerShell 脚本必须带 BOM，纯 ASCII 脚本不强制。
行为测试使用隔离的注册表与临时文件，覆盖关联恢复、组件删除、进程筛选、文件锁、目录联接和重复运行；不会调用真实的默认应用设置或停止真实进程。

```powershell
.\tests\Test-Project.ps1
```

同一检查会通过 GitHub Actions 在 Windows 环境自动执行。
