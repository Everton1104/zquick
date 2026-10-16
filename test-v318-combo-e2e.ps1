# test-v318-combo-e2e.ps1 - v3.18: ComboBox com template do tema (+ TextBox/PasswordBox
# implicitos no dialogo de config). Estrutural: com template proprio, expandir/listar/
# selecionar/digitar tem que continuar funcionando via UIA nos 6 combos (incluindo o
# EDITAVEL SetFont) e nos campos de texto. A confirmacao VISUAL das cores e do usuario
# (regra ui-test-fallback-human). ASCII-only (5.1/ANSI).
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
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }
$procId = (Get-Process zquick | Select-Object -First 1).Id
$root = [System.Windows.Automation.AutomationElement]::RootElement
$pcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
function Find-Wins {
    $c = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Get-MainWin {
    $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($w) { return $w }
    for ($try = 0; $try -lt 4; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
        if ($w) { return $w }
    }
    throw 'janela principal nao achada'
}
function Invoke-ById($win, [string]$id) {
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    if (-not $el) { throw "elemento $id nao achado" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
function Find-ById($win, [string]$id) {
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)))
}
# expande, conta itens ListItems, colapsa (NAO seleciona: trocar modelo/perfil mudaria a config do usuario)
function Probe-Combo([string]$id, [int]$min) {
    $el = Find-ById $script:__win $id
    if (-not $el) { throw "combo $id nao achado" }
    $ecp = $el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $ecp.Expand(); Start-Sleep -Milliseconds 500
    $lic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = @($el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic))
    try { $ecp.Collapse() } catch {}
    Start-Sleep -Milliseconds 300
    if ($items.Count -lt $min) { throw "combo ${id}: $($items.Count) itens (esperava >= $min)" }
    "$id : $($items.Count) itens, expandir/colapsar OK"
}

$mark0 = [IO.File]::ReadAllText($log).Length
trap { for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; throw }

# ---- 1. janela principal: ProfileBox e ModelBox com o template novo ----
$win = Get-MainWin
$script:__win = $win
Probe-Combo 'ProfileBox' 1
Probe-Combo 'ModelBox' 1

# ---- 2. dialogo de config: combos + campo de texto ----
$null = Invoke-ById $win 'SettingsBtn'
$sw = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $sw) { Start-Sleep -Milliseconds 400; $sw = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1 }
if (-not $sw) { throw 'configuracoes nao abriram' }
'configuracoes abertas'
$script:__win = $sw
Probe-Combo 'SetProfile' 1

# helper de aba: TabControl so renderiza a aba SELECIONADA — selecionar antes de sondar
$tc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
function Select-Tab([string]$like) {
    $tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like $like } | Select-Object -First 1
    if (-not $tab) { throw "aba $like nao achada" }
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 700
}

# aba Janela: TextBox implicito (SetW = largura da janela)
Select-Tab '*Janela*'
$wBox = Find-ById $sw 'SetW'
if (-not $wBox) { throw 'SetW nao achado' }
$wp = $wBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$w0 = $wp.Current.Value
$wp.SetValue('900'); Start-Sleep -Milliseconds 250
if ($wp.Current.Value -ne '900') { throw 'SetW nao aceitou texto' }
$wp.SetValue($w0)
"SetW (TextBox implicito, aba Janela) OK (era $w0, restaurado)"

# aba Aparencia: combo EDITAVEL (SetFont) — ExpandCollapse + ValuePattern no campo interno
Select-Tab '*Apar*'
$sf = Find-ById $sw 'SetFont'
if (-not $sf) { throw 'SetFont nao achado' }
$ecp = $sf.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
$ecp.Expand(); Start-Sleep -Milliseconds 400
try { $ecp.Collapse() } catch {}
$ed = $sf.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)))
if (-not $ed) { throw 'caixa de edicao do SetFont nao achada' }
$v0 = $ed.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
$ed.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Segoe UI')
Start-Sleep -Milliseconds 300
$v1 = $ed.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
if ($v1 -ne 'Segoe UI') { throw "SetFont editavel nao aceitou texto (veio '$v1')" }
$ed.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v0)
"SetFont editavel OK (era '$v0', digitou e restaurou)"

# mesma aba: SetThemeList (template novo) + campo de nome de tema (TextBox implicito)
Probe-Combo 'SetThemeList' 2
$nb = Find-ById $sw 'SetThemeName'
if (-not $nb) { throw 'SetThemeName nao achado' }
$vp = $nb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$vp.SetValue('zq318'); Start-Sleep -Milliseconds 250
if ($vp.Current.Value -ne 'zq318') { throw 'SetThemeName nao aceitou texto' }
$vp.SetValue('')
'SetThemeName (TextBox implicito) OK'

# aba Geral: SetSearch
Select-Tab '*Geral*'
Probe-Combo 'SetSearch' 1

# fecha sem crash
$null = Invoke-ById $sw 'SetClose'
Start-Sleep -Milliseconds 600
if (-not (Get-Process zquick -ErrorAction SilentlyContinue)) { throw 'processo morreu' }
if ((Read-New $mark0) -match 'FATAL') { throw 'FATAL no log' }
'app vivo, sem FATAL'
"VERDICTO: OK (6 combos com template do tema expandem/listam; editavel digita; TextBox implicito aceita texto; fecha limpo)"
