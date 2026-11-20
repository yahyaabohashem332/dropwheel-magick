<#
.SYNOPSIS
  Builds the Magick.Native that DropWheel ships with Magick.NET 15.0.0: the same native library, without the
  two codecs still under patent that it otherwise carries, libde265 (an HEVC decoder) and OpenH264 (an H.264
  codec). HEIC photos are read and written by Windows' own codecs in DropWheel instead; AVIF stays, with aom.

.DESCRIPTION
  Every source is pinned: Magick.Native at the release Magick.NET 15.0.0 was built with, ImageMagick at the
  commit that release names, and ImageMagick's own copies of its libraries at the commits its Dependencies
  repository named that day. The package holds the DLL, each library's licence file, the configuration, and
  the exact sources of the LGPL libraries inside it with the scripts that built them.

.EXAMPLE
  pwsh ./build.ps1 -Output out
#>
param([string]$Output = 'out')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$out = [IO.Path]::GetFullPath((Join-Path $here $Output))
$work = Join-Path $env:RUNNER_TEMP 'magick'
if (-not $env:RUNNER_TEMP) { $work = Join-Path ([IO.Path]::GetTempPath()) 'magick' }

$NativeRepo = 'https://github.com/dlemstra/Magick.Native.git'
$NativeCommit = '4dcdad28530c14c8d35687fdeb1ecc8d39b01e30'     # tag 2026.1010.1943, Magick.NET 15.0.0's
$MagickCommit = '211e5b975a0019a88dcef5f84c1193f46738d815'     # src/ImageMagick/ImageMagick.commit at that tag
$DependenciesCommit = '1e18a4be8125d061c9925594628836bd33a45538' # ImageMagick/Dependencies, 2026-10-10
# The codecs left out, and the libraries of ImageMagick's that would bring them.
$LeftOut = @('de265', 'openh264')

function Run([string]$exe, [string[]]$arguments, [string]$where) {
    Push-Location $where
    try {
        & $exe @arguments
        if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') failed ($LASTEXITCODE)" }
    }
    finally { Pop-Location }
}

if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force $work, $out | Out-Null
$bash = (Get-Command bash -ErrorAction Stop).Source

# Magick.Native and ImageMagick at their commits.
Run git @('clone', '-q', $NativeRepo, 'Magick.Native') $work
$native = Join-Path $work 'Magick.Native'
Run git @('checkout', '-q', $NativeCommit) $native
$im = Join-Path $native 'src\ImageMagick'
Run git @('clone', '-q', 'https://github.com/ImageMagick/ImageMagick.git', 'ImageMagick') $im
Run git @('checkout', '-q', $MagickCommit) (Join-Path $im 'ImageMagick')
Run $bash @('-c', './ImageMagick/.github/build/windows/download-configure.sh') $im

# ImageMagick's copies of its libraries, from source, all but the two left out.
Run git @('clone', '-q', 'https://github.com/ImageMagick/Dependencies.git', 'Dependencies') $im
$deps = Join-Path $im 'Dependencies'
Run git @('checkout', '-q', $DependenciesCommit) $deps
$clone = Join-Path $deps 'clone-dependencies.sh'
$script = Get-Content $clone -Raw
foreach ($name in $LeftOut) { $script = $script -replace "(?m)^\s*clone '$([regex]::Escape($name))' '[0-9a-f]+'\r?\n", '' }
[IO.File]::WriteAllText($clone, $script.Replace("`r`n", "`n"))
Run $bash @('-c', './clone-dependencies.sh windows') $deps
foreach ($name in $LeftOut) {
    if (Test-Path (Join-Path $deps "Dependencies\$name")) { throw "$name was cloned all the same" }
}

# libheif without them: no defines that call them, their two plugins excluded, no reference to their projects.
$config = Join-Path $deps 'Dependencies\heif\.ImageMagick\Config.txt'
$lines = Get-Content $config
$section = ''
$kept = foreach ($line in $lines) {
    if ($line -match '^\[(.+)\]$') { $section = $Matches[1] }
    if ($section -eq 'DEFINES' -and $line -in @('HAVE_LIBDE265', 'HAVE_OpenH264_DECODER', 'LIBDE265_STATIC_BUILD')) { continue }
    if ($section -eq 'REFERENCES' -and $line -in $LeftOut) { continue }
    $line
    if ($line -eq '[EXCLUDES]') { 'libheif\plugins\decoder_libde265.cc'; 'libheif\plugins\decoder_openh264.cc'; 'libheif\plugins\encoder_openh264.cc' }
}
Set-Content $config $kept
Write-Host "libheif's configuration:"; Get-Content $config | Write-Host

