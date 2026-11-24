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
# Magick.Native names each library it links in Stdafx.h; the two left out are not built, so not linked either.
$stdafx = Join-Path $native 'src\Magick.Native\Stdafx.h'
$header = Get-Content $stdafx -Raw
foreach ($name in $LeftOut) {
    $header = $header -replace "(?m)^[ \t]*MAGICK_NATIVE_LINK_LIB\($([regex]::Escape($name))\)[ \t]*\r?\n", ''
    if ($header -match "MAGICK_NATIVE_LINK_LIB\($([regex]::Escape($name))\)") { throw "Stdafx.h still links $name" }
}
[IO.File]::WriteAllText($stdafx, $header)
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
    # Their plugins, those this libheif has: ImageMagick's Configure refuses an excluded path that isn't there
    # (libheif 1.23.6 has no OpenH264 encoder).
    if ($line -eq '[EXCLUDES]') {
        foreach ($plugin in @('decoder_libde265.cc', 'decoder_openh264.cc', 'encoder_openh264.cc')) {
            if (Test-Path (Join-Path $deps "Dependencies\heif\libheif\plugins\$plugin")) { "libheif\plugins\$plugin" }
        }
    }
}
Set-Content $config $kept
Write-Host "libheif's configuration:"; Get-Content $config | Write-Host

# The value under a [SECTION] of a Config.txt, or '' when the section isn't there.
function Section([string[]]$lines, [string]$name) {
    $at = [array]::IndexOf($lines, "[$name]")
    if ($at -lt 0 -or $at + 1 -ge $lines.Count) { return '' }
    $value = $lines[$at + 1].Trim()
    if ($value -match '^\[.+\]$') { return '' }
    $value
}
function Archive([string]$repo, [string]$prefix, [string]$file) {
    & git -C $repo archive --format=tar.gz --prefix=$prefix -o $file HEAD
    if ($LASTEXITCODE -ne 0) { throw "git archive of $repo failed ($LASTEXITCODE)" }
}

# Before the hour-long build: each library's licence file, as its Config.txt names it, and the exact sources
# of the LGPL libraries. A library without its licence file, or under the GPL (which DropWheel can't ship),
# stops the build here.
$package = Join-Path $out 'magick-native-15.0.0-dropwheel-win64'
$sources = Join-Path $out 'sources'
New-Item -ItemType Directory -Force (Join-Path $package 'licenses'), $sources | Out-Null
$summary = @()
foreach ($dir in Get-ChildItem (Join-Path $deps 'Dependencies') -Directory) {
    $cfg = Join-Path $dir.FullName '.ImageMagick\Config.txt'
    if (-not (Test-Path $cfg)) { continue }
    $c = @(Get-Content $cfg)
    # jpeg-turbo-12 and -16 build jpeg-turbo's own source again at other sample sizes: theirs is its licence.
    $builds = Section $c 'DIRECTORY'
    if ($builds) { $summary += "$($dir.Name) builds $builds"; continue }
    $licenceFile = Section $c 'LICENSE_FILE'
    $identifier = Section $c 'LICENSE_IDENTIFIER'
    $version = Section $c 'VERSION'
    if (-not $licenceFile) { throw "$($dir.Name) names no licence file" }
    if (-not $identifier) { throw "$($dir.Name) names no licence" }
    if ($identifier -match '(^|[^L])GPL') { throw "$($dir.Name) is under $identifier, which DropWheel can't ship" }
    $commit = (& git -C $dir.FullName rev-parse HEAD)
    $summary += "$($dir.Name) $(if ($version) { $version } else { '?' }) $identifier $commit"
    $target = Join-Path $package "licenses\$($dir.Name)"
    New-Item -ItemType Directory -Force $target | Out-Null
    foreach ($file in ($licenceFile -split ',')) {
        $from = Join-Path $dir.FullName $file.Trim()
        if (-not (Test-Path $from)) { throw "$($dir.Name)'s licence file $($file.Trim()) isn't there" }
        Copy-Item $from $target -Recurse
    }
    # The LGPL and the MPL (cairo) both ask for the source of what is shipped.
    if ($identifier -match 'LGPL|MPL') { Archive $dir.FullName "$($dir.Name)/" (Join-Path $sources "$($dir.Name)-source.tar.gz") }
}
$summary | Set-Content (Join-Path $package 'libraries.txt')
Write-Host 'Libraries:'; $summary | Write-Host
Copy-Item (Join-Path $im 'ImageMagick\LICENSE') (Join-Path $package 'licenses\ImageMagick.txt')
Copy-Item (Join-Path $native 'License.txt') (Join-Path $package 'licenses\Magick.Native.txt')
Archive (Join-Path $im 'ImageMagick') 'ImageMagick/' (Join-Path $sources 'ImageMagick-source.tar.gz')
Archive $native 'Magick.Native/' (Join-Path $sources 'Magick.Native-source.tar.gz')

