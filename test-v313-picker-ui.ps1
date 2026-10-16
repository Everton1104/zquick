# test-v313-picker-ui.ps1 - v3.13: clicar num swatch da paleta abre o seletor
# visual (arco-iris HSV) e o hex escolhido volta pra caixa da configuracao.
# Swatch e' um Rectangle sem peer UIA -> clique por coordenadas (72px a
# esquerda do TextBox hex). ASCII-only (5.1/ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
'@
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
function Click-At([int]$x, [int]$y) {
    $null = [K.I]::SetCursorPos($x, $y)
    [K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 400
}
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

# limpeza em falha: testes que abortam deixam modal aberto e poluem os proximos
function Close-All {
    for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }
    $sw2 = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1
    if ($sw2) { try { Invoke-ById $sw2 'SetClose' } catch {} }
}
trap { Close-All; throw }

$win = Get-MainWin
$null = Invoke-ById $win 'SettingsBtn'
$sw = $null
$dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $sw) {
    Start-Sleep -Milliseconds 400
    $sw = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1
}
if (-not $sw) { throw 'configuracoes nao abriram' }
'configuracoes abertas'

# aba Aparencia (unico TabItem com 'Apar')
$tc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
$tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
if (-not $tab) { throw 'aba Aparencia nao achada' }
$tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Start-Sleep -Milliseconds 600
'aba Aparencia selecionada'

# primeiro TextBox com valor #RRGGBB (a aba tem caixas de fonte que tambem sao Edit)
$ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
$edits = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec))
$hexEdits = @($edits | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -match '^#[0-9A-Fa-f]{6}$' })
if ($hexEdits.Count -lt 1) { throw 'nenhum TextBox hex na aba' }
$hex0 = $hexEdits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
"caixas hex: $($hexEdits.Count) de $($edits.Count) edits; primeira: $hex0"

# clica no swatch (72px a esquerda do TextBox hex)
$r = $hexEdits[0].Current.BoundingRectangle
Click-At ([int]($r.Left - 72)) ([int](($r.Top + $r.Bottom) / 2))

# seletor visual 'ZQuick -- cor'
$pk = $null
$dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $pk) {
    Start-Sleep -Milliseconds 400
    $pk = Find-Wins | Where-Object { $_.Current.Name -like '*cor' -or $_.Current.Name -like '*cor *' } | Select-Object -First 1
}
if (-not $pk) { throw 'seletor de cor nao abriu' }
'seletor visual aberto'

# clica no meio do espectro (janela 420 de largura; espectro ~47..197px do topo)
$pr = $pk.Current.BoundingRectangle
Click-At ([int]($pr.Left + ($pr.Width * 0.62))) ([int]($pr.Top + 120))

# mexe o brilho (Slider)
$slc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Slider)
$slider = $pk.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $slc)
if (-not $slider) { throw 'slider de brilho nao achado' }
$slider.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue(70)
Start-Sleep -Milliseconds 500
$hexPk = (@($pk.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec)) | Select-Object -First 1).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
"hex no seletor apos clique+slider: $hexPk"
if ($hexPk -notmatch '^#[0-9A-F]{6}$') { throw "hex invalido no seletor: $hexPk" }

# OK
$bc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$okb = @($pk.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) | Where-Object { $_.Current.Name -eq 'OK' } | Select-Object -First 1
if (-not $okb) { throw 'botao OK do seletor nao achado' }
$okb.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 600

# a caixa na configuracao tem que ter mudado
$edits2 = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec) | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -match '^#[0-9A-Fa-f]{6}$' })
$hex1 = $edits2[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
"hex na caixa apos escolher: $hex1"
if ($hex1 -eq $hex0) { throw 'hex NAO mudou ? seletor nao devolveu a cor' }
if ($hex1 -ne $hexPk) { throw "hex devolvido diverge: caixa=$hex1 seletor=$hexPk" }

# desfaz (devolve o valor original) e fecha
$edits2[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($hex0)
Start-Sleep -Milliseconds 300
$null = Invoke-ById $sw 'SetClose'
Start-Sleep -Milliseconds 400
"VERDICTO: OK (swatch abre seletor HSV -> clique+slider geram hex -> OK devolve pra caixa)"


