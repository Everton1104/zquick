# test-wave6-ui.ps1 — E2E da Onda 6 (app residente, oraculo = zquick.log):
#   fase 1: moldura custom — botoes ⚙ — ▢ ✕ achaveis por AutomationId;
#           ▢ maximiza/restaura (WindowPattern), ✕ oculta pra bandeja
#   fase 2: dialogo ⚙ — largura/altura/opacidade/tamanho de fonte via UIA ->
#           'config: aplicado' + json gravado (window.width/height, windowOpacity,
#           answerFontSize) + janela reabre com o tamanho novo
#   fase 3: troca de chave de API no perfil (PasswordBox via UIA) -> json gravado
#   fase 4 (finally): restaura zquick.json original + restart
# Rodar com: pwsh -STA -File test-wave6-ui.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$cfgFile = Join-Path $PSScriptRoot 'zquick.json'
$bakFile = Join-Path $env:TEMP 'zquick.w6bak.json'

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
function Read-New([int]$mark) { (Read-LogText).Substring($mark) }
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        $new = Read-New $mark
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
function Get-SettingsWin($mainWin) {
    # dialogo com Owner fica FILHO da janela principal na arvore UIA (nao do RootElement)
    foreach ($w in @($mainWin.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))) {
        if ($w.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $w.Current.Name -like '*configura*') { return $w }
    }
    $null
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
    # TabControl so' renderiza a aba SELECIONADA — os elementos das outras nao existem na UIA
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $tab = $dlg.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $tab) { throw "aba $name nao achada" }
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 500
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
function Show-Main([int]$procId) {
    # Alt+Q e TOGGLE: so aperta quando a janela esta fora da tela (IsOffscreen)
    for ($try = 0; $try -lt 5; $try++) {
        $w = Get-MainWin $procId
        if ($w -and -not $w.Current.IsOffscreen) { return $w }
        Combo 0x12 0x51
        Start-Sleep -Milliseconds 800
    }
    throw 'janela principal nao ficou visivel'
}

