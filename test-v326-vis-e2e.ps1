# test-v326-vis-e2e.ps1 - v3.26: visibilidade do assistente + atalho no config.
#   A. boot normal (fallback do settings.json do Claude Code existe):
#      NoKeyBar RECOLHIDA (nao esta na arvore) + WizBtn abre o wizard.
#   B. config -> aba Geral -> campo de atalho: armar alt+z ao vivo (log +
#      SetHkStatus), voltar pra alt+q, json persistiu alt+q.
#   C. boot com USERPROFILE falso (sem fallback): wizard abre sozinho (sem
#      chave), barra "sem chave" VISIVEL no corpo do chat e o botao dela abre
#      o wizard de novo.
# ASCII-only (5.1/ANSI). Nao mexe no app instalado (orchestration externa).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$root = 'C:\Users\EVTU-DELL\.local\bin\zquick'
$log = Join-Path $env:TEMP 'zquick.log'
$cfgFile = Join-Path $root 'zquick.json'
$snap = Join-Path $env:TEMP 'zq326-snap.json'
Copy-Item $cfgFile $snap -Force
$realHome = $env:USERPROFILE
$fakeHome = Join-Path $env:TEMP 'zq326-fakehome'
function Tap([byte]$vk) {
    [K.I]::keybd_event($vk,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
    [K.I]::keybd_event($vk,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
}
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }
$procId = 0
function Find-Wins {
    $c = @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId))))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Get-MainWin {
    for ($try = 0; $try -lt 12; $try++) {
        $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
        if ($w) { return $w }
        Start-Sleep -Milliseconds 500
    }
    throw 'janela principal nao achou'
}
function Find-ById($win, [string]$id) {
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)))
}
function Invoke-ById($win, [string]$id) {
    $el = Find-ById $win $id
    if (-not $el) { throw "elemento $id nao achado" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
function Wait-Win([string]$like, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 400
        $w = Find-Wins | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.Name -like $like } | Select-Object -First 1
        if ($w) { return $w }
    }
    return $null
}
function Wait-Text([System.Windows.Automation.AutomationElement]$win, [string]$id, [string]$pat, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 500
        $el = Find-ById $win $id
        if ($el -and ([string]$el.Current.Name) -match $pat) { return [string]$el.Current.Name }
    }
    return $null
}
function Set-Val([System.Windows.Automation.AutomationElement]$win, [string]$id, [string]$v) {
    $el = Find-ById $win $id
    if (-not $el) { throw "elemento $id nao achado" }
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $vp.SetValue($v)
    return $el
}
trap { "ERRO(original): $_"; for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; Stop-Process -Name zquick -Force -ErrorAction SilentlyContinue; Copy-Item $snap $cfgFile -Force; $env:USERPROFILE = $realHome; throw }

