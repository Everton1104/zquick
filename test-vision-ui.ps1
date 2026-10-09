# test-vision-ui.ps1 — E2E de visao pela UI REAL (rodar com pwsh -STA):
# clipboard com PNG marcado -> Alt+Q -> Ctrl+V (anexo) -> pergunta -> Enter -> log.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, System.Drawing
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
function Tap([byte]$vk) {
    [K.I]::keybd_event($vk,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
    [K.I]::keybd_event($vk,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
}
function Combo([byte]$mod,[byte]$vk) {
    [K.I]::keybd_event($mod,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($vk,0,0,[UIntPtr]::Zero);  Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($vk,0,2,[UIntPtr]::Zero);  Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($mod,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 200
}

# 1. PNG de teste -> clipboard (mesmo formato que a Ferramenta de Captura entrega)
$bmp = [System.Drawing.Bitmap]::new(460, 120)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$g.SmoothingMode = 'AntiAlias'
$font = [System.Drawing.Font]::new('Arial', 30, [System.Drawing.FontStyle]::Bold)
$brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(20, 90, 200))
$g.DrawString('ZQUICK-99-UI', $font, $brush, [single]15, [single]38)
$g.Dispose()
$ms = [System.IO.MemoryStream]::new()
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$ms.Position = 0
$frame = [System.Windows.Media.Imaging.BitmapFrame]::Create($ms, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
[System.Windows.Clipboard]::SetImage($frame)
'imagem no clipboard'

$log = Join-Path $env:TEMP 'zquick.log'
$off = [IO.File]::ReadAllText($log).Length

# 2. abre, cola, pergunta, envia
Combo 0x12 0x51                       # Alt+Q
Start-Sleep -Milliseconds 900
Combo 0x11 0x56                       # Ctrl+V -> anexa imagem
Start-Sleep -Milliseconds 900
foreach ($ch in 'o que esta escrito na imagem'.ToCharArray()) {
    if ($ch -eq ' ') { Tap 0x20 }
    else { Tap ([byte][int][char]::ToUpper($ch)) }
    Start-Sleep -Milliseconds 25
}
Start-Sleep -Milliseconds 400
Tap 0x0D                              # Enter
'pergunta com imagem enviada, aguardando...'

# 3. fiscaliza o log
$deadline = (Get-Date).AddSeconds(120); $verdict = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $new = [IO.File]::ReadAllText($log).Substring($off)
    if ($new -match 'respondido: (\d+) chars em (\d+)s \| (.+)')  { $verdict = "RESPONDIDO ($($Matches[1]) chars em $($Matches[2])s): $($Matches[3])"; break }
    if ($new -match 'engine: (.+)')  { $verdict = "ERRO ENGINE: $($Matches[1])"; break }
    if ($new -match 'FATAL')         { $verdict = 'FATAL: ' + $new; break }
}
if (-not $verdict) { $verdict = 'TIMEOUT (120s)' }
Combo 0x11 0x4E                       # Ctrl+N
Start-Sleep -Milliseconds 500
Tap 0x1B                              # Esc
$verdict
'--- log novo ---'
[IO.File]::ReadAllText($log).Substring($off)
