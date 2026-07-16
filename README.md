# Baidu Media Guard

用于 Windows 10/11 的百度网盘媒体默认应用防劫持工具。

它会：

- 删除 `BaiduNetdiskImageViewerAssociations` 及图片查看器模块；
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

## 第三方组件

`SFTA.ps1` 来自 [DanysysTeam/PS-SFTA](https://github.com/DanysysTeam/PS-SFTA)，使用 MIT License。详情见 `THIRD_PARTY_NOTICES.txt`。

## 开发检查

项目包含 Windows PowerShell 5.1 语法检查、机器相关硬编码检查，以及 UTF-8 BOM 检查：含非 ASCII 文案的 PowerShell 脚本必须带 BOM，纯 ASCII 脚本不强制。

```powershell
.\tests\Test-Project.ps1
```

同一检查会通过 GitHub Actions 在 Windows 环境自动执行。
