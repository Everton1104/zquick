# test-mtbump-e2e.ps1 - v3.11.1: rodada cortada por max_tokens SEM nada util
# (thinking come o limite) tem que ser REFEITA com teto maior (8192+) e responder,
# em vez de encerrar "pronto" com resposta vazia. Forca deterministica:
# maxTokens=1 no zquick.json -> 1a rodada sempre corta -> retry com 8192 -> texto.
# ASCII-only (5.1/ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
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
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }

# config: maxTokens=1 (o teste anterior a chamada deve ter gravado isso)
$mt = (Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json' -Raw | ConvertFrom-Json).maxTokens
"maxTokens no json: $mt (esperado 1)"
if ($mt -ne 1) { throw 'rode com maxTokens=1 no zquick.json antes deste teste' }

$app = Get-Process zquick -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }
$procId = $app.Id; "pid: $procId"
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
$win = $null
for ($try = 0; $try -lt 4 -and -not $win; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    $win = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
}
if (-not $win) { throw 'janela nao achada' }
'janela ok'

$mark = [IO.File]::ReadAllText($log).Length
$inCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')
$input = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $inCond)
if (-not $input) { throw 'InputBox nao achado' }
$input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('responda apenas: ok')
$r = $input.Current.BoundingRectangle
$null = [K.I]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
[K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 300
Tap 0x0D
'enviado'

$done = $false; $sawRetry = $false; $sawErr = $false; $nChars = -1
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline -and -not $done) {
    Start-Sleep -Milliseconds 700
    $t = Read-New $mark
    if ($t -match 'engine: HTTP') { $sawErr = $true; "ERRO HTTP: $($Matches[0])"; break }
    if ($t -match 'repetindo com (\d+)') { $sawRetry = $true; "retry disparou com $($Matches[1]) tokens" }
    if ($t -match 'respondido: (\d+) chars') { $nChars = [int]$Matches[1]; $done = $true; "respondido: $($Matches[1]) chars" }
}
if ($sawErr) { throw 'erro HTTP no turno' }
if (-not $done) { throw 'sem respondido em 120s' }
if (-not $sawRetry) { throw 'retry de max_tokens NAO disparou (corte nao detectado?)' }
if ($nChars -lt 1) { throw "resposta vazia ($nChars chars) apos retry" }

Combo 0x11 0x4E; Start-Sleep -Milliseconds 400; Tap 0x1B
"VERDICTO: OK (corte max_tokens -> retry com teto maior -> resposta de $($nChars) chars)"
