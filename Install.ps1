#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Root,
    [ValidateSet('Stage', 'InstallPacks', 'InstallBase', 'ImportClient', 'Profile', 'Backup', 'OpenLauncher')]
    [string] $Action = 'Stage',
    [ValidateSet('Performance', 'Balanced', 'Cinematic')]
    [string] $Profile = 'Balanced',
    [string] $PatrixZip,
    [string] $ClientArtifact,
    [switch] $TrustHostedClient,
    [string] $World
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$lock = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'pack.lock.json') | ConvertFrom-Json -AsHashtable
if ($lock.schema -ne 1) { throw 'Unsupported pack lock schema' }

$Root = [IO.Path]::GetFullPath($Root)
if ($Root -eq [IO.Path]::GetPathRoot($Root)) { throw 'Choose a dedicated directory for the pack' }
$marker = Join-Path $Root '.horizon-vanillapp'
$name = 'Horizon Vanilla++ M1'

if (!(Test-Path -LiteralPath $marker)) {
    if (Test-Path -LiteralPath $Root) {
        if (@(Get-ChildItem -Force -LiteralPath $Root).Count) {
            throw 'Choose an empty directory dedicated to this pack'
        }
    } else {
        New-Item -ItemType Directory -Path $Root | Out-Null
    }
    Set-Content -LiteralPath $marker -Value 'horizon-vanillapp-v1'
}
if ((Get-Content -Raw -LiteralPath $marker).Trim() -cne 'horizon-vanillapp-v1') {
    throw 'Invalid pack directory marker'
}

$cache = Join-Path $Root 'downloads'
[IO.Directory]::CreateDirectory($cache) | Out-Null

function Assert-PinnedFile($Path, $Entry) {
    if ((Get-Item -LiteralPath $Path).Length -ne $Entry.size) {
        throw "Incorrect size for $($Entry.name)"
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm $Entry.algorithm).Hash -ine $Entry.hash) {
        throw "Incorrect hash for $($Entry.name)"
    }
}

function Save-PinnedFile($Entry, $LocalFile) {
    $destination = Join-Path $cache $Entry.name
    if (Test-Path -LiteralPath $destination) {
        Assert-PinnedFile $destination $Entry
        return $destination
    }

    $partial = Join-Path $cache ([guid]::NewGuid().ToString() + '.partial')
    try {
        if ($LocalFile) {
            Assert-PinnedFile $LocalFile $Entry
            Copy-Item -LiteralPath $LocalFile -Destination $partial
        } elseif ($Entry.name -eq $lock.files.patrix.name) {
            throw "Supply the author's archive with -PatrixZip. Download: $($Entry.source)"
        } else {
            Invoke-WebRequest -Uri $Entry.url -OutFile $partial -TimeoutSec 90
        }
        Assert-PinnedFile $partial $Entry
        [IO.File]::Move($partial, $destination)
        return $destination
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
    }
}

