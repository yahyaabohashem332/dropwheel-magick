# Magick.Native for DropWheel

The native library of Magick.NET 15.0.0 (Magick.Native-Q8-x64.dll) as DropWheel ships it, built by `build.ps1` on
GitHub Actions: the same library as Magick.NET's own, from the same sources, without libde265 (an HEVC decoder)
and OpenH264 (an H.264 codec), whose formats are still under patent. DropWheel reads and writes HEIC photos with
Windows' own codecs instead; libheif keeps AVIF, through aom.

Each release holds the DLL with every library's licence file (`licenses/`), `libraries.txt` (each library's
version, licence and commit), the libheif configuration it was built with, and a source archive with the exact
sources of ImageMagick, Magick.Native and the LGPL and MPL libraries inside the DLL, with the scripts that built them.

Every run of the workflow publishes a release of its own, `v15.0.0-dropwheel.<run>`, with `SHA256SUMS.txt`;
DropWheel's `fetch-tools.ps1` pins one by those checksums. The build stops before compiling if a library has no
licence file or is under the GPL, and after it if the DLL holds libde265, OpenH264, x265, kvazaar or FFTW.