# The build, as Magick.Native's own workflow runs it.
Run cmd.exe @('/c', 'build.cmd', 'Release', 'Q8', 'x64', 'noHdri', 'noOpenMP') (Join-Path $native 'build\windows')
$dll = Get-ChildItem $native -Recurse -Filter 'Magick.Native-Q8-x64.dll' | Where-Object { $_.FullName -match 'Release' } | Select-Object -First 1
if (-not $dll) { throw 'Magick.Native-Q8-x64.dll was not built' }

# Nothing of the two left in it.
$text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dll.FullName))
foreach ($mark in @('libde265', 'de265_', 'openh264', 'WelsCreateDecoder', 'WelsCreateSVCEncoder')) {
    if ($text.Contains($mark)) { throw "The DLL still holds $mark" }
}

$package = Join-Path $out 'magick-native-15.0.0-dropwheel-win64'
New-Item -ItemType Directory -Force (Join-Path $package 'licenses') | Out-Null
Copy-Item $dll.FullName $package

# Each library's licence file, as its Config.txt names it, and the LGPL libraries' sources.
$sources = Join-Path $out 'sources'
New-Item -ItemType Directory -Force $sources | Out-Null
$summary = @()
foreach ($dir in Get-ChildItem (Join-Path $deps 'Dependencies') -Directory) {
    $cfg = Join-Path $dir.FullName '.ImageMagick\Config.txt'
    if (-not (Test-Path $cfg)) { continue }
    $c = Get-Content $cfg
    $licenceFile = ($c[([array]::IndexOf($c, '[LICENSE_FILE]') + 1)]).Trim()
    $identifier = if ($c -contains '[LICENSE_IDENTIFIER]') { ($c[([array]::IndexOf($c, '[LICENSE_IDENTIFIER]') + 1)]).Trim() } else { '?' }
    $version = if ($c -contains '[VERSION]') { ($c[([array]::IndexOf($c, '[VERSION]') + 1)]).Trim() } else { '?' }
    $commit = (& git -C $dir.FullName rev-parse HEAD)
    $summary += "$($dir.Name) $version $identifier $commit"
    $target = Join-Path $package "licenses\$($dir.Name)"
    New-Item -ItemType Directory -Force $target | Out-Null
    foreach ($file in ($licenceFile -split ',')) {
        $from = Join-Path $dir.FullName $file.Trim()
        if (Test-Path $from) { Copy-Item $from $target -Recurse }
    }
    if ($identifier -match 'LGPL|GPL') {
        & git -C $dir.FullName archive --format=tar.gz --prefix="$($dir.Name)/" -o (Join-Path $sources "$($dir.Name)-source.tar.gz") HEAD
    }
}
$summary | Set-Content (Join-Path $package 'libraries.txt')
Copy-Item (Join-Path $im 'ImageMagick\LICENSE') (Join-Path $package 'licenses\ImageMagick.txt')
Copy-Item (Join-Path $native 'License.txt') (Join-Path $package 'licenses\Magick.Native.txt')
& git -C (Join-Path $im 'ImageMagick') archive --format=tar.gz --prefix=ImageMagick/ -o (Join-Path $sources 'ImageMagick-source.tar.gz') HEAD
& git -C $native archive --format=tar.gz --prefix=Magick.Native/ -o (Join-Path $sources 'Magick.Native-source.tar.gz') HEAD
Copy-Item $config (Join-Path $package 'heif-Config.txt')
@(
    "Magick.Native $NativeCommit (Magick.NET 15.0.0), built for DropWheel by build.ps1 in https://github.com/yahyaabohashem332/dropwheel-magick.",
    "ImageMagick $MagickCommit; its libraries from ImageMagick/Dependencies $DependenciesCommit, each at the commit in libraries.txt.",
    "Left out: libde265 (HEVC) and OpenH264 (H.264); libheif reads and writes AVIF through aom, and HEIC no more.",
    "The sources of ImageMagick, Magick.Native and the LGPL libraries: magick-native-15.0.0-dropwheel-win64-source.tar.gz beside this build."
) | Set-Content (Join-Path $package 'BUILD.txt')
Copy-Item (Join-Path $package 'BUILD.txt'), (Join-Path $package 'libraries.txt') $sources
Copy-Item (Join-Path $here 'build.ps1'), (Join-Path $here 'README.md') $sources

Compress-Archive -Path $package -DestinationPath (Join-Path $out 'magick-native-15.0.0-dropwheel-win64.zip') -Force
& tar -czf (Join-Path $out 'magick-native-15.0.0-dropwheel-win64-source.tar.gz') -C $out sources
if ($env:GITHUB_OUTPUT) { "package=magick-native-15.0.0-dropwheel-win64" | Add-Content $env:GITHUB_OUTPUT }
