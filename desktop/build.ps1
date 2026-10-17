param([string]$Dotnet = 'dotnet')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$desktopRoot = $PSScriptRoot
$repoRoot = Split-Path $desktopRoot -Parent
$cache = Join-Path $desktopRoot '.cache'
$release = Join-Path $desktopRoot 'release'
$stage = Join-Path $desktopRoot ('.build/' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'payload'
$publish = Join-Path $stage 'publish'
$version = ([xml](Get-Content -LiteralPath (Join-Path $desktopRoot 'src/UaiBridge/UaiBridge.csproj') -Raw)).Project.PropertyGroup.Version
$asset = Join-Path $release "UAI-Bridge-$version-win-x64.exe"
$utf8 = [Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path $cache,$release,$stage,$payload,$publish -Force | Out-Null
$dotnetCommand = (Get-Command $Dotnet -ErrorAction Stop).Source
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

# Bridge and client files are embedded in the executable, not shipped beside it.
# Node is detected/downloaded at runtime. OpenCode is detected from an existing
# installation. Neither executable is added to this payload.
New-Item -ItemType Directory -Path (Join-Path $payload 'bridge'),(Join-Path $payload 'client'),(Join-Path $payload 'licenses') -Force | Out-Null
foreach ($file in @('server.js','inference.js','opencode.js','support.js','mcp.js','mcp-stdio.js','picture-store.js','launcher.js','release.js','updater.js','supervisor.js')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "bridge/$file") -Destination (Join-Path $payload "bridge/$file")
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'bridge/web') -Destination (Join-Path $payload 'bridge/web') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'dist/uai.lua') -Destination (Join-Path $payload 'client/uai.lua')
Copy-Item -LiteralPath (Join-Path $desktopRoot 'START-HERE.txt') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $payload 'licenses/Project-UAI-LICENSE.txt')
$dotnetRoot = Split-Path $dotnetCommand -Parent
foreach ($name in @('LICENSE.txt','ThirdPartyNotices.txt')) {
    if (!(Test-Path -LiteralPath (Join-Path $dotnetRoot $name))) { throw "Missing .NET redistribution notice: $name" }
    Copy-Item -LiteralPath (Join-Path $dotnetRoot $name) -Destination (Join-Path $payload "licenses/Dotnet-$name")
}
$files = @(Get-ChildItem -LiteralPath $payload -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = $_.FullName.Substring($payload.Length + 1).Replace('\','/'); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$inventory = [ordered]@{ product = 'UAI Bridge'; version = $version; platform = 'win-x64'; node = 'detected-or-downloaded'; opencode = 'external-installation-only'; files = $files }
[IO.File]::WriteAllText((Join-Path $payload 'manifest.json'), ($inventory | ConvertTo-Json -Depth 5), $utf8)
Add-Type -AssemblyName System.IO.Compression
$payloadArchive = Join-Path $stage 'payload.zip'
# CreateFromDirectory stores Windows backslash separators, which never match
# the forward-slash inventory. Write entries explicitly so every build uses
# canonical forward-slash names on any host OS.
$archiveStream = [IO.File]::Open($payloadArchive, [IO.FileMode]::CreateNew)
try {
    $zip = New-Object IO.Compression.ZipArchive($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($item in $files) {
            $entry = $zip.CreateEntry($item.path, [IO.Compression.CompressionLevel]::Optimal)
            $source = [IO.File]::OpenRead((Join-Path $payload ($item.path.Replace('/', [IO.Path]::DirectorySeparatorChar))))
            $destination = $entry.Open()
            try { $source.CopyTo($destination) } finally { $destination.Close(); $source.Close() }
        }
        $manifestBytes = [IO.File]::ReadAllBytes((Join-Path $payload 'manifest.json'))
        $manifestEntry = $zip.CreateEntry('manifest.json', [IO.Compression.CompressionLevel]::Optimal)
        $manifestOut = $manifestEntry.Open()
        try { $manifestOut.Write($manifestBytes, 0, $manifestBytes.Length) } finally { $manifestOut.Close() }
    } finally { $zip.Dispose() }
} finally { $archiveStream.Close() }

$icon = Join-Path $cache 'app.ico'
& (Join-Path $desktopRoot 'make-icon.ps1') -Destination $icon
& $dotnetCommand publish (Join-Path $desktopRoot 'src/UaiBridge/UaiBridge.csproj') -c Release -r win-x64 --self-contained true -o $publish -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:ApplicationIcon=$icon -p:BridgePayload=$payloadArchive
if ($LASTEXITCODE -ne 0) { throw 'Desktop publish failed.' }
Copy-Item -LiteralPath (Join-Path $publish 'UAI Bridge.exe') -Destination $asset -Force
$digest = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
"$digest  $([IO.Path]::GetFileName($asset))" | Set-Content -LiteralPath ($asset + '.sha256') -Encoding ASCII
$manifest = [ordered]@{ format = 'project-uai-desktop-release'; schema = 1; version = $version; platform = 'win-x64'; protocol = 1;
    package = [ordered]@{ name = [IO.Path]::GetFileName($asset); bytes = (Get-Item -LiteralPath $asset).Length; sha256 = $digest } }
[IO.File]::WriteAllText((Join-Path $release 'desktop-release.json'), ($manifest | ConvertTo-Json -Depth 5), $utf8)
Write-Output "Built standalone $asset"
Write-Output "Embedded $($files.Count) bridge/client/license files; Node.js and OpenCode CLI are not bundled."
Write-Output "Inspect $payload and desktop-release.json before running desktop/verify.ps1."
