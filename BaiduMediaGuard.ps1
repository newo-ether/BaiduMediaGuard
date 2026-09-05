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
$BaiduVideoApplications = @('BaiduNetdiskUnite', 'BaiduNetdiskPlayer')
$BaiduVideoProgIds = @(
    'BaiduNetdiskUniteAssociations', 'BaiduNetdiskPlayerAssociations',
    'Applications\BaiduNetdiskUnite.exe', 'Applications\BaiduNetdiskUnite.open',
    'Applications\BaiduNetdiskPlayer.open',
    'Applications\BaiduNetdiskPlayerLaunch.exe', 'Applications\BaiduNetdiskPlayer.exe'
)

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
                if ($progId -eq $BaiduImageProgId -or $progId -in $BaiduVideoProgIds) {
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
        if ($progId -and $progId -notmatch '^BaiduNetdisk.*Associations$' -and $progId -notin $BaiduVideoProgIds) {
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

    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) {
        return 0
    }

    if ($null -ne $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force
        return 1
    }

    return 0
}

function Remove-BaiduOpenWithEntries {
    param(
        [Parameter(Mandatory = $true)][string[]]$Extensions,
        [Parameter(Mandatory = $true)][string[]]$ProgIds
    )

    $removed = 0
    foreach ($extension in $Extensions) {
        $paths = @(
            ('HKCU:\Software\Classes\{0}' -f $extension),
            ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\{0}' -f $extension)
        )

        foreach ($path in $paths) {
            $progIdPath = $path + '\OpenWithProgids'
            $progIdKey = Get-Item -LiteralPath $progIdPath -ErrorAction SilentlyContinue
            if ($null -ne $progIdKey) {
                foreach ($name in $progIdKey.GetValueNames()) {
                    if ($name -in $ProgIds) {
                        $removed += Remove-RegistryValueIfPresent -Path $progIdPath -Name $name
                    }
                }
            }
            $listPath = $path + '\OpenWithList'
            $list = Get-Item -LiteralPath $listPath -ErrorAction SilentlyContinue
            if ($null -ne $list) {
                $mru = [string]$list.GetValue('MRUList')
                $originalMru = $mru
                foreach ($name in $list.GetValueNames()) {
                    if ($name -ne 'MRUList' -and ('Applications\' + $list.GetValue($name)) -in $ProgIds) {
                        $removed += Remove-RegistryValueIfPresent -Path $listPath -Name $name
                        $mru = $mru.Replace($name, '')
                    }
                }
                if ($mru -ne $originalMru) {
                    Set-ItemProperty -LiteralPath $listPath -Name MRUList -Value $mru
                }
                foreach ($name in $list.GetSubKeyNames()) {
                    if (('Applications\' + $name) -in $ProgIds) {
                        $removed += Remove-RegistryTreeIfPresent -Path ($listPath + '\' + $name)
                    }
                }
            }
            $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($null -ne $key -and $key.GetValue('') -in $ProgIds) {
                $writable = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($key.Name.Substring('HKEY_CURRENT_USER\'.Length), $true)
                try {
                    if ($writable.GetValue('') -in $ProgIds) {
                        $writable.DeleteValue('')
                        $removed++
                    }
                }
                finally { $writable.Dispose() }
            }
        }

    }
    # Inspect existing toast names once, rather than repeatedly asking the
    # provider for hundreds of absent properties on a potentially large key.
    $toastPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts'
    $toast = Get-Item -LiteralPath $toastPath -ErrorAction SilentlyContinue
    if ($null -ne $toast) {
        foreach ($name in $toast.GetValueNames()) {
            foreach ($progId in $ProgIds) {
                if ($name.StartsWith($progId + '_.', [StringComparison]::OrdinalIgnoreCase) -and
                    $name.Substring($progId.Length + 1) -in $Extensions) {
                    $removed += Remove-RegistryValueIfPresent -Path $toastPath -Name $name
                }
            }
        }
    }

    return $removed
}

function Get-BaiduVideoExtensions {
    # Read the entire footprint before deleting any registration, including formats
    # that exist only in OpenWith or as a Classes fallback (without UserChoice).
    $KnownVideoExtensions
    foreach ($application in $BaiduVideoApplications) {
        Get-CapabilityExtensions -Path ('HKCU:\Software\Baidu\' + $application + '\Capabilities\FileAssociations')
    }
    foreach ($root in @('HKCU:\Software\Classes', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts')) {
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\.[^\\/]+$' } | ForEach-Object {
                $extension = $_
                $owned = $extension.GetValue('') -in $BaiduVideoProgIds
                foreach ($child in @('UserChoice', 'OpenWithProgids', 'OpenWithList')) {
                    $key = Get-Item -LiteralPath ($extension.PSPath + '\' + $child) -ErrorAction SilentlyContinue
                    if ($null -eq $key) { continue }
                    foreach ($name in $key.GetValueNames()) {
                        $value = $key.GetValue($name)
                        if ($name -in $BaiduVideoProgIds -or $value -in $BaiduVideoProgIds -or
                            ('Applications\' + $value) -in $BaiduVideoProgIds) { $owned = $true }
                    }
                    foreach ($name in $key.GetSubKeyNames()) {
                        if (('Applications\' + $name) -in $BaiduVideoProgIds) { $owned = $true }
                    }
                }
                if ($owned) { $extension.PSChildName.ToLowerInvariant() }
            }
    }
    $toast = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts' -ErrorAction SilentlyContinue
    if ($null -ne $toast) {
        foreach ($name in $toast.GetValueNames()) {
            foreach ($progId in $BaiduVideoProgIds) {
                if ($name.StartsWith($progId + '_.', [StringComparison]::OrdinalIgnoreCase)) {
                    $name.Substring($progId.Length + 1)
                }
            }
        }
    }
}

function Get-BaiduInstallRoots {
    $candidates = @(
        foreach ($hive in @('HKCU:\Software', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
            (Get-ItemProperty -LiteralPath ($hive + '\Baidu\BaiduYunGuanjia') -Name installDir -ErrorAction SilentlyContinue).installDir
        }
        foreach ($progId in @($BaiduImageProgId) + $BaiduVideoProgIds) {
            $key = Get-Item -LiteralPath ('HKCU:\Software\Classes\' + $progId + '\shell\open\command') -ErrorAction SilentlyContinue
            if ($null -ne $key -and [string]$key.GetValue('') -match '^"?(.+?)\\module\\(?:BrowserEngine|ImageViewer)\\[^\\"]+\.exe(?:"|\s|$)') {
                $Matches[1]
            }
        }
    )
    foreach ($candidate in @($candidates | Where-Object { $_ } | Sort-Object -Unique)) {
        $path = [Environment]::ExpandEnvironmentVariables(([string]$candidate).Trim('"'))
        if ($path -notmatch '^(?:[a-zA-Z]:\\|\\\\[^\\]+\\[^\\]+\\)') { continue }
        $path = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if (Test-Path -LiteralPath (Join-Path $path 'BaiduNetdisk.exe') -PathType Leaf) { $path }
    }
}

function Resolve-BaiduCleanupPath {
    param([string]$Root, [string]$RelativePath)

    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or $path -eq $base.TrimEnd('\')) {
        throw "Cleanup target escapes root: $path"
    }
    # Reject links in both the target and its ancestors, before any traversal.
    $ancestor = $path
    while ($ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing reparse point: $ancestor"
        }
        $ancestor = Split-Path -Path $ancestor -Parent
    }
    return $path
}

function Remove-BaiduModuleTarget {
    param([string]$Root, [string]$RelativePath)

    $path = Resolve-BaiduCleanupPath -Root $Root -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    # Inspect one directory at a time so a nested junction is never traversed.
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($path)
    while ($pending.Count -gt 0) {
        $item = Get-Item -LiteralPath $pending.Dequeue() -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse point: $($item.FullName)" }
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) { $pending.Enqueue($child.FullName) }
        }
    }
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $path) { throw "Cleanup target remains: $path" }
    Write-GuardLog ('Removed component: ' + $path)
    return 1
}

function Remove-BaiduModules {
    param([bool]$RemoveImage, [bool]$RemoveVideo, [string[]]$InstallRoots,
        [System.Collections.Generic.List[string]]$Failures)

    $removed = 0
    $targets = @(
        foreach ($root in $InstallRoots) {
            if ($RemoveImage) { [pscustomobject]@{ Root = $root; RelativePath = 'module\ImageViewer' } }
            if ($RemoveVideo) {
                foreach ($file in @('BaiduNetdiskPlayerLaunch.exe', 'resources\video_player.asar',
                    'resources\BaiduNetdiskPlayer.ico', 'module\asar\video_player.asar.new', 'module\asar\video_player.asar.sig')) {
                    [pscustomobject]@{ Root = $root; RelativePath = 'module\BrowserEngine\' + $file }
                }
            }
        }
        if ($RemoveImage) { [pscustomobject]@{ Root = $env:APPDATA; RelativePath = 'baidu\BaiduNetdisk\module\ImageViewer' } }
    )
    try {
        $imageExecutables = @($targets | Where-Object { $_.RelativePath.EndsWith('\ImageViewer') } | ForEach-Object {
            Resolve-BaiduCleanupPath $_.Root ($_.RelativePath + '\BaiduNetdiskImageViewer.exe')
        })
        $launchers = @()
        $engines = @()
        if ($RemoveVideo) {
            $launchers = @($InstallRoots | ForEach-Object { Resolve-BaiduCleanupPath $_ 'module\BrowserEngine\BaiduNetdiskPlayerLaunch.exe' })
            $engines = @($InstallRoots | ForEach-Object { Resolve-BaiduCleanupPath $_ 'module\BrowserEngine\BaiduNetdiskUnite.exe' })
        }
        foreach ($process in Get-CimInstance Win32_Process -Filter "Name = 'BaiduNetdiskPlayerLaunch.exe' OR Name = 'BaiduNetdiskUnite.exe' OR Name = 'BaiduNetdiskImageViewer.exe'") {
            # Keep quoted file paths together: a filename containing the mode
            # text must never identify a shared engine as a player process.
            $modes = @([regex]::Matches([string]$process.CommandLine, '(?:[^\s"]+|"[^"]*")+') |
                ForEach-Object { $_.Value.Trim('"') } | Where-Object { $_ -clike '--mode=*' })
            $playerMode = $modes.Count -eq 1 -and $modes[0] -ceq '--mode=video_player'
            if ($process.ExecutablePath -in $imageExecutables -or $process.ExecutablePath -in $launchers -or
                ($process.ExecutablePath -in $engines -and $playerMode)) {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
                Write-GuardLog ('Stopped component process: {0} ({1})' -f $process.ExecutablePath, $process.ProcessId)
            }
        }
    }
    catch { $Failures.Add(('Component process cleanup: ' + $_.Exception.Message)) }
    foreach ($target in $targets) {
        try { $removed += Remove-BaiduModuleTarget -Root $target.Root -RelativePath $target.RelativePath }
        catch { $Failures.Add(('Component {0}: {1}' -f (Join-Path $target.Root $target.RelativePath), $_.Exception.Message)) }
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
        $removed += Remove-BaiduOpenWithEntries -Extensions $ImageExtensions -ProgIds @($BaiduImageProgId, 'Applications\BaiduNetdiskImageViewer.exe')
    }

    if ($RemoveVideo) {
        foreach ($application in $BaiduVideoApplications) {
            $removed += Remove-RegistryValueIfPresent -Path $registeredApplications -Name $application
            $removed += Remove-RegistryTreeIfPresent -Path ('HKCU:\Software\Baidu\' + $application + '\Capabilities')
        }
        foreach ($progId in $BaiduVideoProgIds) {
            $removed += Remove-RegistryTreeIfPresent -Path ('HKCU:\Software\Classes\' + $progId)
        }
        $removed += Remove-BaiduOpenWithEntries -Extensions $VideoExtensions -ProgIds $BaiduVideoProgIds
    }

    return $removed
}

function Send-AssociationChange {
    if (-not ('BaiduMediaGuard.Shell' -as [type])) {
        Add-Type -Namespace BaiduMediaGuard -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);
'@
    }
    [BaiduMediaGuard.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
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
    $hijacks = @(Get-BaiduUserChoices)
    $installRoots = @(Get-BaiduInstallRoots | Sort-Object -Unique)

    $imageExtensions = @(
        $KnownImageExtensions +
        (Get-CapabilityExtensions -Path $imageCapabilityPath) +
        @($hijacks | Where-Object { $_.ProgId -eq $BaiduImageProgId } | ForEach-Object { $_.Extension }) |
            Sort-Object -Unique
    )
    $videoExtensions = @(
        Get-BaiduVideoExtensions |
            Where-Object { $_ -match '^\.[^\\/]+$' } |
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
        $declaredVideoExtensions = @($KnownVideoExtensions + @(
            foreach ($application in $BaiduVideoApplications) {
                Get-CapabilityExtensions -Path ('HKCU:\Software\Baidu\' + $application + '\Capabilities\FileAssociations')
            }
        ))
        $videoToRepair = @(
            $videoExtensions | Where-Object {
                $current = Get-CurrentProgId -Extension $_
                $fallback = $null
                if (-not $current) {
                    $key = Get-Item -LiteralPath ('HKCU:\Software\Classes\' + $_) -ErrorAction SilentlyContinue
                    if ($null -ne $key) { $fallback = $key.GetValue('') }
                }
                # OpenWith/MRU history alone is not evidence that the default
                # was hijacked: nonmedia files may have been opened by Netdisk.
                $eligible = $_ -in $declaredVideoExtensions -or $current -in $BaiduVideoProgIds -or $fallback -in $BaiduVideoProgIds
                $eligible -and $current -ne $player.ProgId
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

    $registrationsRemoved = 0
    $modulesRemoved = 0
    # Preserve discovery evidence if defaults could not be repaired this time.
    if ($failures.Count -eq 0) {
        $modulesRemoved = Remove-BaiduModules -RemoveImage $RepairImage -RemoveVideo $RepairVideo -InstallRoots $installRoots -Failures $failures
        if ($failures.Count -eq 0) {
            try {
                $registrationsRemoved = Remove-BaiduRegistrations `
                    -RemoveImage $RepairImage `
                    -RemoveVideo $RepairVideo `
                    -ImageExtensions $imageExtensions `
                    -VideoExtensions $videoExtensions
            }
            catch { $failures.Add(('Registration cleanup: ' + $_.Exception.Message)) }
        }
    }

    $remaining = @(
        Get-BaiduUserChoices | Where-Object {
            ($RepairImage -and $_.ProgId -eq $BaiduImageProgId) -or
            ($RepairVideo -and $_.ProgId -in $BaiduVideoProgIds)
        }
    )
    foreach ($item in $remaining) {
        $failures.Add(('Remaining hijack {0}: {1}' -f $item.Extension, $item.ProgId))
    }
    if ($registrationsRemoved -gt 0 -or $modulesRemoved -gt 0) {
        try { Send-AssociationChange }
        catch { $failures.Add(('Shell association refresh: ' + $_.Exception.Message)) }
    }

    $summary = 'Image restored: {0}; video restored: {1}; Baidu registrations removed: {2}; remaining Baidu defaults: {3}; components removed: {4}; failures: {5}' -f `
        $imageChanged, $videoChanged, $registrationsRemoved, $remaining.Count, $modulesRemoved, $failures.Count

    if (($imageChanged + $videoChanged + $registrationsRemoved + $modulesRemoved) -gt 0 -or $failures.Count -gt 0) {
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
