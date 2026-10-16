# test-passthrough-e2e.ps1 - v3.12: botao PassBtn (🡒) liga o modo passthrough
# (GateConfirm aprova tudo). Tem que: (1) ligar e logar 'chrome: passthrough True',
# (2) um file_write rodar SEM dialogo de confirmacao mas COM 'pass: aprovado' no log,
# (3) gravar o arquivo certo, (4) desligar no fim (config volta a false).
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
function Click-Btn($win, [string]$id) {
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    if (-not $el) { throw "botao $id nao achado" }
    $r = $el.Current.BoundingRectangle
    $null = [K.I]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
    [K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 400
    return $el
}

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

# 1) liga o passthrough
$mark = [IO.File]::ReadAllText($log).Length
$null = Click-Btn $win 'PassBtn'
$deadline = (Get-Date).AddSeconds(10); $on = $false
while ((Get-Date) -lt $deadline -and -not $on) {
    Start-Sleep -Milliseconds 400
    if ((Read-New $mark) -match 'chrome: passthrough True') { $on = $true }
}
if (-not $on) { throw 'pass: clique no PassBtn nao ligou (chrome: passthrough True ausente)' }
'pass: ligado (log confirmado)'

# 2) turno com file_write: tem que rodar SEM dialogo e COM pass: aprovado
$testFile = 'C:\Users\EVTU-DELL\.local\bin\zquick\pass-test.txt'
Remove-Item $testFile -ErrorAction SilentlyContinue
$mark2 = [IO.File]::ReadAllText($log).Length
$inCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')
$input = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $inCond)
if (-not $input) { throw 'InputBox nao achado' }
$input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("Use file_write para criar o arquivo $testFile com o conteudo exato: teste-passthrough-ok")
$r = $input.Current.BoundingRectangle
$null = [K.I]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
[K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 300
Tap 0x0D
'enviado'

$done = $false; $pass = $false; $err = $false
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline -and -not $done) {
    Start-Sleep -Milliseconds 800
    $t = Read-New $mark2
    if ($t -match 'engine: HTTP') { $err = $true; "ERRO HTTP: $($Matches[0])"; break }
    if ($t -match 'pass: aprovado') { $pass = $true; 'pass: aprovado apareceu no log' }
    if ($t -match 'respondido: (\d+) chars') { $done = $true; "respondido: $($Matches[1]) chars" }
}
if ($err) { throw 'erro HTTP no turno' }
if (-not $done) { throw 'sem respondido em 120s' }
if (-not $pass) { throw 'pass: aprovado NAO apareceu — bypass ou filtro de log falhou' }
if ((Read-New $mark2) -match 'confirma:') { throw 'apareceu confirma: — passthrough nao pulou o dialogo' }
'pass: nenhum dialogo de confirmacao'

# 3) arquivo gravado certo?
if (-not (Test-Path $testFile)) { throw 'arquivo pass-test.txt nao foi criado' }
$content = [IO.File]::ReadAllText($testFile).Trim()
"arquivo criado, conteudo: $content"
if ($content -ne 'teste-passthrough-ok') { throw "conteudo inesperado: $content" }

# 4) desliga o passthrough (estado final seguro)
$mark3 = [IO.File]::ReadAllText($log).Length
$null = Click-Btn $win 'PassBtn'
$deadline = (Get-Date).AddSeconds(10); $off = $false
while ((Get-Date) -lt $deadline -and -not $off) {
    Start-Sleep -Milliseconds 400
    if ((Read-New $mark3) -match 'chrome: passthrough False') { $off = $true }
}
if (-not $off) { throw 'pass: segundo clique nao desligou' }
Remove-Item $testFile -ErrorAction SilentlyContinue

# limpeza: nova conversa + esconde
Combo 0x11 0x4E; Start-Sleep -Milliseconds 400; Tap 0x1B
"VERDICTO: OK (liga -> file_write sem dialogo com pass: no log -> arquivo certo -> desligado)"
