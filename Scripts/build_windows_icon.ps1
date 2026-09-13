param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$source = [System.Drawing.Image]::FromFile((Join-Path $PSScriptRoot "../Icon.icon/Assets/codexbar.png"))
$images = @()
try {
    foreach ($size in @(16, 20, 24, 32, 40, 48, 64, 256)) {
        $bitmap = [System.Drawing.Bitmap]::new($size, $size)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $stream = [IO.MemoryStream]::new()
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($source, 0, 0, $size, $size)
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $images += @{ Size = $size; Bytes = $stream.ToArray() }
        } finally {
            $stream.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
} finally {
    $source.Dispose()
}
$iconPath = Join-Path $OutputDirectory "codexbar.ico"
$writer = [IO.BinaryWriter]::new([IO.File]::Create($iconPath))
try {
    $writer.Write([UInt16]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($image in $images) {
        $dimension = if ($image.Size -eq 256) { 0 } else { $image.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$image.Bytes.Length)
        $writer.Write([UInt32]$offset)
        $offset += $image.Bytes.Length
    }
    foreach ($image in $images) { $writer.Write([byte[]]$image.Bytes) }
} finally {
    $writer.Dispose()
}
$resourcePath = Join-Path $OutputDirectory "codexbar.rc"
$escapedIconPath = $iconPath.Replace('\', '\\')
$manifestPath = (Join-Path $PSScriptRoot "windows-tray.manifest").Replace('\', '\\')
# Link the manifest with the icon. Post-link mt.exe rewriting invalidates this Swift PE's COFF table.
Set-Content $resourcePath @(
    '#include <windows.h>'
    ('1 ICON "' + $escapedIconPath + '"')
    ('CREATEPROCESS_MANIFEST_RESOURCE_ID RT_MANIFEST "' + $manifestPath + '"')
) -Encoding ascii

$providerIcons = Join-Path $PSScriptRoot 'WindowsProviderIcons'
foreach ($providerIcon in Get-ChildItem $providerIcons -Filter '*.ico' | Sort-Object Name) {
    $path = $providerIcon.FullName.Replace('\', '\\')
    $resourceName = ('PROVIDER_' + $providerIcon.BaseName.Replace('-', '_')).ToUpperInvariant()
    Add-Content $resourcePath ($resourceName + ' ICON "' + $path + '"') -Encoding ascii
}
& rc.exe /nologo /fo (Join-Path $OutputDirectory "codexbar.res") $resourcePath
if ($LASTEXITCODE -ne 0) { throw "Windows provider icon resource compilation failed." }
