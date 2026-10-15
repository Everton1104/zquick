# test-font-ui.ps1 — v3.8: escala GLOBAL de fonte (answerFontSize 13 = 100% da interface).
#   1. boot com fonte 13 -> mede altura fisica do SendBtn e do titulo "ZQuick" (UIA BoundingRectangle)
#   2. dialogo ⚙ -> Aparencia -> tamanho 18 -> Aplicar -> log 'fontscale: 100% -> 138%'
#      e os elementos da janela principal crescem ao vivo (sem reabrir)
#   3. volta pra 13 -> log 'fontscale: 138% -> 100%' e alturas voltam ~ao original
#   finally: restaura zquick.json original + restart
# Rodar com: pwsh -STA -File test-font-ui.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$cfgFile = Join-Path $PSScriptRoot 'zquick.json'
$bakFile = Join-Path $env:TEMP 'zquick.fbak.json'

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
function Set-Value($win, [string]$id, [string]$val) {
    $e = Find-ById $win $id
    if (-not $e) { throw "elemento $id nao achado" }
    $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($val)
}
function Select-Tab($dlg, [string]$name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $tab = $dlg.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $tab) { throw "aba $name nao achada" }
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 500
}
function Get-SettingsWin($mainWin) {
    foreach ($w in @($mainWin.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))) {
        if ($w.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $w.Current.Name -like '*configura*') { return $w }
    }
    $null
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
function Get-TitleH($mainWin) {
    # titulo "⚡ ZQuick": TextBlock sem padding -> altura = pura altura de linha da fonte
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, '⚡ ZQuick')
    $t = $mainWin.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $t) { throw 'titulo ZQuick nao achado' }
    [double]$t.Current.BoundingRectangle.Height
}

Copy-Item $cfgFile $bakFile -Force
try {
    #### boot limpo com fonte 13 (escala 100%) ####
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    $j.answerFontSize = 13
    $j | ConvertTo-Json -Depth 6 | Set-Content $cfgFile -Encoding utf8
    Restart-App
    $app = Get-AppProc
    $w = Show-Main $app.ProcessId
    $send0 = [double](Find-ById $w 'SendBtn').Current.BoundingRectangle.Height
    $tit0  = Get-TitleH $w
    "boot 13: SendBtn=$([math]::Round($send0,1))px  titulo=$([math]::Round($tit0,1))px"

    #### aplica 18 ao vivo ####
    $m = (Read-LogText).Length
    Invoke-Btn $w 'SettingsBtn'
    $null = Wait-Log $m 'config: dialogo' 10
    $sd = $null
    for ($try = 0; $try -lt 10 -and -not $sd; $try++) {
        $w = Show-Main $app.ProcessId
        $sd = Get-SettingsWin $w
        if (-not $sd) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $sd) { throw 'dialogo ⚙ nao abriu' }
    Select-Tab $sd 'Aparência'
    Set-Value $sd 'SetFontSize' '18'
    Start-Sleep -Milliseconds 300
    $m = (Read-LogText).Length
    Invoke-Btn $sd 'SetApply'
    $new = Wait-Log $m 'fontscale: ' 15
    if (-not $new) { throw 'sem linha fontscale no log apos Aplicar' }
    if ($new -notmatch 'fontscale: 100% -> 138%') { throw "log inesperado: $($new -split "`n" | Select-String fontscale)" }
    'aplicou 18: log fontscale 100% -> 138%'
    Tap 0x1B
    Start-Sleep -Milliseconds 700
    # re-adquire janela (nao stale) e mede de novo
    $w = Show-Main $app.ProcessId
    $send1 = [double](Find-ById $w 'SendBtn').Current.BoundingRectangle.Height
    $tit1  = Get-TitleH $w
    $rS = $send1 / $send0; $rT = $tit1 / $tit0
    "apos 18: SendBtn=$([math]::Round($send1,1))px (x$([math]::Round($rS,2)))  titulo=$([math]::Round($tit1,1))px (x$([math]::Round($rT,2)))"
    if ($rT -lt 1.25) { throw "titulo cresceu só x$([math]::Round($rT,2)) — escala nao aplicou ao vivo" }
    if ($rS -lt 1.12) { throw "SendBtn cresceu só x$([math]::Round($rS,2))" }

    #### volta pra 13 ####
    $m = (Read-LogText).Length
    Invoke-Btn $w 'SettingsBtn'
    $sd = $null
    for ($try = 0; $try -lt 10 -and -not $sd; $try++) {
        $w = Show-Main $app.ProcessId
        $sd = Get-SettingsWin $w
        if (-not $sd) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $sd) { throw 'dialogo ⚙ nao reabriu' }
    Select-Tab $sd 'Aparência'
    Set-Value $sd 'SetFontSize' '13'
    Start-Sleep -Milliseconds 300
    $m = (Read-LogText).Length
    Invoke-Btn $sd 'SetApply'
    $null = Wait-Log $m 'fontscale: 138% -> 100%' 15
    Tap 0x1B
    Start-Sleep -Milliseconds 700
    $w = Show-Main $app.ProcessId
    $tit2 = Get-TitleH $w
    if ([Math]::Abs($tit2 - $tit0) -gt 3) { throw "titulo nao voltou: $([math]::Round($tit2,1)) vs $([math]::Round($tit0,1))" }
    "voltou 13: titulo=$([math]::Round($tit2,1))px (~original) — OK"
} finally {
    if (Test-Path $bakFile) { Copy-Item $bakFile $cfgFile -Force; Remove-Item $bakFile -Force -Confirm:$false }
    Restart-App
    'restaurado: json original de volta, app reiniciado'
}
'FONT-SCALE OK'
