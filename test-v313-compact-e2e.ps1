# test-v313-compact-e2e.ps1 - v3.13: compactacao NAO apaga mais o historico.
# Disco guarda a conversa COMPLETA (GetFull); so' a copia da API e' resumida.
# Fases: (1) retoma conv de 30 msgs -> confirm de compactar -> Compactar ->
#   disco continua com 32 (30+2), nao 8. (2) retoma de novo -> botao
#   Auto-compactar -> liga autocompact no json. (3) retoma de novo -> compacta
#   SEM dialogo. ASCII-only (5.1/ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$hist = 'C:\Users\EVTU-DELL\.local\bin\zquick\history'
$conv = Join-Path $hist 'conv-99991231-010101-999.json'
$jsonPath = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json'
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
        Start-Sleep -Milliseconds 500
        $t = Read-New $mark
        if ($t -match $pat) { return $t }
    }
    return $null
}
$procId = (Get-Process zquick | Select-Object -First 1).Id
$root = [System.Windows.Automation.AutomationElement]::RootElement
$pcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
function Find-Wins {
    # janelas do processo na raiz + dialogos com Owner (aparecem como filhos da principal)
    $c = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Get-MainWin {
    $w = Find-Wins | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' -and $_.Current.Name -notlike '*cor*' -and $_.Current.Name -notlike '*configura*' -and $_.Current.Name -notlike '*renomear*' } | Select-Object -First 1
    if ($w) { return $w }
    for ($try = 0; $try -lt 4; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $w = Find-Wins | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' -and $_.Current.Name -notlike '*cor*' -and $_.Current.Name -notlike '*configura*' -and $_.Current.Name -notlike '*renomear*' } | Select-Object -First 1
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
function Send-Prompt($win, [string]$text) {
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')
    $input = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    $input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $r = $input.Current.BoundingRectangle
    $null = [K.I]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
    [K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    Tap 0x0D
}
function Resume-Conv([string]$searchText) {
    $win = Get-MainWin
    $null = Invoke-ById $win 'HistBtn'
    $dl = (Get-Date).AddSeconds(8); $sw = $null
    while ((Get-Date) -lt $dl -and -not $sw) {
        Start-Sleep -Milliseconds 400
        $sw = Find-Wins | Where-Object { $_.Current.Name -like '*hist*' } | Select-Object -First 1
    }
    if (-not $sw) { throw 'dialogo do historico nao achado' }
    $sc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'Search')
    $sbx = $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $sc)
    if (-not $sbx) { throw 'Search do historico nao achado' }
    $sbx.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($searchText)
    Start-Sleep -Milliseconds 500
    $lc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = @($sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'List'))).FindAll([System.Windows.Automation.TreeScope]::Children, $lc))
    if ($items.Count -lt 1) { throw 'item do historico nao apareceu no filtro' }
    $items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $null = Invoke-ById $sw 'OkBtn'
}

# ---- fixture: conversa com 30 msgs ----
$msgs = @()
for ($i = 1; $i -le 15; $i++) {
    $msgs += '{"role":"user","content":[{"type":"text","text":"zq313-compact-test pergunta numero ' + $i + ' sobre um assunto generico qualquer"}]}'
    $msgs += '{"role":"assistant","content":[{"type":"text","text":"zq313-compact-test resposta numero ' + $i + ' com texto generico de preenchimento"}]}'
}
$obj = [ordered]@{ time = '9999-12-31T01:01:01'; profile = 'zai'; model = 'glm-5.3'; q = 'zq313-compact-test pergunta original'; a = 'zq313-compact-test resposta final'; msgs = $msgs }
[pscustomobject]$obj | ConvertTo-Json -Depth 4 | Set-Content -Path $conv -Encoding utf8
'fixture: 30 msgs no historico'

