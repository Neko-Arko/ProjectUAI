$ErrorActionPreference = 'Stop'
$release = Join-Path $PSScriptRoot 'release'
$evidence = Join-Path $PSScriptRoot '.build/verification'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$manifest = Get-Content -LiteralPath (Join-Path $release 'desktop-release.json') -Raw | ConvertFrom-Json
$exe = [IO.Path]::GetFullPath((Join-Path $release $manifest.package.name))
if (!$exe.StartsWith([IO.Path]::GetFullPath($release) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid release path' }
if ((Get-Item -LiteralPath $exe).Length -ne $manifest.package.bytes -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.package.sha256) { throw 'Executable release hash mismatch' }

# Copy just the executable to prove it has no neighboring file dependencies.
$standalone = Join-Path $evidence ('standalone-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $standalone -Force | Out-Null
$isolated = Join-Path $standalone 'Cowork.exe'
Copy-Item -LiteralPath $exe -Destination $isolated
foreach ($mode in @('self-test','startup-test','smoke-test','window-test')) {
    $result = Join-Path $evidence ($mode + '.json')
    $process = Start-Process -FilePath $isolated -ArgumentList @('--' + $mode,('"' + $result + '"')) -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(60000)) { Stop-Process -Id $process.Id -Force; throw "Desktop $mode exceeded 60 seconds." }
    if ($process.ExitCode -ne 0) { Get-Content -LiteralPath $result -ErrorAction SilentlyContinue; throw "Desktop $mode failed." }
    Get-Content -LiteralPath $result
}
if (@(Get-ChildItem -LiteralPath $standalone -Force).Count -ne 1) { throw 'App wrote files beside the standalone executable' }
foreach ($size in @('normal', 'compact', 'narrow')) {
    $preview = Join-Path $evidence $(if ($size -eq 'normal') { 'launcher.png' } else { 'launcher-' + $size + '.png' })
    $mode = if ($size -eq 'normal') { '--render-preview' } else { '--render-preview-' + $size }
    $process = Start-Process -FilePath $isolated -ArgumentList @($mode,('"' + $preview + '"')) -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(20000)) { Stop-Process -Id $process.Id -Force; throw 'Desktop preview exceeded 20 seconds.' }
    if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $preview)) { throw 'Desktop preview failed.' }
    Write-Output "Inspect native window preview: $preview"
    if ($size -eq 'narrow') {
        $bottomPreview = Join-Path $evidence 'launcher-narrow-bottom.png'
        if (!(Test-Path -LiteralPath $bottomPreview)) { throw 'Desktop narrow bottom preview failed.' }
        Write-Output "Inspect native window preview: $bottomPreview"
    }
}
Write-Output 'Standalone executable verified without neighboring runtime or bridge folders.'
