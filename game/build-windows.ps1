# Build a single-file Windows x64 release. Build tools: GCC and windres (MinGW).
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$work = Join-Path ([IO.Path]::GetTempPath()) ('hr-kill-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work, $dist -Force | Out-Null
function Download-File($uri, $destination) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $destination
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Warning "Download failed; retrying ($attempt/3): $uri"
        }
    }
}
function Run-Native($exe, $arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe failed ($LASTEXITCODE)" }
}
try {
    $gcc = (Get-Command gcc -ErrorAction Stop).Source
    $windres = (Get-Command windres -ErrorAction Stop).Source
    $launcher = Join-Path $PSScriptRoot 'packaging/launcher.c'
    if (-not (Test-Path -LiteralPath $launcher)) { throw "Missing launcher source: $launcher" }
    $runtimeZip = Join-Path $work 'love.zip'
    Download-File 'https://github.com/love2d/love/releases/download/11.4/love-11.4-win64.zip' -destination $runtimeZip
    $unpack = Join-Path $work 'download'
    New-Item -ItemType Directory -Path $unpack | Out-Null
    Expand-Archive -LiteralPath $runtimeZip -DestinationPath $unpack
    $runtime = Join-Path $unpack 'love-11.4-win64'
    $stage = Join-Path $work 'game'
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'main.lua'), (Join-Path $PSScriptRoot 'conf.lua') -Destination $stage
    Copy-Item (Join-Path $PSScriptRoot 'src') -Destination $stage -Recurse
    $fonts = Join-Path $stage 'assets/fonts'
    New-Item -ItemType Directory -Path $fonts -Force | Out-Null
    Download-File 'https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf' -destination (Join-Path $fonts 'NotoSansCJKsc-Regular.otf')
    Download-File 'https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/LICENSE' -destination (Join-Path $fonts 'LICENSE.txt')
    $loveFile = Join-Path $work 'game.love'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $loveFile)
    $gameExe = Join-Path $runtime 'HRKill.exe'
    $output = [IO.File]::Create($gameExe)
    try {
        foreach ($part in @((Join-Path $runtime 'love.exe'), $loveFile)) {
            $inputStream = [IO.File]::OpenRead($part)
            try { $inputStream.CopyTo($output) } finally { $inputStream.Dispose() }
        }
    } finally { $output.Dispose() }
    # Retain the runtime's DLLs and license; the launcher embeds the entire folder.
    Remove-Item (Join-Path $runtime 'love.exe')
    $payload = Join-Path $work 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($runtime, $payload)
    $resource = Join-Path $work 'payload.rc'
    $resourcePath = $payload.Replace('\', '/')
    [IO.File]::WriteAllText($resource, "101 RCDATA `"$resourcePath`"`n")
    $object = Join-Path $work 'payload.o'
    Run-Native $windres @('-i', $resource, '-o', $object, '-O', 'coff')
    $release = Join-Path $dist 'HRKill-Windows-x64.exe'
    Run-Native $gcc @('-O2', '-Wall', '-Wextra', '-municode', '-mwindows', '-static', (Join-Path $PSScriptRoot 'packaging/launcher.c'), $object, '-lshell32', '-o', $release)
    Get-Item $release | Select-Object FullName, Length
    Get-FileHash $release -Algorithm SHA256
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