try {
    # ---- A. boot normal: barra recolhida (fallback existe), WizBtn abre wizard ----
    $mark0 = [IO.File]::ReadAllText($log).Length
    Start-Process (Join-Path $root 'zquick.exe') -WorkingDirectory $root
    $dl = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $dl) { $ps = @(Get-Process zquick -ErrorAction SilentlyContinue); if ($ps.Count) { $procId = $ps[0].Id; break }; Start-Sleep -Milliseconds 300 }
    if (-not $procId) { throw 'dev app nao subiu' }
    $win = Get-MainWin
    if (-not (Wait-Text $win 'LogoText' 'ZQuick' 15)) { throw 'app nao abriu a janela' }
    # Border nao tem AutomationPeer; o UIA (raw view) expoe o botao mesmo
    # recolhido como IsOffscreen=True -> o criterio e offscreen, nao presenca
    $b = Find-ById $win 'NoKeyBtn'
    if ($b -and -not $b.Current.IsOffscreen) { throw 'barra sem-chave visivel com chave de fallback' }
    'A: barra sem-chave recolhida (chave via fallback do settings.json)'
    $null = Invoke-ById $win 'WizBtn'
    $wz = Wait-Win '*assistente*' 8
    if (-not $wz) { throw 'WizBtn nao abriu o wizard' }
    'A: WizBtn (toolbar) abriu o assistente'
    $null = Invoke-ById $wz 'WzClose'
    Start-Sleep -Milliseconds 600
    $still = Wait-Win '*assistente*' 2
    if ($still) { throw 'wizard nao fechou (WzClose)' }

    # ---- B. config -> Geral -> atalho: armar alt+z e voltar pra alt+q ----
    $null = Invoke-ById $win 'SettingsBtn'
    $sw = Wait-Win '*configura*' 8
    if (-not $sw) { throw 'configuracoes nao abriram' }
    $tab = $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)) )
    # acha a aba Geral pelo nome (TabControl so renderiza a selecionada)
    $dl = (Get-Date).AddSeconds(6); $gtab = $null
    while ((Get-Date) -lt $dl -and -not $gtab) {
        $tabs = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem))))
        $gtab = $tabs | Where-Object { $_.Current.Name -eq 'Geral' } | Select-Object -First 1
        if (-not $gtab) { Start-Sleep -Milliseconds 300 }
    }
    if (-not $gtab) { throw 'aba Geral nao achada' }
    $gtab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 500
    if (-not (Find-ById $sw 'SetHotkey')) { throw 'campo SetHotkey nao renderizou na aba Geral' }
    'B: campo de atalho na aba Geral'
    $mark1 = [IO.File]::ReadAllText($log).Length
    $null = Set-Val $sw 'SetHotkey' 'ctrl+alt+z'
    $null = Invoke-ById $sw 'SetHkApply'
    $st = Wait-Text $sw 'SetHkStatus' 'armado' 8
    if (-not $st) { throw 'SetHkStatus nao confirmou: ' + (Find-ById $sw 'SetHkStatus').Current.Name }
    if ((Read-New $mark1) -notmatch "atalho 'ctrl\+alt\+z' \(re\)armado -> True") { throw 'log nao mostra (re)armado ctrl+alt+z' }
    "B: ctrl+alt+z armado ao vivo ($st)"   # nota: alt+z puro e da NVIDIA aqui
    Start-Sleep -Milliseconds 600
    $null = Set-Val $sw 'SetHotkey' 'alt+q'
    $null = Invoke-ById $sw 'SetHkApply'
    $null = Wait-Text $sw 'SetHkStatus' 'armado' 8
    Start-Sleep -Milliseconds 600
    $null = Invoke-ById $sw 'SetClose'
    Start-Sleep -Milliseconds 700
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if ([string]$j.hotkey -ne 'alt+q') { throw "json hotkey=$($j.hotkey) (devia voltar pra alt+q)" }
    'B: voltou pra alt+q e persistiu no zquick.json'
    if (@(Get-Process -Id $procId -ErrorAction SilentlyContinue).Count -eq 0) { throw 'processo morreu' }

    # ---- C. sem fallback (USERPROFILE falso): wizard sozinho + barra visivel ----
    Stop-Process -Id $procId -Force; Start-Sleep -Milliseconds 900
    $mark2 = [IO.File]::ReadAllText($log).Length
    $null = New-Item -ItemType Directory -Force -Path $fakeHome
    $env:USERPROFILE = $fakeHome
    Start-Process (Join-Path $root 'zquick.exe') -WorkingDirectory $root
    $env:USERPROFILE = $realHome
    $procId = 0
    $dl = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $dl) { $ps = @(Get-Process zquick -ErrorAction SilentlyContinue); if ($ps.Count) { $procId = $ps[0].Id; break }; Start-Sleep -Milliseconds 300 }
    if (-not $procId) { throw 'dev app (sem fallback) nao subiu' }
    $wz2 = Wait-Win '*assistente*' 15
    if (-not $wz2) { throw 'wizard nao abriu sozinho na primeira execucao sem chave' }
    'C: wizard abriu sozinho (sem chave de API)'
    $null = Invoke-ById $wz2 'WzClose'
    Start-Sleep -Milliseconds 800
    $win2 = Get-MainWin
    $b2 = $null; $dl = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $dl) {
        $b2 = Find-ById $win2 'NoKeyBtn'
        if ($b2 -and -not $b2.Current.IsOffscreen) { break }
        Start-Sleep -Milliseconds 400; $b2 = $null
    }
    if (-not $b2) { throw 'barra sem-chave nao ficou VISIVEL (offscreen) sem chave' }
    'C: barra "sem chave" visivel no corpo do chat'
    $b2.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $wz3 = Wait-Win '*assistente*' 8
    if (-not $wz3) { throw 'NoKeyBtn nao abriu o wizard' }
    'C: botao da barra abre o assistente'
    $null = Invoke-ById $wz3 'WzClose'
    Start-Sleep -Milliseconds 500
    if ((Read-New $mark2) -match 'FATAL') { throw 'FATAL no log (fase C)' }
    'VERDICTO: OK (WizBtn toolbar + NoKeyBar sem-chave + atalho no config com armar ao vivo)'
} finally {
    Stop-Process -Name zquick -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Copy-Item $snap $cfgFile -Force
    $env:USERPROFILE = $realHome
    Remove-Item $fakeHome -Recurse -Force -ErrorAction SilentlyContinue
    'limpeza: app dev parado, json restaurado, USERPROFILE restaurado'
}
