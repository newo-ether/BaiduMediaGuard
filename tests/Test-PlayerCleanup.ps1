[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testId = [guid]::NewGuid().ToString('N')
$testRoot = Join-Path $env:TEMP ('BaiduMediaGuard.Tests.' + $testId)
$registryBase = 'Software\BaiduMediaGuard.Tests.' + $testId
$registryRoot = 'Registry::HKEY_CURRENT_USER\' + $registryBase
$originalAppData = $env:APPDATA
$checks = 0
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'BaiduMediaGuard.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Guard source did not parse.' }

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
    $script:checks++
}
function Set-TestValue {
    param([string]$Path, [string]$Name, $Value)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryBase + '\' + $Path)
    try { $key.SetValue($Name, $Value) } finally { $key.Dispose() }
}
function New-TestFile {
    param([string]$Path)
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, 'fixture')
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action } catch { $caught = $_.Exception.Message }
    Assert-Test ($null -ne $caught -and $caught -match $Pattern) ('Expected failure: ' + $Pattern + '; got ' + $caught)
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $env:APPDATA = Join-Path $testRoot 'AppData'
    New-Item -ItemType Directory -Path $env:APPDATA | Out-Null
    # Import only constant assignments and function definitions, never the live
    # entry point or SFTA. Provider paths are redirected to one disposable key.
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
            $statement.Left.Extent.Text -match '^\$(Baidu|Known)') {
            . ([scriptblock]::Create($statement.Extent.Text))
        }
        elseif ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
            $text = $statement.Extent.Text.Replace('HKCU:\', $registryRoot + '\').Replace('HKLM:\', $registryRoot + '\Machine\')
            . ([scriptblock]::Create($text))
        }
    }
    # No test can invoke SFTA, touch real player registration, or stop a process.
    $fixturePlayer = [pscustomobject]@{ ProgId = 'Applications\FixturePlayer.exe'; PlayerName = 'Fixture'; PlayerPath = (Join-Path $testRoot 'FixturePlayer.exe') }
    $Quiet = $true
    $logs = New-Object 'System.Collections.Generic.List[string]'
    $stopped = New-Object 'System.Collections.Generic.List[int]'
    $processes = @()
    $failExtension = ''
    $notifications = 0
    $BaselinePath = Join-Path $testRoot 'baseline.json'
    function Write-GuardLog { param($Message) $logs.Add($Message) }
    function Write-Status { param($Message) }
    function Import-Sfta {}
    function Get-PlayerConfiguration { param($RequestedPath) return $fixturePlayer }
    function Ensure-PlayerRegistration { param($Configuration) }
    function Send-AssociationChange { $script:notifications++ }
    function Get-CimInstance { param($ClassName, $Filter) return $processes }
    function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $stopped.Add($Id) }
    function Set-FTA {
        param($ProgId, $Extension)
        if ($Extension -eq $failExtension) { throw 'Injected association failure' }
        Set-TestValue ('Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $Extension + '\UserChoice') 'ProgId' $ProgId
    }
    function Remove-FTA {
        param($ProgramPath, $Extension)
        Remove-Item -LiteralPath ($registryRoot + '\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $Extension + '\UserChoice') -Recurse -Force
    }

    $install = Join-Path $testRoot 'Netdisk'
    New-TestFile (Join-Path $install 'BaiduNetdisk.exe')
    Set-TestValue 'Software\Baidu\BaiduYunGuanjia' 'installDir' $install
    Assert-Test (@(Get-BaiduInstallRoots) -contains $install) 'Discover installation from installDir'
    $engine = Join-Path $install 'module\BrowserEngine'
    $componentFiles = @('BaiduNetdiskPlayerLaunch.exe', 'resources\video_player.asar', 'resources\BaiduNetdiskPlayer.ico',
        'module\asar\video_player.asar.new', 'module\asar\video_player.asar.sig')
    foreach ($file in $componentFiles) { New-TestFile (Join-Path $engine $file) }
    foreach ($file in @('BaiduNetdiskUnite.exe', 'resources\app.asar', 'localplayer.dll', 'vastplayer.dll')) {
        New-TestFile (Join-Path $engine $file)
    }
    New-TestFile (Join-Path $install 'module\ImageViewer\BaiduNetdiskImageViewer.exe')
    $appDataImage = Join-Path $env:APPDATA 'baidu\BaiduNetdisk\module\ImageViewer'
    New-TestFile (Join-Path $appDataImage 'BaiduNetdiskImageViewer.exe')
    $newProgId = 'BaiduNetdiskPlayerAssociations'
    $fileExts = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
    $classes = 'Software\Classes'
    $capability = 'Software\Baidu\BaiduNetdiskPlayer\Capabilities\FileAssociations'
    Set-TestValue 'Software\RegisteredApplications' 'BaiduNetdiskPlayer' 'Software\Baidu\BaiduNetdiskPlayer\Capabilities'
    Set-TestValue 'Software\RegisteredApplications' 'OtherPlayer' 'Software\OtherPlayer\Capabilities'
    Set-TestValue $capability '.extra' $newProgId
    Set-TestValue ($classes + '\Applications\BaiduNetdisk.open\shell\open\command') '' 'main-client'
    foreach ($progId in $BaiduVideoProgIds) {
        Set-TestValue ($classes + '\' + $progId + '\shell\open\command') '' ('"' + $engine + '\BaiduNetdiskPlayerLaunch.exe" --mode=video_player')
    }
    $index = 0
    foreach ($progId in $BaiduVideoProgIds) {
        Set-TestValue ($fileExts + '\.identity' + $index + '\UserChoice') 'ProgId' $progId
        $index++
    }
    Set-TestValue ($fileExts + '\.mp3\UserChoice') 'ProgId' 'Audio.Keep'
    Set-TestValue ($fileExts + '\.jpg\UserChoice') 'ProgId' 'Photos.Keep'
    Set-TestValue ($fileExts + '\.unrelated\UserChoice') 'ProgId' 'BaiduOtherAssociations'
    Set-TestValue 'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' 'ProgId' 'Browser.Keep'
    Set-TestValue ($fileExts + '\.png\UserChoice') 'ProgId' $BaiduImageProgId
    Set-TestValue ($fileExts + '\.webp\UserChoice') 'ProgId' $BaiduImageProgId
    '{"ImageAssociations":{".png":"Photos.Baseline"}}' | Set-Content -LiteralPath $BaselinePath
    Set-TestValue ($classes + '\.fallback') '' $newProgId
    Set-TestValue ($classes + '\.fallback') 'PerceivedType' 'video'
    Set-TestValue ($classes + '\.openonly\OpenWithProgids') $newProgId ''
    Set-TestValue ($classes + '\.openonly\OpenWithProgids') 'Other.Keep' ''
    Set-TestValue ($classes + '\.openonly\OpenWithProgids') 'Applications\BaiduNetdiskPlayer.open' ([byte[]]@())
    Set-TestValue ($fileExts + '\.openonly\UserChoice') 'ProgId' 'Design.Keep'
    Set-TestValue ($fileExts + '\.blend\UserChoice') 'ProgId' 'Blender.Keep'
    Set-TestValue ($fileExts + '\.blend\OpenWithList') 'a' 'BaiduNetdiskUnite.exe'
    Set-TestValue ($fileExts + '\.blend\OpenWithList') 'b' 'blender.exe'
    Set-TestValue ($fileExts + '\.blend\OpenWithList') 'MRUList' 'ba'
    Set-TestValue ($fileExts + '\.listonly\OpenWithList') 'a' 'BaiduNetdiskPlayer.open'
    Set-TestValue ($fileExts + '\.listonly\OpenWithList') 'b' 'Other.exe'
    Set-TestValue ($fileExts + '\.listonly\OpenWithList') 'MRUList' 'ba'
    Set-TestValue ($classes + '\.subkeyonly\OpenWithList\BaiduNetdiskPlayerLaunch.exe') '' ''
    $toast = 'Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts'
    Set-TestValue $toast ($newProgId + '_.toastonly') 0
    Set-TestValue $toast 'Other_.toastonly' 0
    Assert-Test (@(Get-BaiduUserChoices).Count -eq ($BaiduVideoProgIds.Count + 2)) 'Recognize every video identity plus image hijacks'
    $extensions = @(Get-BaiduVideoExtensions)
    foreach ($extension in @('.extra', '.fallback', '.openonly', '.listonly', '.subkeyonly', '.toastonly', '.identity3')) {
        Assert-Test ($extensions -contains $extension) ('Discover format ' + $extension)
    }
    $processes = @(
        [pscustomobject]@{ ProcessId = 1; ExecutablePath = (Join-Path $engine 'BaiduNetdiskUnite.exe'); CommandLine = '"engine.exe" --mode=video_player --video-path="test.mp4"' },
        [pscustomobject]@{ ProcessId = 2; ExecutablePath = (Join-Path $engine 'BaiduNetdiskUnite.exe'); CommandLine = '"engine.exe" --mode=netdisk' },
        [pscustomobject]@{ ProcessId = 3; ExecutablePath = (Join-Path $testRoot 'Other\BaiduNetdiskPlayerLaunch.exe'); CommandLine = '--mode=video_player' },
        [pscustomobject]@{ ProcessId = 4; ExecutablePath = (Join-Path $engine 'BaiduNetdiskUnite.exe'); CommandLine = '"engine.exe" --mode=video_player_other' },
        [pscustomobject]@{ ProcessId = 5; ExecutablePath = (Join-Path $engine 'BaiduNetdiskPlayerLaunch.exe'); CommandLine = '' },
        [pscustomobject]@{ ProcessId = 6; ExecutablePath = (Join-Path $engine 'BaiduNetdiskUnite.exe'); CommandLine = '"engine.exe" --file="a --mode=video_player b"' },
        [pscustomobject]@{ ProcessId = 7; ExecutablePath = (Join-Path $engine 'BaiduNetdiskUnite.exe'); CommandLine = '"engine.exe" --user-data-dir="a b" --mode=video_player' },
        [pscustomobject]@{ ProcessId = 8; ExecutablePath = (Join-Path $engine 'BaiduNetdiskUnite.exe'); CommandLine = '"engine.exe" --mode=video_player --mode=netdisk' },
        [pscustomobject]@{ ProcessId = 9; ExecutablePath = (Join-Path $appDataImage 'BaiduNetdiskImageViewer.exe'); CommandLine = '' }
    )
    Invoke-Repair -RepairImage $true -RepairVideo $true
    foreach ($extension in @($extensions | Sort-Object -Unique | Where-Object { $_ -notin @('.openonly', '.listonly', '.subkeyonly', '.toastonly', '.blend') })) {
        Assert-Test ((Get-CurrentProgId $extension) -eq $fixturePlayer.ProgId) ('Restored ' + $extension)
    }
    foreach ($extension in @('.listonly', '.subkeyonly', '.toastonly')) {
        Assert-Test (-not (Get-CurrentProgId $extension)) ('History alone does not establish a default: ' + $extension)
    }
    Assert-Test ((Get-CurrentProgId '.blend') -eq 'Blender.Keep') 'Preserve Blender despite old Netdisk OpenWith history'
    Assert-Test ((Get-CurrentProgId '.openonly') -eq 'Design.Keep') 'Preserve nonmedia default despite new player OpenWith entry'
    Assert-Test ((Get-CurrentProgId '.mp3') -eq 'Audio.Keep') 'Preserve audio default'
    Assert-Test ((Get-CurrentProgId '.unrelated') -eq 'BaiduOtherAssociations') 'Do not treat unrelated Baidu identity as a player'
    Assert-Test ((Get-Item -LiteralPath ($registryRoot + '\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice')).GetValue('ProgId') -eq 'Browser.Keep') 'Preserve URL default'
    Assert-Test ((Get-CurrentProgId '.jpg') -eq 'Photos.Keep') 'Preserve non-hijacked image'
    Assert-Test ((Get-CurrentProgId '.png') -eq 'Photos.Baseline') 'Restore image baseline'
    Assert-Test (-not (Get-CurrentProgId '.webp')) 'Clear image hijack without baseline'
    Assert-Test (($stopped -join ',') -eq '1,5,7,9') 'Stop only exact dedicated component processes'
    Assert-Test ($notifications -eq 1) 'Notify shell when only registrations/components change'
    foreach ($file in $componentFiles) { Assert-Test (-not (Test-Path -LiteralPath (Join-Path $engine $file))) ('Removed ' + $file) }
    foreach ($file in @('BaiduNetdiskUnite.exe', 'resources\app.asar', 'localplayer.dll', 'vastplayer.dll')) {
        Assert-Test (Test-Path -LiteralPath (Join-Path $engine $file)) ('Preserve shared ' + $file)
    }
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $install 'module\ImageViewer'))) 'Removed install ImageViewer'
    Assert-Test (-not (Test-Path -LiteralPath $appDataImage)) 'Removed AppData ImageViewer'
    foreach ($progId in $BaiduVideoProgIds) {
        Assert-Test (-not (Test-Path -LiteralPath ($registryRoot + '\' + $classes + '\' + $progId))) ('Removed registration ' + $progId)
    }
    $mruKey = Get-Item -LiteralPath ($registryRoot + '\' + $fileExts + '\.listonly\OpenWithList')
    Assert-Test ($mruKey.GetValue('MRUList') -eq 'b' -and $mruKey.GetValue('b') -eq 'Other.exe' -and $null -eq $mruKey.GetValue('a')) 'Preserve MRU order and other applications'
    $fallback = Get-Item -LiteralPath ($registryRoot + '\' + $classes + '\.fallback')
    Assert-Test ($null -eq $fallback.GetValue('') -and $fallback.GetValue('PerceivedType') -eq 'video') 'Remove only owned fallback value'
    Assert-Test (Test-Path -LiteralPath ($registryRoot + '\' + $classes + '\Applications\BaiduNetdisk.open')) 'Preserve main-client application'
    Assert-Test ((Get-Item -LiteralPath ($registryRoot + '\Software\RegisteredApplications')).GetValue('OtherPlayer') -eq 'Software\OtherPlayer\Capabilities') 'Preserve other registered application'
    Assert-Test ((Get-Item -LiteralPath ($registryRoot + '\' + $toast)).GetValueNames() -notcontains ($newProgId + '_.toastonly')) 'Remove owned toast'
    Assert-Test ((Get-Item -LiteralPath ($registryRoot + '\' + $classes + '\.openonly\OpenWithProgids')).GetValueNames() -contains 'Other.Keep') 'Preserve unrelated OpenWithProgID'
    Assert-Test ((Get-Item -LiteralPath ($registryRoot + '\' + $classes + '\.openonly\OpenWithProgids')).GetValueNames() -notcontains 'Applications\BaiduNetdiskPlayer.open') 'Remove empty binary OpenWith value'
    $processes = @()
    $logCount = $logs.Count
    Invoke-Repair -RepairImage $true -RepairVideo $true
    Assert-Test ($logs.Count -eq $logCount) 'Second run is idempotent and quiet'
    Assert-Test ($notifications -eq 1) 'Do not notify shell on a no-op run'

    # Preserve discovery on a failed association write, allowing a later retry.
    Set-TestValue $capability '.retry' $newProgId
    New-TestFile (Join-Path $engine 'BaiduNetdiskPlayerLaunch.exe')
    $failExtension = '.retry'
    Assert-Throws { Invoke-Repair -RepairImage $true -RepairVideo $true } 'Injected association failure'
    Assert-Test (Test-Path -LiteralPath ($registryRoot + '\' + $capability)) 'Keep capability after association failure'
    Assert-Test (Test-Path -LiteralPath (Join-Path $engine 'BaiduNetdiskPlayerLaunch.exe')) 'Keep component after association failure'
    $failExtension = ''
    Invoke-Repair -RepairImage $true -RepairVideo $true
    Assert-Test ((Get-CurrentProgId '.retry') -eq $fixturePlayer.ProgId) 'Retry repairs extra extension'

    # Use a real Windows file lock to check failure propagation without ACL edits.
    $lockedPath = Join-Path $engine 'resources\video_player.asar'
    New-TestFile $lockedPath
    Set-TestValue $capability '.locked' $newProgId
    $lock = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { Assert-Throws { Invoke-Repair -RepairImage $false -RepairVideo $true } 'Component.*video_player.asar' }
    finally { $lock.Dispose() }
    Assert-Test (Test-Path -LiteralPath $lockedPath) 'Locked file is reported, not counted as removed'
    Assert-Test (Test-Path -LiteralPath ($registryRoot + '\' + $capability)) 'Keep discovery registration after module failure'
    Invoke-Repair -RepairImage $false -RepairVideo $true
    Assert-Test (-not (Test-Path -LiteralPath $lockedPath)) 'Retry removes unlocked file'
    $registryRemoval = (Get-Command Remove-RegistryValueIfPresent).ScriptBlock
    function Remove-RegistryValueIfPresent {
        param($Path, $Name)
        if ($Name -eq 'BaiduNetdiskPlayer') { throw 'Injected registry access denied' }
        & $registryRemoval -Path $Path -Name $Name
    }
    try { Assert-Throws { Invoke-Repair -RepairImage $false -RepairVideo $true } 'Registration cleanup: Injected registry access denied' }
    finally { Set-Item -LiteralPath Function:\Remove-RegistryValueIfPresent -Value $registryRemoval }
    Assert-Throws { Remove-BaiduModuleTarget $install '..\outside' } 'escapes root'
    Assert-Throws { Remove-BaiduModuleTarget $install '.' } 'escapes root'
    $outside = Join-Path $testRoot 'Outside'
    New-TestFile (Join-Path $outside 'keep.txt')
    $junction = Join-Path $install 'module\ImageViewer'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    try { Assert-Throws { Remove-BaiduModuleTarget $install 'module\ImageViewer' } 'reparse point' }
    finally { [IO.Directory]::Delete($junction) }
    Assert-Test (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) 'Reparse target remains untouched'
    $nested = Join-Path $install 'module\ImageViewer\nested'
    New-Item -ItemType Directory -Path (Split-Path $nested -Parent) -Force | Out-Null
    New-Item -ItemType Junction -Path $nested -Target $outside | Out-Null
    try { Assert-Throws { Remove-BaiduModuleTarget $install 'module\ImageViewer' } 'reparse point' }
    finally { [IO.Directory]::Delete($nested) }
    Assert-Test (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) 'Nested reparse target remains untouched'

    # Resolve from the command even when installDir is absent; never accept a
    # candidate that lacks the main-client executable.
    Remove-ItemProperty -LiteralPath ($registryRoot + '\Software\Baidu\BaiduYunGuanjia') -Name installDir
    Set-TestValue ($classes + '\' + $newProgId + '\shell\open\command') '' ('"' + $engine + '\BaiduNetdiskPlayerLaunch.exe" --mode=video_player')
    Assert-Test (@(Get-BaiduInstallRoots) -contains $install) 'Command fallback discovers installation'
    Remove-Item -LiteralPath (Join-Path $install 'BaiduNetdisk.exe')
    Assert-Test (@(Get-BaiduInstallRoots).Count -eq 0) 'Reject unverified installation root'
    Write-Host ('PASS: {0} player cleanup assertions; isolated registry, files and process mocks.' -f $checks) -ForegroundColor Green
}
finally {
    $env:APPDATA = $originalAppData
    if ($registryBase -ne ('Software\BaiduMediaGuard.Tests.' + $testId)) { throw 'Unsafe registry fixture cleanup' }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryBase, $false)
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('BaiduMediaGuard.Tests.' + $testId)))
    if ([IO.Path]::GetFullPath($testRoot) -ne $expectedRoot) { throw 'Unsafe filesystem fixture cleanup' }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
