# Build do zquick.exe — RODE COM Windows PowerShell 5.1:
#   powershell -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1
# Gera zquick.exe (GUI, STA, sem console, icone Z) + zquick.ico na mesma pasta.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $dir 'tools\ps2exe\ps2exe.psd1')

Add-Type -AssemblyName System.Drawing
$ico = Join-Path $dir 'zquick.ico'
if (-not (Test-Path $ico)) {
    $sz = 32
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $rect = New-Object System.Drawing.Rectangle(0, 0, $sz, $sz)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(139, 124, 246), [System.Drawing.Color]::FromArgb(99, 88, 200), [single]45)
    $g.FillRectangle($brush, $rect)
    $font = New-Object System.Drawing.Font('Segoe UI', [single]17, [System.Drawing.FontStyle]::Bold)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.DrawString('Z', $font, $white, [single]7, [single]2)
    $g.Dispose(); $brush.Dispose(); $white.Dispose(); $font.Dispose()
    $ic = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $fs = [System.IO.File]::Create($ico)
    $ic.Save($fs)
    $fs.Close()
    "icone: $ico"
}

Invoke-PS2EXE -inputFile (Join-Path $dir 'zquick.ps1') -outputFile (Join-Path $dir 'zquick.exe') `
    -noConsole -STA -iconFile $ico -title 'ZQuick' -description 'Busca rapida com LLM' -version '1.0.0' -DPIAware

Get-Item (Join-Path $dir 'zquick.exe') | ForEach-Object { "exe: {0} ({1:N0} bytes)" -f $_.FullName, $_.Length }
