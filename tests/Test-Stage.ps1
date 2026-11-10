#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$project = Split-Path $PSScriptRoot
$install = Join-Path $project 'Install.ps1'
$lock = Get-Content -Raw -LiteralPath (Join-Path $project 'pack.lock.json') | ConvertFrom-Json -AsHashtable
if ($lock.minecraft -ne '26.3' -or $lock.horizon -cnotmatch '^[a-f0-9]{40}$' -or $lock.mixins -cnotmatch '^[a-f0-9]{40}$') {
    throw 'Invalid engine or Minecraft pins'
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) "horizon-stage-test-$([guid]::NewGuid())"
$root = Join-Path $scratch 'instance'
$cache = Join-Path $root 'downloads'
[IO.Directory]::CreateDirectory($cache) | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $root '.horizon-vanillapp') -Value 'horizon-vanillapp-v1'
    Copy-Item -LiteralPath $install -Destination $scratch
    foreach ($entry in $lock.files.Values) {
        if ($entry.url -cnotmatch '^https://(github\.com|cdn\.modrinth\.com)/' -or
            $entry.name -cne [IO.Path]::GetFileName($entry.name) -or
            $entry.size -le 0 -or
            ($entry.algorithm -eq 'SHA256' -and $entry.hash -cnotmatch '^[a-f0-9]{64}$') -or
            ($entry.algorithm -eq 'SHA512' -and $entry.hash -cnotmatch '^[a-f0-9]{128}$') -or
            $entry.algorithm -notin 'SHA256', 'SHA512') {
            throw "Invalid asset pin: $($entry.name)"
        }
        $path = Join-Path $cache $entry.name
        [IO.File]::WriteAllText($path, $entry.name)
        $entry.size = (Get-Item -LiteralPath $path).Length
        $entry.hash = (Get-FileHash -LiteralPath $path -Algorithm $entry.algorithm).Hash
    }
    $lock | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $scratch 'pack.lock.json')
    & (Join-Path $scratch 'Install.ps1') -Root $root -Action Stage

    $path = Join-Path $cache $lock.files.patrix.name
    [IO.File]::WriteAllText($path, ('x' * $lock.files.patrix.size))
    $rejected = $false
    try { & (Join-Path $scratch 'Install.ps1') -Root $root -Action Stage }
    catch {
        if ($_.Exception.Message -notlike 'Incorrect hash for *') { throw }
        $rejected = $true
    }
    if (!$rejected) { throw 'Stage accepted a modified cache file of the expected size' }
    Write-Output 'Stage cache and hash rejection passed'
} finally {
    $tmpPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::GetFullPath($scratch).StartsWith($tmpPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $scratch -Leaf) -match '^horizon-stage-test-[0-9a-f-]{36}$') {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
