# test-histbtn-ui.ps1 — E2E do clique real no 🕘 (UI Automation): botao -> dialogo -> Retomar -> conversa carregada.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$off = [IO.File]::ReadAllText($log).Length
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
function Find-WindowsByProc([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))
}
function Invoke-Button($win, [string]$name, [string]$label) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $btn) { throw "botao '$label' nao encontrado via UIA" }
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    "invocado: $label"
}
function Get-ChildWin($mainWin, [string]$nameLike) {
    # dialogo com WindowChrome/Owner aninha como FILHO da janela principal na arvore UIA
    foreach ($d in @($mainWin.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))) {
        if ($d.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $d.Current.Name -like $nameLike) { return $d }
    }
    $null
}
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }

# acha o processo do zquick
$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }
"pid: $($app.ProcessId)"

# abre a janela (toggle e' estado: se ja estava visivel, o 1o Alt+Q esconde —
# entao repete ate a janela aparecer de fato na arvore UIA)
$win = $null
for ($try = 0; $try -lt 3 -and -not $win; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    $win = @(Find-WindowsByProc $app.ProcessId) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
}
if (-not $win) { throw 'janela do zquick nao achada via UIA' }
$mark = [IO.File]::ReadAllText($log).Length

# clica no 🕘 (mesmo caminho do usuario)
Invoke-Button $win '🕘' 'relogio/historico'

# espera o dialogo logar
$okDialogo = $false
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ((Read-New $mark) -match 'historico: dialogo \((\d+) itens\)') { $okDialogo = $true; "dialogo aberto com $($Matches[1]) itens"; break }
    if ((Read-New $mark) -match 'historico-ui: (.+)') { throw "dialogo ERRO: $($Matches[1])" }
}
if (-not $okDialogo) { throw 'dialogo nao abriu (sem log)' }

# clica Retomar no dialogo (item 0 = mais recente)
$mark2 = [IO.File]::ReadAllText($log).Length
$dlg = $null
$deadline = (Get-Date).AddSeconds(5)
while (-not $dlg -and (Get-Date) -lt $deadline) {
    $dlg = @(Find-WindowsByProc $app.ProcessId) | Where-Object { $_.Current.Name -like '*histórico*' } | Select-Object -First 1
    if (-not $dlg) { $dlg = Get-ChildWin $win '*histórico*' }
    if (-not $dlg) { Start-Sleep -Milliseconds 300 }
}
if (-not $dlg) { throw 'dialogo nao visivel via UIA' }
Invoke-Button $dlg 'Retomar' 'Retomar'

# espera o load
$okLoad = $false
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ((Read-New $mark2) -match 'historico: retomou (\d+) msgs') { $okLoad = $true; "retomou $($Matches[1]) msgs"; break }
}
if (-not $okLoad) { throw 'conversa nao carregou' }

# limpeza: nova conversa + esconde
Combo 0x11 0x4E; Start-Sleep -Milliseconds 400
Tap 0x1B
'VEREDITO: OK (clique -> dialogo -> retomar)'
'--- log novo ---'
Read-New $off