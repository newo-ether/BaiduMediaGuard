[CmdletBinding()]
param(
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'BaiduMediaGuard.ps1'

if (-not $Yes) {
    $confirmation = Read-Host '确认卸载 Baidu Media Guard？[y/N]'
    if ($confirmation -notmatch '^(?i)y(es)?$') {
        Write-Host '已取消。'
        exit 0
    }
}

try {
    & $guard -Uninstall
    Write-Host '卸载完成。现有默认应用设置不会被改动。' -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
