[CmdletBinding()]
param(
    [string]$PlayerPath,

    [ValidateRange(1, 60)]
    [int]$IntervalMinutes = 2,

    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'BaiduMediaGuard.ps1'

function Normalize-ExecutablePath {
    param([string]$Path)

    $candidate = $Path.Trim()
    if ($candidate.StartsWith('& ')) {
        $candidate = $candidate.Substring(2).Trim()
    }
    $candidate = $candidate.Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($candidate))
    }
    catch {
        return $null
    }
}

Clear-Host
Write-Host '==========================================' -ForegroundColor DarkCyan
Write-Host '       Baidu Media Guard Installer' -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor DarkCyan
Write-Host
Write-Host '安装后会执行一次完整修复，并创建完全隐藏的后台计划任务。'
Write-Host '你只需要选择默认视频播放器的 .exe 文件。'
Write-Host

$selectedPath = $null
while ($null -eq $selectedPath) {
    $inputPath = $PlayerPath
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        $inputPath = Read-Host '请输入或拖入播放器 .exe 路径'
    }

    $candidate = Normalize-ExecutablePath -Path $inputPath
    if ($candidate -and
        [System.IO.Path]::GetExtension($candidate) -ieq '.exe' -and
        (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $selectedPath = $candidate
        break
    }

    Write-Host '路径无效：必须选择一个存在的 .exe 文件。' -ForegroundColor Yellow
    $PlayerPath = $null
}

$versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($selectedPath)
$playerName = $versionInfo.FileDescription
if ([string]::IsNullOrWhiteSpace($playerName)) {
    $playerName = [System.IO.Path]::GetFileNameWithoutExtension($selectedPath)
}

Write-Host
Write-Host ('播放器：{0}' -f $playerName) -ForegroundColor Green
Write-Host ('路径：    {0}' -f $selectedPath)
Write-Host ('检查间隔：每 {0} 分钟，并在登录时检查' -f $IntervalMinutes)

if (-not $Yes) {
    $confirmation = Read-Host '确认安装？[Y/n]'
    if ($confirmation -and $confirmation -notmatch '^(?i)y(es)?$') {
        Write-Host '已取消。'
        exit 0
    }
}

Write-Host
Write-Host '正在安装并恢复文件关联，首次运行可能需要约一分钟……' -ForegroundColor Cyan

try {
    & $guard -Install -PlayerPath $selectedPath -IntervalMinutes $IntervalMinutes
    Write-Host
    Write-Host '安装完成。之后的检查会完全在后台运行，不会弹出窗口。' -ForegroundColor Green
    Write-Host '如需更换播放器，重新运行本安装器并选择新的 .exe 即可。'
}
catch {
    Write-Host
    Write-Host ('安装失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