# ============ FASE 1: confirm -> Compactar -> disco continua completo ============
Resume-Conv 'zq313-compact-test'
$w1 = Wait-Log 'historico: retomou (\d+) msgs' ([IO.File]::ReadAllText($log).Length) 15
if (-not $w1) { throw 'fase1: nao retomou as 30 msgs' }
$null = $w1 -match 'retomou (\d+)'
if ($Matches[1] -ne '30') { throw "fase1: retomou $($Matches[1]) msgs, esperado 30" }
"fase1: retomou $($Matches[1]) msgs"
if (-not $w1) { throw 'fase1: nao retomou as 30 msgs' }
'fase1: retomou 30 msgs'
$mark1 = [IO.File]::ReadAllText($log).Length
$win = Get-MainWin
Send-Prompt $win 'zq313fase1 responda apenas: ok'
$c1 = Wait-Log 'confirma: Compactar' $mark1 30
if (-not $c1) { throw 'fase1: confirm de compactacao NAO apareceu' }
'fase1: confirm de compactacao apareceu'
$null = Invoke-ById $win 'ConfirmYes'
$r1 = Wait-Log 'respondido: (\d+) chars' $mark1 120
if (-not $r1) { throw 'fase1: sem respondido' }
if ($r1 -notmatch 'conversa compactada') { throw 'fase1: nao compactou' }
Start-Sleep -Milliseconds 800
$n1 = @((Get-Content $conv -Raw -Encoding utf8 | ConvertFrom-Json).msgs).Count
"fase1: msgs no disco apos compactar = $n1 (esperado 32; antigo comportamento gravaria 8)"
if ($n1 -ne 32) { throw "fase1: disco deveria ter 32 msgs, tem $n1" }

# ============ FASE 2: botao Auto-compactar liga o autocompact ============
Resume-Conv 'zq313fase1'
$mark2 = [IO.File]::ReadAllText($log).Length
$win = Get-MainWin
Send-Prompt $win 'zq313fase2 responda apenas: ok'
$c2 = Wait-Log 'confirma: Compactar' $mark2 30
if (-not $c2) { throw 'fase2: confirm de compactacao NAO apareceu' }
'fase2: confirm de compactacao apareceu'
$null = Invoke-ById $win 'ConfirmAlwaysBtn'   # v3.13: virou "Auto-compactar"
$r2 = Wait-Log 'respondido: (\d+) chars' $mark2 120
if (-not $r2) { throw 'fase2: sem respondido' }
if ($r2 -notmatch 'autocompact LIGADO') { throw 'fase2: autocompact nao ligou no engine' }
Start-Sleep -Milliseconds 500
if (-not ((Get-Content $jsonPath -Raw | ConvertFrom-Json).autoCompact)) { throw 'fase2: autoCompact nao gravou no json' }
'fase2: autocompact LIGADO (engine + json)'
$n2 = @((Get-Content $conv -Raw -Encoding utf8 | ConvertFrom-Json).msgs).Count
"fase2: msgs no disco = $n2 (esperado 34)"
if ($n2 -ne 34) { throw "fase2: disco deveria ter 34 msgs, tem $n2" }

# ============ FASE 3: autocompact roda SEM dialogo ============
Resume-Conv 'zq313fase2'
$mark3 = [IO.File]::ReadAllText($log).Length
$win = Get-MainWin
Send-Prompt $win 'zq313fase3 responda apenas: ok'
$r3 = Wait-Log 'respondido: (\d+) chars' $mark3 150
if (-not $r3) { throw 'fase3: sem respondido' }
if ($r3 -match 'confirma: Compactar') { throw 'fase3: abriu dialogo mesmo com autocompact' }
if ($r3 -notmatch 'autocompact') { throw 'fase3: autocompact nao rodou' }
'fase3: compactou sem dialogo'
$n3 = @((Get-Content $conv -Raw -Encoding utf8 | ConvertFrom-Json).msgs).Count
"fase3: msgs no disco = $n3 (esperado 36)"
if ($n3 -ne 36) { throw "fase3: disco deveria ter 36 msgs, tem $n3" }

# ---- cleanup ----
Remove-Item $conv -Force -ErrorAction SilentlyContinue
$cfg2 = Get-Content $jsonPath -Raw | ConvertFrom-Json
$cfg2.autoCompact = $false
$cfg2 | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding utf8
Combo 0x11 0x4E; Start-Sleep -Milliseconds 400; Tap 0x1B
"VERDICTO: OK (disco completo nas 3 fases + auto-compactar liga + compacta sem dialogo)"
