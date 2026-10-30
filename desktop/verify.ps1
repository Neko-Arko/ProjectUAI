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
foreach ($mode in @('self-test','startup-test','smoke-test','window-test','update-test')) {
    $result = Join-Path $evidence ($mode + '.json')
    # The update test restarts real helper, parent and candidate windows for
    # three scenarios; it needs a wider deadline than the offline checks.
    $deadline = if ($mode -eq 'update-test') { 240000 } else { 60000 }
    $process = Start-Process -FilePath $isolated -ArgumentList @('--' + $mode,('"' + $result + '"')) -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit($deadline)) { Stop-Process -Id $process.Id -Force; throw "Desktop $mode exceeded $($deadline / 1000) seconds." }
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
    if ($size -eq 'normal') {
        foreach ($page in @('connections', 'updates', 'settings', 'tunnels', 'tunnels-bottom')) {
            $pagePreview = Join-Path $evidence ("launcher-$page.png")
            if (!(Test-Path -LiteralPath $pagePreview)) { throw "Desktop $page preview failed." }
            Write-Output "Inspect native WPF page preview: $pagePreview"
        }
    }
    if ($size -eq 'narrow') {
        $bottomPreview = Join-Path $evidence 'launcher-narrow-bottom.png'
        if (!(Test-Path -LiteralPath $bottomPreview)) { throw 'Desktop narrow bottom preview failed.' }
        Write-Output "Inspect native window preview: $bottomPreview"
        foreach ($suffix in @('tunnels', 'tunnels-bottom')) {
            $tunnelPreview = Join-Path $evidence ("launcher-narrow-$suffix.png")
            if (!(Test-Path -LiteralPath $tunnelPreview)) { throw "Desktop narrow $suffix preview failed." }
            Write-Output "Inspect native WPF tunnel preview: $tunnelPreview"
        }
    }
}
Write-Output 'Standalone executable verified without neighboring runtime or bridge folders.'
