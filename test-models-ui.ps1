# test-models-ui.ps1 — v3.10: botao "🔎 listar da API" no 🎚 puxa GET /v1/models e enche a caixa de modelos.
#   1. abre o ⚙ (aba Perfil e a primeira), invoca SetListModels, poll do valor de SetModels
#   2. confere 'glm-' + EXATAMENTE UMA estrela ⭐, em modelo sem sufixo flash/turbo/air/mini/lite
#   3. Aplicar -> ModelBox do topo mostra o item com ⭐; seleciona -> cfg.model fica com id LIMPO
#   finally: restaura zquick.json + restart
# Rodar com: pwsh -STA -File test-models-ui.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$cfgFile = Join-Path $PSScriptRoot 'zquick.json'
$bakFile = Join-Path $env:TEMP 'zquick.mbak.json'

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
function Read-LogText { for ($i = 0; $i -lt 10; $i++) { try { return [IO.File]::ReadAllText($log) } catch { Start-Sleep -Milliseconds 150 } } throw 'log travado' }
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        try { $new = (Read-LogText).Substring($mark) } catch { $new = '' }
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 400
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
    for ($try = 0; $try -lt 6; $try++) {
        $w = Get-MainWin $procId
        if ($w -and -not $w.Current.IsOffscreen) { return $w }
        Combo 0x12 0x51
        Start-Sleep -Milliseconds 900
        $w = Get-MainWin $procId
        if ($w -and -not $w.Current.IsOffscreen) { return $w }
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

Copy-Item $cfgFile $bakFile -Force
try {
    $app = Get-AppProc
    $w = Show-Main $app.ProcessId

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
'dialogo ⚙ aberto (aba Perfil é a primeira — já selecionada)'

$m = (Read-LogText).Length
Invoke-Btn $sd 'SetListModels'
$new = Wait-Log $m 'modelos listados da API|listar modelos falhou' 30
if (-not $new) { throw 'sem log do listar modelos (nem sucesso nem falha)' }
if ($new -notmatch 'modelos listados da API') { throw "listar falhou: $($new -split "`n" | Select-Object -Last 3)" }

# poll do valor da caixa ate refletir (UIA cache pode estar stale na 1a leitura)
$val = ''
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline) {
    $sd = Get-SettingsWin (Show-Main $app.ProcessId)
    if ($sd) {
        $tb = Find-ById $sd 'SetModels'
        if ($tb) { $val = $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
        if ($val) { break }
    }
    Start-Sleep -Milliseconds 400
}
if (-not $val) { throw 'caixa SetModels continua vazia' }
if ($val -notmatch 'glm-') { throw "lista sem glm-: $val" }
$ids = @($val -split ',' | ForEach-Object { $_.Trim() })
"caixa preenchida: $($ids.Count) modelos — $($ids -join ' · ')"

#### estrela de recomendado ####
$starred = @($ids | Where-Object { $_ -match '⭐' })
if ($starred.Count -ne 1) { throw "esperava EXATAMENTE 1 recomendado, veio $($starred.Count): $($starred -join ',')" }
$recId = ($starred[0] -replace '\s*⭐\s*$','').Trim()
if ($recId -match '(?i)flash|turbo|air|mini|lite|preview|thinking') { throw "recomendado deveria ser modelo cheio, veio: $recId" }
"recomendado: ⭐ $recId"

#### Aplicar e conferir a cadeia inteira no topo ####
Invoke-Btn $sd 'SetApply'
Start-Sleep -Milliseconds 1200
$w = Show-Main $app.ProcessId
$mb = Find-ById $w 'ModelBox'
if (-not $mb) { throw 'ModelBox nao achado' }
$mb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
Start-Sleep -Milliseconds 600
$starItem = $null
foreach ($it in @($mb.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition))) {
    if ($it.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and [string]$it.Current.Name -eq $starred[0]) { $starItem = $it; break }
}
if (-not $starItem) { throw "item '$($starred[0])' nao apareceu no ModelBox" }
"ModelBox do topo mostra o item com ⭐: $($starItem.Current.Name)"
$starItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Start-Sleep -Milliseconds 900
$j = Get-Content $cfgFile -Raw | ConvertFrom-Json
if ([string]$j.model -ne $recId) { throw "cfg.model deveria ser o id LIMPO '$recId', veio '$($j.model)'" }
"cfg.model = '$($j.model)' (id limpo, sem estrela) — cadeia de strip OK"
} finally {
    if (Test-Path $bakFile) { Copy-Item $bakFile $cfgFile -Force; Remove-Item $bakFile -Force -Confirm:$false }
    Restart-App
    'restaurado: json original de volta, app reiniciado'
}
'MODELS-LIST OK'
