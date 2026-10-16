# test-v315-preview-e2e.ps1 - v3.15: aba Aparencia com nomes legiveis nas
# cores + mini ZQuick que espelha as cores ao vivo. Confere estrutura (labels
# e elementos da previa) e que editar hex/resetar/fechar nao derruba o app.
# A confirmacao VISUAL do espelhamento e do usuario (regra ui-test-fallback-human).
# ASCII-only (5.1/ANSI).
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
$mark0 = [IO.File]::ReadAllText($log).Length
trap { for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; throw }

$win = Get-MainWin
$null = Invoke-ById $win 'SettingsBtn'
$sw = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $sw) { Start-Sleep -Milliseconds 400; $sw = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1 }
if (-not $sw) { throw 'configuracoes nao abriram' }
'configuracoes abertas'

# aba Aparencia
$tc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
$tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
if (-not $tab) { throw 'aba Aparencia nao achada' }
$tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Start-Sleep -Milliseconds 700

# 1. labels legiveis presentes
$txtC = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
$texts = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $txtC)) | ForEach-Object { $_.Current.Name }
foreach ($nome in @('Card da resposta', 'Pergunta', 'Barra de status', 'Bandeja (fim)')) {
    if ($texts -notcontains $nome) { throw "label '$nome' nao apareceu" }
}
"labels legiveis ok (Card da resposta, Pergunta, Barra de status, Bandeira... $($texts.Count) textos)"

# 2. mini ZQuick presente (titulo da previa + composer) dentro do dialogo
$miniTitle = @($texts | Where-Object { $_ -like '*busca*' })
if ($miniTitle.Count -lt 1) { throw 'previa (mini ZQuick) nao achada na aba' }
$prevOk = 0
foreach ($probe in @('*glm-5.3*ctx*', '*fontes*', '*nota secundaria*')) {
    if (@($texts | Where-Object { $_ -like $probe }).Count -ge 1) { $prevOk++ }
}
"previa: elementos reconhecidos: $prevOk/3"
if ($prevOk -lt 2) { throw 'previa incompleta (esperava status/fontes/nota)' }

# 3. editar hex ao vivo (pinta a previa - visual) + reset + fechar = vivo
# (independe do tema atual do usuario: edita a 1a caixa e confere no valor)
$ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
$hexEdits = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec)) | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -match '^#[0-9A-Fa-f]{6}$' }
if ($hexEdits.Count -lt 14) { throw "esperava 14 hex, achei $($hexEdits.Count)" }
$v0 = $hexEdits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
$hexEdits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('#FF0000')
Start-Sleep -Milliseconds 500
$hexEdits2 = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec)) | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -match '^#[0-9A-Fa-f]{6}$' }
if (@($hexEdits2 | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -eq '#FF0000' }).Count -lt 1) { throw 'hex da 1a cor nao mudou' }
"1a cor editada pra #FF0000 (era $v0; previa deve ter repintado)"
# devolve o valor original antes de fechar (nao suja o tema do usuario)
$hexEdits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v0)
$null = Invoke-ById $sw 'SetClose'
Start-Sleep -Milliseconds 500
if (-not (Get-Process zquick -ErrorAction SilentlyContinue)) { throw 'processo morreu' }
if ((Read-New $mark0) -match 'FATAL') { throw 'FATAL no log' }
'app vivo, sem FATAL'
"VERDICTO: OK (labels legiveis + previa presente + edicao/fechar sem crash)"
