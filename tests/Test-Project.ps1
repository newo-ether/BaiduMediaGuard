[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$failures = New-Object System.Collections.Generic.List[string]
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

$scripts = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -File -Recurse)
foreach ($script in $scripts) {
    $bytes = [System.IO.File]::ReadAllBytes($script.FullName)
    $hasBom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF

    $offset = if ($hasBom) { 3 } else { 0 }
    try {
        $text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch {
        $failures.Add(('{0}: invalid UTF-8' -f $script.Name))
        continue
    }

    $hasNonAscii = $false
    foreach ($character in $text.ToCharArray()) {
        if ([int]$character -gt 127) {
            $hasNonAscii = $true
            break
        }
    }

    if ($hasNonAscii -and -not $hasBom) {
        $failures.Add(('{0}: non-ASCII PowerShell requires UTF-8 BOM for Windows PowerShell 5.1' -f $script.Name))
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    foreach ($parseError in $parseErrors) {
        $failures.Add(('{0}:{1}: {2}' -f $script.Name, $parseError.Extent.StartLineNumber, $parseError.Message))
    }
}

$projectFiles = @(
    Get-ChildItem -LiteralPath $repoRoot -File -Recurse |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.git[\\/]' -and
            $_.Name -ne 'SFTA.ps1' -and
            $_.FullName -ne $PSCommandPath
        }
)
$machinePatterns = @(
    ('C:' + '\\Users\\'),
    ('[A-Za-z]:' + '\\workspace\\')
)
foreach ($file in $projectFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    foreach ($pattern in $machinePatterns) {
        if ($content -match $pattern) {
            $relativePath = $file.FullName.Substring($repoRoot.Length + 1)
            $failures.Add(('{0}: machine-specific value matched {1}' -f $relativePath, $pattern))
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host ('PASS: {0} PowerShell scripts parsed; UTF-8 BOM and portability checks passed.' -f $scripts.Count) -ForegroundColor Green
& (Join-Path $PSScriptRoot 'Test-PlayerCleanup.ps1')
