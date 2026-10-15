# test-top-ui.ps1 — v3.9: 📌 sempre no topo + Ctrl+roda = opacidade ao vivo.
#   fase 1: clique no 📌 (UIA) -> WindowPattern.IsTopmost True + log 'chrome: topmost True' + json alwaysOnTop
#   fase 2: clique de novo -> IsTopmost False + json false
#   fase 3: cursor no centro da janela + Ctrl + roda p/ baixo 2 notchs -> opacidade 80% -> 70%
#           (log 'opacidade salva 70% (Ctrl+roda)' + json) ; roda p/ cima volta a 80%
#   fase 4: MESMO Ctrl+roda com o dialogo ⚙ aberto, cursor sobre o dialogo (v3.9.1)
#   finally: restaura zquick.json original + restart
# Rodar com: pwsh -STA -File test-top-ui.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int dwData, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$cfgFile = Join-Path $PSScriptRoot 'zquick.json'
$bakFile = Join-Path $env:TEMP 'zquick.tbak.json'

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
function Read-LogText {
    for ($i = 0; $i -lt 10; $i++) {
        try { return [IO.File]::ReadAllText($log) } catch { Start-Sleep -Milliseconds 150 }
    }
    throw 'log travado para leitura'
}
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        try { $new = (Read-LogText).Substring($mark) } catch { $new = '' }
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 500
    }
    return ''
}
function Get-AppProc {
    $app = Get-CimInstance Win32_Process -Filter "Name LIKE 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' -and $_.ProcessId -ne $PID } | Select-Object -First 1
    if (-not $app) { throw 'processo zquick nao achado' }
    $app
}
function Get-MainWin([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    foreach ($w in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($w.Current.Name -like '*ZQuick*' -and $w.Current.Name -notlike '*hist*' -and $w.Current.Name -notlike '*configura*') { return $w }
    }
    $null
}
function Show-Main([int]$procId) {
    for ($try = 0; $try -lt 5; $try++) {
        $w = Get-MainWin $procId
        if ($w -and -not $w.Current.IsOffscreen) { return $w }
        Combo 0x12 0x51
        Start-Sleep -Milliseconds 800
    }
    throw 'janela principal nao ficou visivel'
}
function Find-ById($win, [string]$id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}
function Invoke-Btn($win, [string]$id) {
    $b = Find-ById $win $id
    if (-not $b) { throw "botao $id nao achado" }
    $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Restart-App {
    $mark = (Read-LogText).Length
    $null = schtasks /End /TN ZQuick 2>$null
    Start-Sleep -Milliseconds 1200
    Get-CimInstance Win32_Process -Filter "Name LIKE 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 1200
    $null = schtasks /Run /TN ZQuick
    if (-not (Wait-Log $mark 'hotkey .* -> True' 45)) { throw 'app nao reiniciou (sem hotkey no log)' }
    Start-Sleep -Milliseconds 600
}
function Get-IsTopmost($mainWin) {
    $mainWin.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.IsTopmost
}
function Get-SettingsWin($mainWin) {
    foreach ($w in @($mainWin.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))) {
        if ($w.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $w.Current.Name -like '*configura*') { return $w }
    }
    $null
}
function Send-CtrlWheel([int]$notches) {
    # cursor no centro da janela; Ctrl pressionado + roda (120/notch)
    [K.I]::keybd_event(0x11,0,0,[UIntPtr]::Zero)
    for ($i = 0; $i -lt [Math]::Abs($notches); $i++) {
        $d = $(if ($notches -gt 0) { 120 } else { -120 })
        [K.I]::mouse_event(0x0800, 0, 0, $d, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 120
    }
    [K.I]::keybd_event(0x11,0,2,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}

Copy-Item $cfgFile $bakFile -Force
try {
    # estado deterministico: topmost off, opacidade 0.8
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    $j | Add-Member -NotePropertyName alwaysOnTop -NotePropertyValue $false -Force
    $j.windowOpacity = 0.8
    $j | ConvertTo-Json -Depth 6 | Set-Content $cfgFile -Encoding utf8
    Restart-App
    $app = Get-AppProc
    $w = Show-Main $app.ProcessId
    if (Get-IsTopmost $w) { throw 'boot: topmost deveria estar OFF' }
    'boot: topmost OFF, opacidade 80%'

    #### fase 1: liga o 📌 ####
    $m = (Read-LogText).Length
    Invoke-Btn $w 'TopBtn'
    if (-not (Wait-Log $m 'chrome: topmost True' 10)) { throw 'fase1: sem log topmost True' }
    Start-Sleep -Milliseconds 400
    $w = Show-Main $app.ProcessId
    if (-not (Get-IsTopmost $w)) { throw 'fase1: WindowPattern nao viu IsTopmost' }
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if (-not [bool]$j.alwaysOnTop) { throw 'fase1: json nao gravou alwaysOnTop true' }
    'fase1: 📌 ligou — IsTopmost True + json gravado'

    #### fase 2: desliga ####
    $m = (Read-LogText).Length
    Invoke-Btn $w 'TopBtn'
    if (-not (Wait-Log $m 'chrome: topmost False' 10)) { throw 'fase2: sem log topmost False' }
    Start-Sleep -Milliseconds 400
    $w = Show-Main $app.ProcessId
    if (Get-IsTopmost $w) { throw 'fase2: ainda topmost' }
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if ([bool]$j.alwaysOnTop) { throw 'fase2: json nao voltou a false' }
    'fase2: 📌 desligou — IsTopmost False + json false'

    #### fase 3: Ctrl+roda = opacidade ####
    $r = $w.Current.BoundingRectangle
    $null = [K.I]::SetCursorPos([int]($r.Left + $r.Width / 2), [int]($r.Top + $r.Height / 2))
    Start-Sleep -Milliseconds 300
    $m = (Read-LogText).Length
    Send-CtrlWheel -2
    if (-not (Wait-Log $m 'opacidade salva 70% \(Ctrl\+roda\)' 15)) { throw "fase3: sem log opacidade 70%: $((Read-LogText).Substring($m) -split "`n" | Select-Object -Last 5)" }
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if ([Math]::Abs([double]$j.windowOpacity - 0.7) -gt 0.011) { throw "fase3: json opacity = $($j.windowOpacity)" }
    'fase3: Ctrl+roda baixo — opacidade 80% -> 70% + json gravado'
    $m = (Read-LogText).Length
    Send-CtrlWheel 2
    if (-not (Wait-Log $m 'opacidade salva 80% \(Ctrl\+roda\)' 15)) { throw 'fase3: sem log opacidade 80% (volta)' }
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if ([Math]::Abs([double]$j.windowOpacity - 0.8) -gt 0.011) { throw "fase3: json opacity volta = $($j.windowOpacity)" }
    'fase3: Ctrl+roda cima — voltou a 80%'

    #### fase 4: Ctrl+roda com o dialogo ⚙ aberto (cursor SOBRE o dialogo) ####
    $m = (Read-LogText).Length
    Invoke-Btn $w 'SettingsBtn'
    $null = Wait-Log $m 'config: dialogo' 10
    $sd = $null
    for ($try = 0; $try -lt 10 -and -not $sd; $try++) {
        $w = Show-Main $app.ProcessId
        $sd = Get-SettingsWin $w
        if (-not $sd) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $sd) { throw 'fase4: dialogo ⚙ nao abriu' }
    $r = $sd.Current.BoundingRectangle
    $null = [K.I]::SetCursorPos([int]($r.Left + $r.Width / 2), [int]($r.Top + $r.Height / 2))
    Start-Sleep -Milliseconds 300
    $m = (Read-LogText).Length
    Send-CtrlWheel -2
    if (-not (Wait-Log $m 'opacidade salva 70% \(Ctrl\+roda\)' 15)) { throw "fase4: roda sobre o ⚙ nao salvou: $((Read-LogText).Substring($m) -split "`n" | Select-Object -Last 5)" }
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if ([Math]::Abs([double]$j.windowOpacity - 0.7) -gt 0.011) { throw "fase4: json opacity = $($j.windowOpacity)" }
    'fase4: Ctrl+roda SOBRE o dialogo ⚙ — 80% -> 70% + json gravado'
    $m = (Read-LogText).Length
    Send-CtrlWheel 2
    if (-not (Wait-Log $m 'opacidade salva 80% \(Ctrl\+roda\)' 15)) { throw 'fase4: sem log 80% (volta)' }
    Tap 0x1B
    Start-Sleep -Milliseconds 700
    'fase4: voltou a 80% com o ⚙ ainda aberto; Esc fechou o dialogo'
} finally {
    if (Test-Path $bakFile) { Copy-Item $bakFile $cfgFile -Force; Remove-Item $bakFile -Force -Confirm:$false }
    Restart-App
    'restaurado: json original de volta, app reiniciado'
}
'TOP-OPACITY OK'
