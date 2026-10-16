# test-v313-passtrebtn.ps1 - v3.13: botao de passthrough agora com raio;
# toggle tem que logar True/False (sem turno de API). ASCII-only.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
function Combo([byte]$mod,[byte]$vk) {
    [K.I]::keybd_event($mod,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($vk,0,0,[UIntPtr]::Zero);  Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($vk,0,2,[UIntPtr]::Zero);  Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($mod,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 200
}
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }
$procId = (Get-Process zquick | Select-Object -First 1).Id
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
$win = $null
for ($try = 0; $try -lt 4 -and -not $win; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    $win = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
}
if (-not $win) { throw 'janela nao achada' }
$c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PassBtn')
$btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
if (-not $btn) { throw 'PassBtn nao achado' }
"conteudo do botao: $($btn.Current.Name)"
if ($btn.Current.Name -notmatch [string][char]0x26A1) { throw 'botao nao esta com o raio' }
$r = $btn.Current.BoundingRectangle
function Click-Btn { $null = [K.I]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2)); [K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 600 }
$mark = [IO.File]::ReadAllText($log).Length
Click-Btn
$ok1 = $false; $dl = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $dl -and -not $ok1) { Start-Sleep -Milliseconds 300; if ((Read-New $mark) -match 'chrome: passthrough True') { $ok1 = $true } }
if (-not $ok1) { throw 'clique 1 nao ligou' }
'raio: ligou (True no log)'
$mark = [IO.File]::ReadAllText($log).Length
Click-Btn
$ok2 = $false; $dl = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $dl -and -not $ok2) { Start-Sleep -Milliseconds 300; if ((Read-New $mark) -match 'chrome: passthrough False') { $ok2 = $true } }
if (-not $ok2) { throw 'clique 2 nao desligou' }
'raio: desligou (False no log)'
"VERDICTO: OK (raio visivel + toggle True/False)"
