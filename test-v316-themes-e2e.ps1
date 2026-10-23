# test-v316-themes-e2e.ps1 - v3.16: temas nomeados no ⚙ (💾 salvar / ◀ aplicar /
# 🗑 apagar) + botaozinho ⟲ que volta SO a cor daquela linha pro padrao.
# Fluxo: sentinela #ABCDEF -> salva tema -> restaura padroes -> aplica tema
# (sentinela volta) -> ⟲ devolve o padrao -> apaga tema -> fecha sem FATAL.
# ASCII-only (5.1/ANSI); o ⟲ entra por codigo de caractere.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$rl = [string][char]0x27F2   # seta anti-horaria do botao de reset
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
function Wait-Log([string]$pat, [int]$mark, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 400
        $t = Read-New $mark
        if ($t -match $pat) { return $t }
    }
    return $null
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
function Get-HexEdits($sw) {
    $ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec)) | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -match '^#[0-9A-Fa-f]{6}$' }
}
function Get-Val($el) { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
function Set-Val($el, [string]$v) { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v) }
function Select-Theme($cbEl, $licCond, [string]$name) {
    $cbEl.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Start-Sleep -Milliseconds 400
    $li = @($cbEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $licCond)) | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
    if (-not $li) { throw "tema '$name' nao esta na lista" }
    $li.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 300
    try { $cbEl.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch {}
}
function Get-Status($win) {
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'SetStatus')))
    if ($el) { return [string]$el.Current.Name }
    return ''
}

$mark0 = [IO.File]::ReadAllText($log).Length
trap { for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; throw }

$win = Get-MainWin
$null = Invoke-ById $win 'SettingsBtn'
$sw = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $sw) { Start-Sleep -Milliseconds 400; $sw = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1 }
if (-not $sw) { throw 'configuracoes nao abriram' }
'configuracoes abertas'
$tc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
$tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
if (-not $tab) { throw 'aba Aparencia nao achada' }
$tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Start-Sleep -Milliseconds 700

# 1. botaozinho ⟲ existe em cada uma das 15 linhas (v3.22: + 'Barra de rolagem')
$bc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$rlBtns = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) | Where-Object { $_.Current.Name -eq $rl }
"botoes reset: $($rlBtns.Count)"
if ($rlBtns.Count -ne 15) { throw "esperava 15 botoes reset, achei $($rlBtns.Count)" }

# 2. salva um tema com sentinela na 1a cor
$hexEdits = @(Get-HexEdits $sw)
if ($hexEdits.Count -lt 15) { throw "esperava 15 hex, achei $($hexEdits.Count)" }
$h0 = $hexEdits[0]; $v0 = Get-Val $h0
# sentinela fixa #ABCDEF; o default da 1a chave (bg) e' sempre #202024
$sent = '#ABCDEF'; $def0 = '#202024'
Set-Val $h0 $sent
Start-Sleep -Milliseconds 300
$nm = 'tema-e2e-' + (Get-Date -Format 'HHmmss')
$nameBox = $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'SetThemeName')))
if (-not $nameBox) { throw 'caixa de nome do tema nao achada' }
Set-Val $nameBox $nm
$null = Invoke-ById $sw 'SetThemeSave'
if (-not (Wait-Log ('tema: salvo "' + $nm) $mark0 8)) { throw 'nao logou tema salvo' }
"tema salvo: $nm (1a cor = $sent; original era $v0)"

# 3. restaura padroes -> 1a cor vira o default
$null = Invoke-ById $sw 'SetResetColors'
Start-Sleep -Milliseconds 500
if ((Get-Val $h0) -ne $def0) { throw "reset nao devolveu o padrao (veio $(Get-Val $h0), esperava $def0)" }
'restaurar padroes ok'