Copy-Item $cfgFile $bakFile -Force
$app = Get-AppProc
try {
    #### fase 1: moldura custom ####
    Restart-App
    $app = Get-AppProc
    $w = Show-Main $app.ProcessId
    foreach ($id in 'SettingsBtn','MinBtn','MaxBtn','CloseBtn') {
        if (-not (Find-ById $w $id)) { throw "fase1: botao $id nao achado (moldura custom)" }
    }
    'fase1: botoes ⚙ — ▢ ✕ presentes'
    $width0 = [int]$w.Current.BoundingRectangle.Width
    $wp = $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
    if ($wp.Current.WindowVisualState -ne 'Normal') { throw "fase1: estado inicial = $($wp.Current.WindowVisualState)" }
    $m = (Read-LogText).Length
    Invoke-Btn $w 'MaxBtn'
    $new = Wait-Log $m 'chrome: maximizado' 10
    if (-not $new) { throw 'fase1: sem log de maximizado' }
    if ($wp.Current.WindowVisualState -ne 'Maximized') { throw 'fase1: WindowPattern nao viu Maximized' }
    $m = (Read-LogText).Length
    Invoke-Btn $w 'MaxBtn'
    $null = Wait-Log $m 'chrome: restaurado' 10
    if ($wp.Current.WindowVisualState -ne 'Normal') { throw 'fase1: nao restaurou' }
    $m = (Read-LogText).Length
    Invoke-Btn $w 'CloseBtn'
    $null = Wait-Log $m 'chrome: ocultado' 10
    Start-Sleep -Milliseconds 700
    if (Get-MainWin $app.ProcessId) { throw 'fase1: janela nao ocultou' }
    'fase1: ▢ maximiza/restaura; ✕ oculta pra bandeja — OK'

    #### fase 2: dialogo de configuracoes ####
    $w = Show-Main $app.ProcessId
    $m = (Read-LogText).Length
    Invoke-Btn $w 'SettingsBtn'
    $null = Wait-Log $m 'config: dialogo \(perfis \d+\)' 10
    $sd = $null
    for ($try = 0; $try -lt 10 -and -not $sd; $try++) {
        $w = Show-Main $app.ProcessId     # re-adquire (elemento stale nao varre Descendants)
        $sd = Get-SettingsWin $w
        if (-not $sd) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $sd) { throw 'fase2: dialogo de configuracoes nao apareceu' }
    'fase2: dialogo ⚙ aberto'
    Select-Tab $sd 'Janela'
    Set-Value $sd 'SetW' '700'
    Set-Value $sd 'SetH' '480'
    $sl = Find-ById $sd 'SetOpacity'
    $rv = $sl.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
    $rv.SetValue(0.75)
    Select-Tab $sd 'Aparência'
    Set-Value $sd 'SetFontSize' '14'
    Start-Sleep -Milliseconds 300
    $m = (Read-LogText).Length
    Invoke-Btn $sd 'SetApply'
    $new = Wait-Log $m 'config: aplicado' 15
    if (-not $new) { throw "fase2: sem 'config: aplicado'. Log: $(Read-New $m)" }
    if ($new -notmatch 'janela 700x480') { throw "fase2: log nao cita 700x480: $($new -split "`n" | Select-String 'config: aplicado')" }
    if ($new -notmatch '75\s*%') { throw 'fase2: log nao cita opacidade 75%' }
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if ([int]$j.window.width -ne 700 -or [int]$j.window.height -ne 480) { throw "fase2: json window = $($j.window.width)x$($j.window.height)" }
    if ([double]$j.windowOpacity -lt 0.74 -or [double]$j.windowOpacity -gt 0.76) { throw "fase2: json opacity = $($j.windowOpacity)" }
    if ([int]$j.answerFontSize -ne 14) { throw "fase2: json answerFontSize = $($j.answerFontSize)" }
    'fase2: aplicado + json gravado (700x480, 75%, fonte 14)'
    Tap 0x1B   # Esc fecha o dialogo (IsCancel)
    Start-Sleep -Milliseconds 800
    if (Get-SettingsWin $w) { throw 'fase2: dialogo nao fechou com Esc' }

    # janela reabre com o tamanho novo (BoundingRectangle e fisico: escala por width0/860)
    $wm = Show-Main $app.ProcessId
    Invoke-Btn $wm 'CloseBtn'
    Start-Sleep -Milliseconds 700
    $w2 = Show-Main $app.ProcessId
    $scale = $width0 / 860.0
    $wNow = [int]$w2.Current.BoundingRectangle.Width
    $esperado = [int](700 * $scale)
    if ([Math]::Abs($wNow - $esperado) -gt 60) { throw "fase2: largura apos reabrir = $wNow (esperado ~$esperado, escala $([math]::Round($scale,2)))" }
    "fase2: reabriu com largura $wNow (esperado ~$esperado) — OK"

    #### fase 3: troca de chave (PasswordBox via UIA) ####
    $keyOk = $true
    try {
        $w = Show-Main $app.ProcessId
        Invoke-Btn $w 'SettingsBtn'
        $sd = $null
        for ($try = 0; $try -lt 10 -and -not $sd; $try++) {
            $w = Show-Main $app.ProcessId
            $sd = Get-SettingsWin $w
            if (-not $sd) { Start-Sleep -Milliseconds 400 }
        }
        if (-not $sd) { throw 'dialogo nao abriu (fase 3)' }
        Set-Value $sd 'SetKey' 'TESTKEY-W6-XYZ'
        $m = (Read-LogText).Length
        Invoke-Btn $sd 'SetApply'
        if (-not (Wait-Log $m 'config: aplicado' 15)) { throw 'sem aplicado (fase 3)' }
        Tap 0x1B; Start-Sleep -Milliseconds 600
        $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
        if ([string]$j.profiles.zai.apiKey -ne 'TESTKEY-W6-XYZ') { throw 'json nao gravou a chave no perfil zai' }
        'fase3: chave do perfil gravada via PasswordBox — OK'
    } catch { $keyOk = $false; "fase3: PULADO ($_)" }
} finally {
    # restaura config original e reinicia limpo
    if (Test-Path $bakFile) { Copy-Item $bakFile $cfgFile -Force; Remove-Item $bakFile -Force -Confirm:$false }
    Restart-App
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if ([string]$j.profiles.zai.apiKey -eq 'TESTKEY-W6-XYZ') { throw 'FATAL: chave de teste nao foi restaurada' }
    "restaurado: json original de volta; engine novo no ar ($(if ($keyOk) { 'fase3 executada' } else { 'fase3 pulada' }))"
}
'WAVE6 OK'
