# probe-repaint.ps1 — manda /uitest repaint (sentinelas EM MEMORIA, sem tocar no
# config) e devolve as 3 linhas do log: antes / sentinela / volta. Se logo, NewBtn
# e ProfileBox aparecem com FFB300/5C3A00/26313B na linha "sent", a varredura
# Update-ThemeLive funciona.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
Add-Type -Namespace K -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
function Read-LogText {
    $fs = [IO.FileStream]::new($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        try { $new = (Read-LogText).Substring($mark) } catch { $new = '' }
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 400
    }
    return ''
}
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
function Find-ById($win, [string]$id) {
    for ($t = 0; $t -lt 6; $t++) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
            return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        } catch { Start-Sleep -Milliseconds 700 }
    }
    throw "UIA timeout '$id'"
}
$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$app.ProcessId)
$w = $null
for ($try = 0; $try -lt 6 -and -not $w; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    foreach ($cand in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($cand.Current.Name -like '*ZQuick*' -and $cand.Current.Name -notlike '*hist*' -and (Find-ById $cand 'InputBox')) { $w = $cand }
    }
}
if (-not $w) { throw 'janela nao acessivel' }

$mark = (Read-LogText).Length
$tb = Find-ById $w 'InputBox'
$tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('/uitest repaint')
$p = $tb.GetClickablePoint()
$null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y); Start-Sleep -Milliseconds 80
[K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 200
Tap 0x0D
$hit = Wait-Log $mark 'repaint volta' 20
if (-not $hit) { throw "repaint nao completou. log: $((Read-LogText).Substring($mark))" }
$hit -split "`n" | Where-Object { $_ -match 'repaint (antes|sent|volta)|themelive|comboitem' }
'probe fim'