# 4. aplica o tema salvo -> sentinela volta
$cb = $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'SetThemeList')))
if (-not $cb) { throw 'combo de temas nao achada' }
$cb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
Start-Sleep -Milliseconds 400
$lic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
$li = @($cb.FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic)) | Where-Object { $_.Current.Name -eq $nm } | Select-Object -First 1
if (-not $li) { throw 'tema salvo nao apareceu na lista' }
$li.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Start-Sleep -Milliseconds 300
try { $cb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch {}
$null = Invoke-ById $sw 'SetThemeLoad'
Start-Sleep -Milliseconds 500
if ((Get-Val $h0) -ne $sent) { throw "aplicar tema nao devolveu a sentinela (veio $(Get-Val $h0), esperava $sent)" }
'tema aplicado nas caixas'

# 5. ⟲ da 1a linha volta SO ela pro padrao
$rlBtns[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 400
if ((Get-Val $h0) -ne $def0) { throw "botao reset nao devolveu o padrao (veio $(Get-Val $h0), esperava $def0)" }
'botao reset ok'

# 6. apaga o tema
$mark1 = [IO.File]::ReadAllText($log).Length
$cb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
Start-Sleep -Milliseconds 400
$li = @($cb.FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic)) | Where-Object { $_.Current.Name -eq $nm } | Select-Object -First 1
if ($li) { $li.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 300 }
try { $cb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch {}
$null = Invoke-ById $sw 'SetThemeDel'
if (-not (Wait-Log ('tema: apagado "' + $nm) $mark1 8)) { throw 'nao logou tema apagado' }
'tema apagado'

# 6b. temas EMBUTIDOS: 'padrao' e 'matrix' vem no app (v3.16.1)
$pad = 'padr' + [char]0xE3 + 'o'   # acento por codigo de caractere (arquivo ASCII)
$cb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
Start-Sleep -Milliseconds 400
$items = @($cb.FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic)) | ForEach-Object { $_.Current.Name }
try { $cb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch {}
"lista de temas: $($items -join ', ')"
if ($items -notcontains $pad)   { throw "lista sem o tema embutido '$pad'" }
if ($items -notcontains 'matrix') { throw 'lista sem o tema embutido matrix' }
if ($items.IndexOf($pad) -gt 0 -or $items.IndexOf('matrix') -ne 1) { throw 'embutidos nao vieram primeiro' }
Select-Theme $cb $lic 'matrix'
$null = Invoke-ById $sw 'SetThemeLoad'
Start-Sleep -Milliseconds 500
if ((Get-Val $h0) -ne '#000000') { throw "matrix nao aplicou (1a cor = $(Get-Val $h0), esperava #000000)" }
'matrix aplicado (bg #000000)'
Select-Theme $cb $lic $pad
$null = Invoke-ById $sw 'SetThemeLoad'
Start-Sleep -Milliseconds 500
if ((Get-Val $h0) -ne '#202024') { throw "padrao nao aplicou (1a cor = $(Get-Val $h0), esperava #202024)" }
'padrao aplicado (bg #202024)'
# salvar com nome reservado e apagar embutido = recusados
Set-Val $nameBox 'matrix'
$null = Invoke-ById $sw 'SetThemeSave'
Start-Sleep -Milliseconds 400
if ((Get-Status $sw) -notmatch 'embutido') { throw 'salvar com nome de embutido nao foi recusado' }
'salvar sobre embutido: recusado'
Select-Theme $cb $lic $pad
$null = Invoke-ById $sw 'SetThemeDel'
Start-Sleep -Milliseconds 400
if ((Get-Status $sw) -notmatch 'embutido') { throw 'apagar embutido nao foi recusado' }
'apagar embutido: recusado'

# 7. devolve a cor original do usuario e fecha sem crash
Set-Val $h0 $v0
$null = Invoke-ById $sw 'SetClose'
Start-Sleep -Milliseconds 500
if (-not (Get-Process zquick -ErrorAction SilentlyContinue)) { throw 'processo morreu' }
if ((Read-New $mark0) -match 'FATAL') { throw 'FATAL no log' }
'app vivo, sem FATAL'
"VERDICTO: OK (temas salvar/aplicar/apagar + reset por cor + fechamento limpo)"
