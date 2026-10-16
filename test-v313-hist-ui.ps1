# test-v313-hist-ui.ps1 - v3.13: favoritar (fixa no topo) e renomear
# conversas no dialogo do historico. ASCII-only (5.1/ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$conv = 'C:\Users\EVTU-DELL\.local\bin\zquick\history\conv-99991231-020202-999.json'
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

# ---- fixture ----
$msgs = @(
    '{"role":"user","content":[{"type":"text","text":"zq313-hist-test pergunta original"}]}',
    '{"role":"assistant","content":[{"type":"text","text":"zq313-hist-test resposta original"}]}'
)
$obj = [ordered]@{ time = '9999-12-31T02:02:02'; profile = 'zai'; model = 'glm-5.3'; q = 'zq313-hist-test pergunta original'; a = 'zq313-hist-test resposta original'; msgs = $msgs }
[pscustomobject]$obj | ConvertTo-Json -Depth 4 | Set-Content -Path $conv -Encoding utf8
'fixture criada'

# ---- abre o historico, filtra, seleciona ----
$win = Get-MainWin
$null = Invoke-ById $win 'HistBtn'
$hw = $null
$dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $hw) {
    Start-Sleep -Milliseconds 400
    $hw = Find-Wins | Where-Object { $_.Current.Name -like '*hist*' } | Select-Object -First 1
}
if (-not $hw) { throw 'dialogo do historico nao abriu' }
'historico aberto'
$sc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'Search')
$hw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $sc).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('zq313-hist-test')
Start-Sleep -Milliseconds 600
$lc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
$listEl = $hw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'List')))
$items = @($listEl.FindAll([System.Windows.Automation.TreeScope]::Children, $lc))
if ($items.Count -lt 1) { throw 'conversa nao apareceu no filtro' }
"itens no filtro: $($items.Count); primeiro: $($items[0].Current.Name)"
$items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()

# ---- 1) favoritar ----
$mark1 = [IO.File]::ReadAllText($log).Length
$null = Invoke-ById $hw 'FavBtn'
$f1 = Wait-Log 'historico: fav conv-99991231-020202-999\.json -> True' $mark1 10
if (-not $f1) { throw 'fav: log nao apareceu' }
$j = Get-Content $conv -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $j.fav) { throw 'fav: json nao gravou fav=true' }
'fav: json gravado'
Start-Sleep -Milliseconds 600
$items2 = @($hw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'List'))).FindAll([System.Windows.Automation.TreeScope]::Children, $lc))
$star = [string][char]0x2B50
if ($items2.Count -lt 1 -or $items2[0].Current.Name -notlike '*zq313-hist-test*') { throw 'fav: item nao esta no topo' }
if ($items2[0].Current.Name.IndexOf($star) -lt 0) { throw 'fav: item do topo sem estrela' }
"fav: item no topo com estrela: $($items2[0].Current.Name)"

# ---- 2) renomear ----
$mark2 = [IO.File]::ReadAllText($log).Length
$null = Invoke-ById $hw 'RenBtn'
$rw = $null
$dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $rw) {
    Start-Sleep -Milliseconds 400
    $rw = Find-Wins | Where-Object { $_.Current.Name -like '*Renomear*' } | Select-Object -First 1
}
if (-not $rw) { throw 'renomear: janela de input nao abriu' }
'renomear: janela de input aberta'
$ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
$tb = $rw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $ec)
if (-not $tb) { throw 'renomear: textbox nao achado' }
"renomear: valor atual: $($tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value)"
$tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('nome-renomeado-zq313')
$bc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$okb = @($rw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) | Where-Object { $_.Current.Name -eq 'OK' } | Select-Object -First 1
if (-not $okb) { throw 'renomear: botao OK nao achado' }
$okb.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
$r2 = Wait-Log "historico: renomeada conv-99991231-020202-999\.json -> 'nome-renomeado-zq313'" $mark2 10
if (-not $r2) { throw 'renomear: log nao apareceu' }
$j = Get-Content $conv -Raw -Encoding utf8 | ConvertFrom-Json
if ($j.title -ne 'nome-renomeado-zq313') { throw "renomear: json title = $($j.title)" }
'renomear: json gravado'
Start-Sleep -Milliseconds 600
$items3 = @($hw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'List'))).FindAll([System.Windows.Automation.TreeScope]::Children, $lc))
if ($items3.Count -lt 1 -or $items3[0].Current.Name -notlike '*nome-renomeado-zq313*') { throw 'renomear: lista nao mostra o nome novo no topo' }
"renomear: lista mostra o nome novo: $($items3[0].Current.Name)"

# ---- fecha e limpa ----
$null = Invoke-ById $hw 'HistClose'
Start-Sleep -Milliseconds 400
Remove-Item $conv -Force -ErrorAction SilentlyContinue
"VERDICTO: OK (favorita fixa no topo com estrela + renomeia e a lista/atualizacao refletem)"
