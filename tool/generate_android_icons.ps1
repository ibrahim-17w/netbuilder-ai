# Generates the Android launcher icons from the app icon the desktop build
# uses (assets/app_icon.png - the same art as windows/runner/resources/
# app_icon.ico), so every platform ships one logo.
#
# Outputs (all committed, so CI never needs to run this):
#   android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
#     48 / 72 / 96 / 144 / 192 px - the legacy launcher icon.
#   android/app/src/main/res/drawable-*/ic_launcher_foreground.png
#     108 / 162 / 216 / 324 / 432 px canvases with the art at 66% -
#     the adaptive-icon foreground (the launcher mask shows the middle
#     72 of 108 dp, so 66% keeps the whole logo visible in any mask).
#   android/app/src/main/res/values/ic_launcher_background.xml
#     The adaptive background: sampled from the art's edge so the mask
#     shape blends seamlessly with the rounded square.
#   android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
#
# Run from the repo root:  powershell -File tool/generate_android_icons.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$srcPath = Join-Path $root 'assets/app_icon.png'
$res = Join-Path $root 'android/app/src/main/res'

Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Bitmap]::new($srcPath)
try {
    if ($src.Width -ne 512 -or $src.Height -ne 512) {
        throw "assets/app_icon.png must be 512x512, found $($src.Width)x$($src.Height)"
    }

    function Save-Resized([System.Drawing.Bitmap]$image, [int]$size, [string]$path) {
        $target = [System.Drawing.Bitmap]::new($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($target)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.DrawImage($image, 0, 0, $size, $size)
        } finally {
            $g.Dispose()
        }
        $dir = Split-Path -Parent $path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $target.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $target.Dispose()
        Write-Output "wrote $path ($size px)"
    }

    # --- legacy launcher icon, one per density -------------------------------
    $legacy = @{
        'mipmap-mdpi'    = 48
        'mipmap-hdpi'    = 72
        'mipmap-xhdpi'   = 96
        'mipmap-xxhdpi'  = 144
        'mipmap-xxxhdpi' = 192
    }
    foreach ($entry in $legacy.GetEnumerator()) {
        Save-Resized $src $entry.Value (Join-Path $res "$($entry.Key)/ic_launcher.png")
    }

    # --- adaptive-icon foreground: the art at 66% on a transparent canvas ----
    $foreground = @{
        'drawable'          = 108
        'drawable-mdpi'     = 108
        'drawable-hdpi'     = 162
        'drawable-xhdpi'    = 216
        'drawable-xxhdpi'   = 324
        'drawable-xxxhdpi'  = 432
    }
    foreach ($entry in $foreground.GetEnumerator()) {
        $canvas = $entry.Value
        $art = [int][Math]::Round($canvas * 0.66)
        $pad = [int](($canvas - $art) / 2)
        $target = [System.Drawing.Bitmap]::new($canvas, $canvas)
        $g = [System.Drawing.Graphics]::FromImage($target)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.DrawImage($src, $pad, $pad, $art, $art)
        } finally {
            $g.Dispose()
        }
        $path = Join-Path $res "$($entry.Key)/ic_launcher_foreground.png"
        $dir = Split-Path -Parent $path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $target.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $target.Dispose()
        Write-Output "wrote $path ($canvas px canvas, art $art px)"
    }

    # --- adaptive background: the average color of the art's border row ------
    $totalR = 0L; $totalG = 0L; $totalB = 0L
    for ($x = 0; $x -lt 512; $x++) {
        foreach ($y in 2, 509) {
            $p = $src.GetPixel($x, $y)
            if ($p.A -gt 0) {
                $totalR += $p.R; $totalG += $p.G; $totalB += $p.B
            }
        }
    }
    $bgHex = '#{0:X2}{1:X2}{2:X2}' -f [int]($totalR / 1024), [int]($totalG / 1024), [int]($totalB / 1024)
    $colorXml = Join-Path $res 'values/ic_launcher_background.xml'
    @"
<?xml version="1.0" encoding="utf-8"?>
<!-- The adaptive-icon background, sampled from the edge of
     assets/app_icon.png by tool/generate_android_icons.ps1 so the
     launcher mask blends with the logo's own dark plate. -->
<resources>
    <color name="ic_launcher_background">$bgHex</color>
</resources>
"@ | Set-Content -Path $colorXml -Encoding UTF8
    Write-Output "wrote $colorXml (background $bgHex)"
} finally {
    $src.Dispose()
}

# --- adaptive icon definition (Android 8+) -----------------------------------
$anyDpi = Join-Path $res 'mipmap-anydpi-v26'
if (-not (Test-Path $anyDpi)) { New-Item -ItemType Directory -Path $anyDpi | Out-Null }
$adaptive = @'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
'@
$adaptive | Set-Content -Path (Join-Path $anyDpi 'ic_launcher.xml') -Encoding UTF8
Write-Output "wrote $(Join-Path $anyDpi 'ic_launcher.xml')"
Write-Output 'Android launcher icons generated.'
