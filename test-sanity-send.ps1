# test-sanity-send.ps1 — envio real via UIA: espera respondido sem engine: HTTP (401 etc.)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$procId = (Get-Process zquick | Select-Object -First 1).Id
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
$win = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
if (-not $win) { throw 'janela nao achada' }
$mark = [IO.File]::ReadAllText($log).Length
$inCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')
$input = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $inCond)
$input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('responda apenas: ok')
$r = $input.Current.BoundingRectangle
$null = [K.I]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
[K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 300
[K.I]::keybd_event(0x0D,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45; [K.I]::keybd_event(0x0D,0,2,[UIntPtr]::Zero)
$done = $false; $err = $false
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline -and -not $done) {
    Start-Sleep -Milliseconds 700
    try { $t = [IO.File]::ReadAllText($log).Substring($mark) } catch { continue }
    if ($t -match 'engine: HTTP') { $err = $true; "ERRO HTTP: $($Matches[0])"; break }
    if ($t -match 'respondido: (\d+) chars') { $done = $true; "RESPONDEU: $($Matches[1]) chars — sem erro HTTP" }
}
# limpeza: nova conversa + esconde
[K.I]::keybd_event(0x11,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 70
[K.I]::keybd_event(0x4E,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 70
[K.I]::keybd_event(0x4E,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 70
[K.I]::keybd_event(0x11,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 300
[K.I]::keybd_event(0x1B,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45; [K.I]::keybd_event(0x1B,0,2,[UIntPtr]::Zero)
if (-not $done -and -not $err) { throw 'sem resposta em 90s' }
'VERDICTO: OK'
