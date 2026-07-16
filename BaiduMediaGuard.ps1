[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [switch]$ImageOnly,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$VideoOnly,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [switch]$Install,

    [Parameter(Mandatory = $true, ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,

    [Parameter(Mandatory = $true, ParameterSetName = 'Guard')]
    [switch]$Guard,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(1, 60)]
    [int]$IntervalMinutes = 2,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Install')]
    [string]$PlayerPath,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$TaskName = 'Baidu Media Guard'
$InstallDirectory = Join-Path $env:LOCALAPPDATA 'BaiduMediaGuard'
$InstalledScript = Join-Path $InstallDirectory 'BaiduMediaGuard.ps1'
$BaselinePath = Join-Path $InstallDirectory 'baseline.json'
$ConfigPath = Join-Path $InstallDirectory 'config.json'
$LogPath = Join-Path $InstallDirectory 'guard.log'
$SftaPath = Join-Path $PSScriptRoot 'SFTA.ps1'
$HiddenLauncherPath = Join-Path $PSScriptRoot 'RunGuardHidden.vbs'

$BaiduImageProgId = 'BaiduNetdiskImageViewerAssociations'
$BaiduVideoProgId = 'BaiduNetdiskUniteAssociations'

# Dot-source in script scope so Set-FTA and Remove-FTA remain visible to all
# repair functions. Loading the helper itself does not modify the registry.
if (-not $Uninstall) {
    if (-not (Test-Path -LiteralPath $SftaPath)) {
        throw "Missing helper: $SftaPath"
    }
    . $SftaPath
}

# Compatibility fallback for extensions declared by known Baidu Netdisk releases.
# Live Capabilities and UserChoice entries are also scanned, so later versions
# can add formats without escaping the guard.
$KnownImageExtensions = @(
    '.3fr', '.arw', '.bmp', '.cr2', '.cr3', '.dng', '.heic', '.heif',
    '.jpeg', '.jpg', '.nef', '.nrw', '.orf', '.pef', '.png', '.raf',
    '.rw2', '.srw', '.tiff', '.webp'
)

$KnownVideoExtensions = @(
    '.3g2', '.3gp', '.264', '.265', '.avi', '.avc', '.avs', '.avs2',
    '.avs3', '.bik', '.bk2', '.dav', '.dif', '.dv', '.evc', '.f4v',
    '.flv', '.h261', '.h263', '.h264', '.h265', '.h26l', '.hevc', '.ifv',
    '.ism', '.ismv', '.j2k', '.kux', '.m2t', '.m2ts', '.m2v', '.mj2',
    '.mjpg', '.mk3d', '.mkv', '.moflex', '.mov', '.mp4', '.mpeg', '.mpg',
    '.mts', '.mxf', '.mxg', '.nsv', '.obu', '.pdv', '.pmp', '.psp',
    '.r3d', '.rcv', '.rm', '.rmvb', '.roq', '.smk', '.str', '.swf',
    '.tmv', '.ts', '.ty', '.ty+', '.usm', '.v', '.v210', '.vc1', '.viv',
    '.vob', '.vpk', '.vvc', '.webm', '.wmv', '.wtv', '.xmv', '.y4m',
    '.yop', '.yuv', '.yuv10'
)

function Write-Status {
    param([string]$Message)

    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Write-GuardLog {
    param([string]$Message)

    if (-not (Test-Path -LiteralPath $InstallDirectory)) {
        return
    }

    try {
        if ((Test-Path -LiteralPath $LogPath) -and
            (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.old') -Force
        }

        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value (
            '{0:u} {1}' -f (Get-Date), $Message
        )
    }
    catch {
        # Logging must never stop the repair.
    }
}

function Get-CurrentProgId {
    param([Parameter(Mandatory = $true)][string]$Extension)

    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\{0}\UserChoice' -f $Extension
    return (Get-ItemProperty -LiteralPath $path -Name ProgId -ErrorAction SilentlyContinue).ProgId
}

function Get-CapabilityExtensions {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return @(
        (Get-ItemProperty -LiteralPath $Path).PSObject.Properties |
            Where-Object { $_.Name -match '^\.' } |
            ForEach-Object { $_.Name.ToLowerInvariant() }
    )
}

function Get-BaiduUserChoices {
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
    if (-not (Test-Path -LiteralPath $base)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue |
            ForEach-Object {
                $progId = (Get-ItemProperty -LiteralPath (Join-Path $_.PSPath 'UserChoice') -Name ProgId -ErrorAction SilentlyContinue).ProgId
                if ($progId -match '^BaiduNetdisk.*Associations$') {
                    [pscustomobject]@{
                        Extension = $_.PSChildName.ToLowerInvariant()
                        ProgId = $progId
                    }
                }
            }
    )
}

function Get-ImageBaseline {
    $map = @{}
    if (-not (Test-Path -LiteralPath $BaselinePath)) {
        return $map
    }

    try {
        $data = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
        if ($null -ne $data.ImageAssociations) {
            foreach ($property in $data.ImageAssociations.PSObject.Properties) {
                $map[$property.Name.ToLowerInvariant()] = [string]$property.Value
            }
        }
    }
    catch {
        Write-GuardLog ('Could not read image baseline: {0}' -f $_.Exception.Message)
    }

    return $map
}

function Save-ImageBaseline {
    $map = Get-ImageBaseline
    $capabilityPath = 'HKCU:\Software\Baidu\BaiduNetdiskImageViewer\Capabilities\FileAssociations'
    $extensions = @($KnownImageExtensions + (Get-CapabilityExtensions -Path $capabilityPath) | Sort-Object -Unique)

    foreach ($extension in $extensions) {
        if ($map.ContainsKey($extension)) {
            continue
        }

        $progId = Get-CurrentProgId -Extension $extension
        if ($progId -and $progId -notmatch '^BaiduNetdisk.*Associations$') {
            $map[$extension] = $progId
        }
    }

    $orderedMap = [ordered]@{}
    foreach ($extension in @($map.Keys | Sort-Object)) {
        $orderedMap[$extension] = $map[$extension]
    }

    [ordered]@{
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        ImageAssociations = $orderedMap
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BaselinePath -Encoding UTF8
}

function Import-Sfta {
    if (-not (Get-Command -Name Set-FTA -ErrorAction SilentlyContinue)) {
        throw 'SFTA helper loaded, but Set-FTA is unavailable.'
    }
}

function New-PlayerConfiguration {
    param([Parameter(Mandatory = $true)][string]$RequestedPath)

    $expandedPath = [Environment]::ExpandEnvironmentVariables($RequestedPath.Trim().Trim('"').Trim("'"))
    if ([string]::IsNullOrWhiteSpace($expandedPath)) {
        throw 'The player executable path is empty.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($expandedPath)
    if ([System.IO.Path]::GetExtension($fullPath) -ine '.exe') {
        throw "The selected player is not an .exe file: $fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "The selected player does not exist: $fullPath"
    }

    $fileName = [System.IO.Path]::GetFileName($fullPath)
    $fileInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($fullPath)
    $displayName = $fileInfo.FileDescription
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    }

    return [pscustomobject]@{
        PlayerPath = $fullPath
        PlayerName = $displayName
        ProgId = 'Applications\' + $fileName
        ConfiguredUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Save-PlayerConfiguration {
    param([Parameter(Mandatory = $true)]$Configuration)

    $Configuration | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-PlayerConfiguration {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return New-PlayerConfiguration -RequestedPath $RequestedPath
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw 'No player is configured. Run install.ps1 and select a player executable.'
    }

    try {
        $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        return New-PlayerConfiguration -RequestedPath ([string]$saved.PlayerPath)
    }
    catch {
        throw ('The saved player configuration is invalid: {0}' -f $_.Exception.Message)
    }
}

function Ensure-PlayerRegistration {
    param([Parameter(Mandatory = $true)]$Configuration)

    $fileName = [System.IO.Path]::GetFileName($Configuration.PlayerPath)
    $applicationKey = 'HKEY_CURRENT_USER\Software\Classes\Applications\{0}' -f $fileName
    $commandKey = $applicationKey + '\shell\open\command'
    $command = '"{0}" "%1"' -f $Configuration.PlayerPath
    [Microsoft.Win32.Registry]::SetValue($commandKey, '', $command, [Microsoft.Win32.RegistryValueKind]::String)
    [Microsoft.Win32.Registry]::SetValue($applicationKey + '\shell\open', 'FriendlyAppName', $Configuration.PlayerName, [Microsoft.Win32.RegistryValueKind]::String)
    [Microsoft.Win32.Registry]::SetValue($applicationKey + '\DefaultIcon', '', $Configuration.PlayerPath + ',0', [Microsoft.Win32.RegistryValueKind]::String)
}

function Remove-RegistryTreeIfPresent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        return 1
    }

    return 0
}

function Remove-RegistryValueIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $property = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $property) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force
        return 1
    }

    return 0
}

function Remove-BaiduOpenWithEntries {
    param(
        [Parameter(Mandatory = $true)][string[]]$Extensions,
        [Parameter(Mandatory = $true)][string]$ProgId
    )

    $removed = 0
    foreach ($extension in $Extensions) {
        $paths = @(
            ('HKCU:\Software\Classes\{0}\OpenWithProgids' -f $extension),
            ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\{0}\OpenWithProgids' -f $extension)
        )

        foreach ($path in $paths) {
            $removed += Remove-RegistryValueIfPresent -Path $path -Name $ProgId
        }

        $toastPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts'
        $removed += Remove-RegistryValueIfPresent -Path $toastPath -Name ($ProgId + '_' + $extension)
    }

    return $removed
}

function Remove-BaiduRegistrations {
    param(
        [Parameter(Mandatory = $true)][bool]$RemoveImage,
        [Parameter(Mandatory = $true)][bool]$RemoveVideo,
        [Parameter(Mandatory = $true)][string[]]$ImageExtensions,
        [Parameter(Mandatory = $true)][string[]]$VideoExtensions
    )

    $removed = 0
    $registeredApplications = 'HKCU:\Software\RegisteredApplications'

    if ($RemoveImage) {
        $removed += Remove-RegistryValueIfPresent -Path $registeredApplications -Name 'BaiduNetdiskImageViewer'
        $removed += Remove-RegistryTreeIfPresent -Path 'HKCU:\Software\Baidu\BaiduNetdiskImageViewer\Capabilities'
        $removed += Remove-RegistryTreeIfPresent -Path ('HKCU:\Software\Classes\' + $BaiduImageProgId)
        $removed += Remove-RegistryTreeIfPresent -Path 'HKCU:\Software\Classes\Applications\BaiduNetdiskImageViewer.exe'
        $removed += Remove-BaiduOpenWithEntries -Extensions $ImageExtensions -ProgId $BaiduImageProgId

        $imageViewerPath = Join-Path $env:APPDATA 'baidu\BaiduNetdisk\module\ImageViewer'
        if (Test-Path -LiteralPath $imageViewerPath) {
            try {
                Remove-Item -LiteralPath $imageViewerPath -Recurse -Force
                $removed++
            }
            catch {
                Write-GuardLog ('Could not remove ImageViewer module: {0}' -f $_.Exception.Message)
            }
        }
    }

    if ($RemoveVideo) {
        $removed += Remove-RegistryValueIfPresent -Path $registeredApplications -Name 'BaiduNetdiskUnite'
        $removed += Remove-RegistryTreeIfPresent -Path 'HKCU:\Software\Baidu\BaiduNetdiskUnite\Capabilities'
        $removed += Remove-RegistryTreeIfPresent -Path ('HKCU:\Software\Classes\' + $BaiduVideoProgId)
        $removed += Remove-RegistryTreeIfPresent -Path 'HKCU:\Software\Classes\Applications\BaiduNetdiskUnite.exe'
        $removed += Remove-BaiduOpenWithEntries -Extensions $VideoExtensions -ProgId $BaiduVideoProgId
    }

    return $removed
}

function Invoke-Repair {
    param(
        [Parameter(Mandatory = $true)][bool]$RepairImage,
        [Parameter(Mandatory = $true)][bool]$RepairVideo,
        [string]$RequestedPlayerPath
    )

    $player = $null
    if ($RepairVideo) {
        $player = Get-PlayerConfiguration -RequestedPath $RequestedPlayerPath
    }

    $imageCapabilityPath = 'HKCU:\Software\Baidu\BaiduNetdiskImageViewer\Capabilities\FileAssociations'
    $videoCapabilityPath = 'HKCU:\Software\Baidu\BaiduNetdiskUnite\Capabilities\FileAssociations'
    $hijacks = @(Get-BaiduUserChoices)

    $imageExtensions = @(
        $KnownImageExtensions +
        (Get-CapabilityExtensions -Path $imageCapabilityPath) +
        @($hijacks | Where-Object { $_.ProgId -eq $BaiduImageProgId } | ForEach-Object { $_.Extension }) |
            Sort-Object -Unique
    )
    $videoExtensions = @(
        $KnownVideoExtensions +
        (Get-CapabilityExtensions -Path $videoCapabilityPath) +
        @($hijacks | Where-Object { $_.ProgId -eq $BaiduVideoProgId } | ForEach-Object { $_.Extension }) |
            Sort-Object -Unique
    )

    $imageToRepair = @()
    if ($RepairImage) {
        $imageToRepair = @(
            $imageExtensions | Where-Object {
                (Get-CurrentProgId -Extension $_) -eq $BaiduImageProgId
            }
        )
    }

    $videoToRepair = @()
    if ($RepairVideo) {
        $videoToRepair = @(
            $videoExtensions | Where-Object {
                (Get-CurrentProgId -Extension $_) -ne $player.ProgId
            }
        )
    }

    $imageChanged = 0
    $videoChanged = 0
    $failures = New-Object System.Collections.Generic.List[string]

    if (($imageToRepair.Count -gt 0) -or ($videoToRepair.Count -gt 0)) {
        Import-Sfta
    }

    if ($RepairImage -and ($imageToRepair.Count -gt 0)) {
        $baseline = Get-ImageBaseline
        foreach ($extension in $imageToRepair) {
            try {
                if ($baseline.ContainsKey($extension)) {
                    Set-FTA -ProgId $baseline[$extension] -Extension $extension
                }
                else {
                    Remove-FTA -ProgramPath $BaiduImageProgId -Extension $extension | Out-Null
                }

                if ((Get-CurrentProgId -Extension $extension) -eq $BaiduImageProgId) {
                    throw 'UserChoice still points to Baidu after repair.'
                }
                $imageChanged++
            }
            catch {
                $failures.Add(('Image {0}: {1}' -f $extension, $_.Exception.Message))
            }
        }
    }

    if ($RepairVideo -and ($videoToRepair.Count -gt 0)) {
        Ensure-PlayerRegistration -Configuration $player
        $index = 0
        foreach ($extension in $videoToRepair) {
            $index++
            if (-not $Quiet) {
                Write-Progress -Activity ('Restoring video defaults to {0}' -f $player.PlayerName) -Status $extension -PercentComplete (($index * 100) / $videoToRepair.Count)
            }

            try {
                Set-FTA -ProgId $player.ProgId -Extension $extension
                if ((Get-CurrentProgId -Extension $extension) -ne $player.ProgId) {
                    throw 'UserChoice verification failed.'
                }
                $videoChanged++
            }
            catch {
                $failures.Add(('Video {0}: {1}' -f $extension, $_.Exception.Message))
            }
        }

        if (-not $Quiet) {
            Write-Progress -Activity ('Restoring video defaults to {0}' -f $player.PlayerName) -Completed
        }
    }

    $registrationsRemoved = Remove-BaiduRegistrations `
        -RemoveImage $RepairImage `
        -RemoveVideo $RepairVideo `
        -ImageExtensions $imageExtensions `
        -VideoExtensions $videoExtensions

    $remaining = @(
        Get-BaiduUserChoices | Where-Object {
            ($RepairImage -and $_.ProgId -eq $BaiduImageProgId) -or
            ($RepairVideo -and $_.ProgId -eq $BaiduVideoProgId)
        }
    )
    foreach ($item in $remaining) {
        $failures.Add(('Remaining hijack {0}: {1}' -f $item.Extension, $item.ProgId))
    }

    $summary = 'Image restored: {0}; video restored: {1}; Baidu registrations removed: {2}; remaining Baidu defaults: {3}' -f `
        $imageChanged, $videoChanged, $registrationsRemoved, $remaining.Count

    if (($imageChanged + $videoChanged + $registrationsRemoved) -gt 0 -or $failures.Count -gt 0) {
        Write-GuardLog $summary
        foreach ($failure in $failures) {
            Write-GuardLog ('ERROR ' + $failure)
        }
    }

    Write-Status $summary

    if ($failures.Count -gt 0) {
        throw ($failures -join [Environment]::NewLine)
    }
}

function Install-GuardTask {
    param([Parameter(Mandatory = $true)][string]$ConfiguredPlayerPath)

    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    Save-ImageBaseline
    $configuration = New-PlayerConfiguration -RequestedPath $ConfiguredPlayerPath
    Save-PlayerConfiguration -Configuration $configuration

    $sourceScript = [System.IO.Path]::GetFullPath($PSCommandPath)
    $destinationScript = [System.IO.Path]::GetFullPath($InstalledScript)
    if ($sourceScript -ne $destinationScript) {
        Copy-Item -LiteralPath $sourceScript -Destination $InstalledScript -Force
    }

    $sourceSfta = [System.IO.Path]::GetFullPath($SftaPath)
    $destinationSfta = [System.IO.Path]::GetFullPath((Join-Path $InstallDirectory 'SFTA.ps1'))
    if ($sourceSfta -ne $destinationSfta) {
        Copy-Item -LiteralPath $sourceSfta -Destination $destinationSfta -Force
    }

    if (-not (Test-Path -LiteralPath $HiddenLauncherPath)) {
        throw "Missing hidden launcher: $HiddenLauncherPath"
    }
    $installedLauncher = Join-Path $InstallDirectory 'RunGuardHidden.vbs'
    $sourceLauncher = [System.IO.Path]::GetFullPath($HiddenLauncherPath)
    $destinationLauncher = [System.IO.Path]::GetFullPath($installedLauncher)
    if ($sourceLauncher -ne $destinationLauncher) {
        Copy-Item -LiteralPath $sourceLauncher -Destination $installedLauncher -Force
    }

    $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $action = New-ScheduledTaskAction -Execute $wscriptExe -Argument ('"{0}"' -f $installedLauncher)
    $userName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userName
    $repeatTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($logonTrigger, $repeatTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description ('Silently restores Baidu-hijacked media defaults to {0}.' -f $configuration.PlayerName) `
        -Force | Out-Null

    Write-GuardLog ("Installed scheduled task for '$($configuration.PlayerPath)' with a ${IntervalMinutes}-minute guard interval.")
    Write-Status "Configured player: $($configuration.PlayerName)"
    Write-Status "Player path: $($configuration.PlayerPath)"
    Write-Status "Installed silent scheduled task '$TaskName' (logon + every $IntervalMinutes minutes)."
}

function Uninstall-GuardTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if (Test-Path -LiteralPath $InstallDirectory) {
        Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
    }

    Write-Status "Removed scheduled task '$TaskName' and its installed files."
}

if ($ImageOnly -and $VideoOnly) {
    throw 'Use either -ImageOnly or -VideoOnly, not both.'
}

if ($Uninstall) {
    Uninstall-GuardTask
    return
}

if ($Install) {
    if ([string]::IsNullOrWhiteSpace($PlayerPath)) {
        throw 'PlayerPath is required for installation. Run install.ps1 for the interactive installer.'
    }
    Install-GuardTask -ConfiguredPlayerPath $PlayerPath
    Invoke-Repair -RepairImage $true -RepairVideo $true -RequestedPlayerPath $PlayerPath
    return
}

if ($Guard) {
    Invoke-Repair -RepairImage $true -RepairVideo $true
    return
}

Invoke-Repair -RepairImage (-not $VideoOnly) -RepairVideo (-not $ImageOnly) -RequestedPlayerPath $PlayerPath
