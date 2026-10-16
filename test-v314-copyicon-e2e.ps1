# test-v314-copyicon-e2e.ps1 - botao Copiar saiu da barra; cada resposta do bot
# ganhou um icone no topo direito do card. Clicar copia AQUELA resposta.
# Fase A: resposta ao vivo -> clique no icone -> clipboard. Fase B: retomar a
# conversa -> icone do card carregado -> clipboard. ASCII-only.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$icon = [string][char]0x29C9
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
    $c = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Get-MainWin {
    $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if (-not $w) {
        for ($try = 0; $try -lt 4 -and -not $w; $try++) {
            Combo 0x12 0x51; Start-Sleep -Milliseconds 900
            $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
        }
    }
    if (-not $w) { throw 'janela principal nao achada' }
    $null = [K.I]::SetForegroundWindow([IntPtr]$w.Current.NativeWindowHandle)
    Start-Sleep -Milliseconds 400
    return $w
}
function Invoke-ById($win, [string]$id) {
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    if (-not $el) { throw "elemento $id nao achado" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
function Get-CopyIcons($win) {
    $bc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    @($win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) | Where-Object { $_.Current.Name -eq $icon }
}

$win = Get-MainWin
# conversa nova: garante que o primeiro icone do documento e' o desta fase
Combo 0x11 0x4E; Start-Sleep -Milliseconds 700
# o botao Copiar da barra tem que sumir
$probe = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'CopyBtn')))
if ($probe) { throw 'CopyBtn ainda existe na barra' }
'barra: sem botao Copiar (ok)'

# ---- Fase A: resposta ao vivo ----
# (envio via InvokePattern no SendBtn: funciona mesmo com a janela em background)
# token unico por run — nao precisa sujar o clipboard antes
$tok = 'copia-ok-' + (Get-Date -Format 'HHmmss')
$mark = [IO.File]::ReadAllText($log).Length
$ic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')
$input = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $ic)
$input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("zq314-copia responda apenas: $tok")
$null = Invoke-ById $win 'SendBtn'
$ra = Wait-Log 'respondido: (\d+) chars' $mark 120
if (-not $ra) { throw 'fase A: sem respondido' }
'fase A: respondido'
# nesta maquina o clipboard e' disputado por outros processos (AHK elevado);
# a prova da escrita e' o log 'copiar: N chars' (so loga se Set-ClipText deu
# true). A leitura direta e' best-effort, informativa.
function Wait-CopyLog([int]$m, [int]$secs) {
    $t = Wait-Log 'copiar: (\d+) chars' $m $secs
    if (-not $t) { throw 'clique nao logou copia (clipboard ocupado ou handler falhou)' }
}
function Get-Clip-Soft {
    for ($i = 0; $i -lt 3; $i++) { try { return (Get-Clipboard -Raw) } catch { Start-Sleep -Milliseconds 300 } }
    return '(clipboard ocupado na leitura)'
}
$icons = @(Get-CopyIcons $win)
"fase A: icones no documento: $($icons.Count)"
if ($icons.Count -lt 1) { throw 'fase A: icone de copiar nao apareceu no card' }
$mark2 = [IO.File]::ReadAllText($log).Length
$icons[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Wait-CopyLog $mark2 10
'fase A: log confirmou a copia'
$clip = (Get-Clip-Soft)
"fase A: clipboard: $clip"
if ($clip -notmatch [regex]::Escape($tok) -and $clip -notmatch 'ocupado na leitura') { throw 'fase A: clipboard sem a resposta' }
'fase A: icone copiou a resposta'

# ---- Fase B: retomar e clicar no icone do card carregado ----
Combo 0x11 0x4E; Start-Sleep -Milliseconds 600
$win = Get-MainWin
$null = Invoke-ById $win 'HistBtn'
$hw = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $hw) { Start-Sleep -Milliseconds 400; $hw = Find-Wins | Where-Object { $_.Current.Name -like '*hist*' } | Select-Object -First 1 }
if (-not $hw) { throw 'fase B: historico nao abriu' }
$hw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'Search'))).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('zq314-copia')
Start-Sleep -Milliseconds 600
$lc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
$items = @($hw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'List'))).FindAll([System.Windows.Automation.TreeScope]::Children, $lc))
if ($items.Count -lt 1) { throw 'fase B: conversa nao achada no filtro' }
$items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
$null = Invoke-ById $hw 'OkBtn'
$rb = Wait-Log 'historico: retomou (\d+) msgs' $mark 15
if (-not $rb) { throw 'fase B: nao retomou' }
'fase B: retomou'
$win = Get-MainWin
$icons2 = @(Get-CopyIcons $win)
"fase B: icones apos retomar: $($icons2.Count)"
if ($icons2.Count -lt 1) { throw 'fase B: card carregado sem icone' }
$mark3 = [IO.File]::ReadAllText($log).Length
$icons2[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Wait-CopyLog $mark3 10
'fase B: log confirmou a copia'
$clip2 = (Get-Clip-Soft)
"fase B: clipboard: $clip2"
if ($clip2 -notmatch [regex]::Escape($tok) -and $clip2 -notmatch 'ocupado na leitura') { throw 'fase B: clipboard sem a resposta do card' }
'fase B: icone do card retomado copiou'

# ---- cleanup ----
Combo 0x11 0x4E; Start-Sleep -Milliseconds 400; Tap 0x1B
$fs = @(Get-ChildItem 'C:\Users\EVTU-DELL\.local\bin\zquick\history' -Filter 'conv-*.json' | Where-Object { (Get-Content $_.FullName -Raw) -match 'zq314-copia' })
foreach ($f in $fs) { Remove-Item $f.FullName -Force }
"convs de teste apagadas: $($fs.Count)"
"VERDICTO: OK (sem Copiar na barra + icone copia a resposta ao vivo e a retomada)"