# The build, as Magick.Native's own workflow runs it.
Run cmd.exe @('/c', 'build.cmd', 'Release', 'Q8', 'x64', 'noHdri', 'noOpenMP') (Join-Path $native 'build\windows')
$dll = Get-ChildItem $native -Recurse -Filter 'Magick.Native-Q8-x64.dll' | Where-Object { $_.FullName -match 'Release' } | Select-Object -First 1
if (-not $dll) { throw 'Magick.Native-Q8-x64.dll was not built' }

# No HEVC or H.264 codec in it (the names and API symbols DropWheel's build.ps1 also looks for), and no FFTW,
# an optional dependency under the GPL that must never be linked in.
$text = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($dll.FullName))
# libheif's message for a picture it has no decoder for names "libde265" and "openh264", each a string of its own,
# as decoders to install (codecs/decoder.cc, missing_decoder_error_message): those two words are text, not code.
# Any other place these names, or the codecs' own names and symbols, are found stops the build.
$scanned = $text.Replace("`0libde265`0", "`0`0").Replace("`0openh264`0", "`0`0")
$held = @()
foreach ($mark in @('libde265', 'de265_', 'openh264', 'WelsCreate', 'x265_', 'kvazaar', 'kvz_', 'fftw')) {
    $at = $scanned.IndexOf($mark, [StringComparison]::OrdinalIgnoreCase)
    while ($at -ge 0) {
        $from = [Math]::Max(0, $at - 40)
        $around = ($scanned.Substring($from, [Math]::Min(100, $scanned.Length - $from)) -replace '[^\x20-\x7E]', '.')
        Write-Host "$mark at $at`: $around"
        $held += $mark
        $at = $scanned.IndexOf($mark, $at + 1, [StringComparison]::OrdinalIgnoreCase)
    }
}
if ($held) { throw "The DLL still holds $(($held | Select-Object -Unique) -join ', ')" }
Copy-Item $dll.FullName $package
Copy-Item $config (Join-Path $package 'heif-Config.txt')
@(
    "Magick.Native $NativeCommit (Magick.NET 15.0.0), built for DropWheel by build.ps1 in https://github.com/yahyaabohashem332/dropwheel-magick.",
    "ImageMagick $MagickCommit; its libraries from ImageMagick/Dependencies $DependenciesCommit, each at the commit in libraries.txt.",
    "Left out: libde265 (HEVC) and OpenH264 (H.264); libheif reads and writes AVIF through aom, and HEIC no more.",
    "The sources of ImageMagick, Magick.Native and the LGPL and MPL libraries: magick-native-15.0.0-dropwheel-win64-source.tar.gz beside this build."
) | Set-Content (Join-Path $package 'BUILD.txt')
Copy-Item (Join-Path $package 'BUILD.txt'), (Join-Path $package 'libraries.txt') $sources
Copy-Item (Join-Path $here 'build.ps1'), (Join-Path $here 'README.md') $sources

Compress-Archive -Path $package -DestinationPath (Join-Path $out 'magick-native-15.0.0-dropwheel-win64.zip') -Force
& tar -czf (Join-Path $out 'magick-native-15.0.0-dropwheel-win64-source.tar.gz') -C $out sources
# Checksums of what is published, for fetch-tools.ps1 to pin.
Get-ChildItem $out -File | Where-Object { $_.Name -like '*.zip' -or $_.Name -like '*-source.tar.gz' } | ForEach-Object {
    "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)  $($_.Name)"
} | Set-Content (Join-Path $out 'SHA256SUMS.txt')
if ($env:GITHUB_OUTPUT) { "package=magick-native-15.0.0-dropwheel-win64" | Add-Content $env:GITHUB_OUTPUT }
