[CmdletBinding()]
param(
    [string]$PlayerPath
)

$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'BaiduMediaGuard.ps1'

try {
    if ([string]::IsNullOrWhiteSpace($PlayerPath)) {
        & $guard
    }
    else {
        & $guard -PlayerPath $PlayerPath
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