function Install-PinnedBase($LauncherData) {
    $base = $lock.importBase
    $archive = Save-PinnedFile $base.asset
    $versions = Join-Path $LauncherData 'versions'
    [IO.Directory]::CreateDirectory($versions) | Out-Null
    $destination = Join-Path $versions $base.tag
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $client = @($zip.Entries | Where-Object Name -ceq 'horizon-client.exe')
        if ($client.Count -ne 1) { throw 'Expected one Horizon game binary in the base archive' }
        $prefix = $client[0].FullName.Substring(0, $client[0].FullName.Length - $client[0].Name.Length)
        if ($prefix -cnotmatch '^(|[^/]+/)$') { throw 'Unexpected Horizon archive layout' }
        $files = @($zip.Entries | Where-Object Name -ne '')
        foreach ($entry in $files) {
            if (!$entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal)) {
                throw 'Unexpected file outside the base archive root'
            }
        }
        if (Test-Path -LiteralPath $destination) {
            if (!(Test-Path -LiteralPath (Join-Path $destination '.installed') -PathType Leaf)) {
                throw "Base version directory already exists without an install marker: $destination"
            }
            foreach ($entry in $files) {
                $path = Join-Path $destination ($entry.FullName.Substring($prefix.Length))
                $stream = $entry.Open()
                try { $expected = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash }
                finally { $stream.Dispose() }
                if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $expected) {
                    throw "Installed base file differs from the pinned archive: $path"
                }
            }
            return
        }

        $pending = Join-Path $versions ".pack-base-$([guid]::NewGuid())"
        try {
            [IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip, $pending)
            $unpacked = if ($prefix) { Join-Path $pending $prefix } else { $pending }
            [IO.File]::WriteAllText((Join-Path $unpacked '.installed'), '')
            [IO.Directory]::Move($unpacked, $destination)
        } finally {
            if ([IO.Directory]::Exists($pending)) {
                $resolved = [IO.Path]::GetFullPath($pending)
                if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($versions) -or
                    [IO.Path]::GetFileName($resolved) -cnotmatch '^\.pack-base-[0-9a-f-]{36}$') {
                    throw "Unexpected extraction directory: $resolved"
                }
                [IO.Directory]::Delete($resolved, $true)
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function Set-ProfileOptions($Path, $Values) {
    $lines = [Collections.Generic.List[string]]::new()
    if ([IO.File]::Exists($Path)) {
        $lines.AddRange([IO.File]::ReadAllLines($Path))
    }
    foreach ($key in $Values.Keys) {
        $lines.RemoveAll([Predicate[string]] { param($line) $line.StartsWith("${key}:", [StringComparison]::Ordinal) }) | Out-Null
        $lines.Add("${key}:$($Values[$key])")
    }
    $partial = "$Path.$([guid]::NewGuid()).partial"
    try {
        [IO.File]::WriteAllLines($partial, $lines)
        [IO.File]::Move($partial, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
    }
}

$operation = [IO.File]::Open((Join-Path $Root '.operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    if ($Action -in 'Stage', 'InstallPacks') {
        foreach ($id in $lock.files.Keys) {
            Save-PinnedFile $lock.files[$id] $(if ($id -eq 'patrix') { $PatrixZip }) | Out-Null
        }
    }
    if ($Action -eq 'Stage') {
        Write-Output "Verified archives: $cache"
        return
    }
    if (!(Test-Path -LiteralPath (Join-Path $cache $lock.files.launcher.name))) {
        throw 'Run Stage before using this action'
    }

    $archive = Save-PinnedFile $lock.files.launcher
    $tools = Join-Path $Root 'tools'
    [IO.Directory]::CreateDirectory($tools) | Out-Null
    $exe = Join-Path $tools "horizon-launcher-$($lock.files.launcher.version).exe"
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entries = @($zip.Entries | Where-Object Name -ceq 'horizon-launcher.exe')
        if ($entries.Count -ne 1) { throw 'Expected one Windows launcher executable' }
        $stream = $entries[0].Open()
        try { $launcherHash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash }
        finally { $stream.Dispose() }
        if (!(Test-Path -LiteralPath $exe)) {
            $partial = "$exe.$([guid]::NewGuid()).partial"
            try {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $partial)
                if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -cne $launcherHash) {
                    throw 'The extracted launcher hash differs from the pinned archive'
                }
                [IO.File]::Move($partial, $exe)
            } finally {
                if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
            }
        }
        if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -cne $launcherHash) {
            throw "The extracted launcher hash differs from the pinned archive: $exe"
        }
    } finally {
        $zip.Dispose()
    }

    $previousLauncherHome = $env:HORIZON_LAUNCHER_HOME
    $previousGameHome = $env:HORIZON_HOME
    $env:HORIZON_LAUNCHER_HOME = Join-Path $Root 'launcher-data'
    $env:HORIZON_HOME = Join-Path $Root 'game-data'
    try {
        $found = @((& $exe instance list --json | ConvertFrom-Json) | Where-Object name -ceq $name)
        if ($found.Count -gt 1) { throw 'Ambiguous pack instance' }
        if (!$found.Count) {
            if ($Action -ne 'InstallPacks') { throw 'Run InstallPacks first' }
            $instance = & $exe instance create $name --json | ConvertFrom-Json
        } else {
            $instance = $found[0]
        }
        $homePath = [IO.Path]::GetFullPath($instance.home)
        $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($instance.kind -ne 'own' -or !$homePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Launcher did not return an isolated Horizon instance'
        }

        if ($Action -eq 'OpenLauncher') {
            & $exe instance select $instance.id | Out-Null
            Start-Process -FilePath $exe
            return
        }

        if ($Action -eq 'InstallBase') {
            Install-PinnedBase $env:HORIZON_LAUNCHER_HOME
            $versions = & $exe versions --installed --json | ConvertFrom-Json
            if ($lock.importBase.tag -cnotin $versions.installed) { throw 'Launcher did not discover the pinned base' }
            Write-Output "Installed Horizon base: $($lock.importBase.tag)"
            return
        }

        if ($Action -eq 'ImportClient') {
            if (!$ClientArtifact -or !$TrustHostedClient) {
                throw 'Supply -ClientArtifact and -TrustHostedClient after verifying the artifact origin'
            }
            $artifact = [IO.Path]::GetFullPath($ClientArtifact)
            $artifactLock = Get-Content -Raw -LiteralPath (Join-Path $artifact 'pack.lock.json') | ConvertFrom-Json -AsHashtable
            if (($artifactLock | ConvertTo-Json -Compress -Depth 12) -cne ($lock | ConvertTo-Json -Compress -Depth 12)) {
                throw 'Hosted client was built against a different pack lock'
            }
            $checksum = (Get-Content -Raw -LiteralPath (Join-Path $artifact 'SHA256SUMS')).Trim()
            if ($checksum -cnotmatch '^([a-f0-9]{64})  horizon-client\.exe$') { throw 'Invalid hosted client checksum' }
            $expected = $Matches[1]
            $client = Join-Path $artifact 'horizon-client.exe'
            if ((Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash -ine $expected) {
                throw 'Hosted client checksum mismatch'
            }
            Install-PinnedBase $env:HORIZON_LAUNCHER_HOME
            $import = & $exe import-build $client --version $lock.importBase.tag --trust-unsigned --json | ConvertFrom-Json
            if ($import.imported -cnotmatch '^imported-[0-9-]+-[a-f0-9]+$') { throw 'Unexpected imported version tag' }
            $installedClient = Join-Path $env:HORIZON_LAUNCHER_HOME 'versions' $import.imported 'horizon-client.exe'
            if ((Get-FileHash -LiteralPath $installedClient -Algorithm SHA256).Hash -ine $expected) {
                throw 'Imported client checksum mismatch'
            }
            & $exe instance version $instance.id $import.imported | Out-Null
            Write-Output "Imported client for $($instance.id): $($import.imported)"
            return
        }

        if ($Action -eq 'Backup') {
            if (!$World) { throw 'Supply the world name or folder with -World' }
            & $exe worlds backup $World --instance $instance.id
            return
        }
        if ($Action -eq 'InstallPacks') {
            foreach ($id in $lock.files.Keys) {
                if ($id -in 'launcher', 'tectonic_horizon') { continue }
                $path = Join-Path $cache $lock.files[$id].name
                $folder = if ($id -eq 'patrix') { 'resourcepacks' } else { 'shaderpacks' }
                $installed = Join-Path $homePath $folder $lock.files[$id].name
                if (Test-Path -LiteralPath $installed) {
                    Assert-PinnedFile $installed $lock.files[$id]
                } else {
                    & $exe packs add $path --instance $instance.id | Out-Null
                    Assert-PinnedFile $installed $lock.files[$id]
                }
            }
            & $exe packs on $lock.files.patrix.name --kind resource --instance $instance.id | Out-Null
            & $exe settings install-new-versions off | Out-Null
            & $exe settings prune-old-versions off | Out-Null
        }

        $selection = $lock.profiles[$Profile]
        $shader = $selection.shader
        Assert-PinnedFile (Join-Path $homePath 'shaderpacks' $lock.files[$shader].name) $lock.files[$shader]
        & $exe packs on $lock.files[$shader].name --kind shader --instance $instance.id | Out-Null
        Set-ProfileOptions (Join-Path $homePath 'options.txt') $selection.options
        Set-ProfileOptions (Join-Path $homePath 'horizon-graphics.txt') $selection.graphics
        Write-Output "Instance: $($instance.id)"
        Write-Output "Game directory: $homePath"
        Write-Output "Profile shader: $($lock.files[$shader].name)"
        Write-Output "Launcher: $exe"
    } finally {
        $env:HORIZON_LAUNCHER_HOME = $previousLauncherHome
        $env:HORIZON_HOME = $previousGameHome
    }
} finally {
    $operation.Dispose()
}
