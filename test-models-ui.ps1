# test-models-ui.ps1 — v3.10: botao "🔎 listar da API" no 🎚 puxa GET /v1/models e enche a caixa de modelos.
# E2E: abre o ⚙ (aba Perfil e a primeira), invoca SetListModels, faz poll do valor de SetModels via UIA
# ate virar nao-vazio; confere 'glm-' na lista + log 'modelos listados da API'. Fecha sem Aplicar (json intacto).
# Rodar com: pwsh -STA -File test-models-ui.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
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

Tap 0x1B   # Cancelar: fecha sem gravar (json intacto)
Start-Sleep -Milliseconds 700
'MODELS-LIST OK'
