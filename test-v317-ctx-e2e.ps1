# test-v317-ctx-e2e.ps1 - v3.17: medidor ctx mostra CONTAGEM de tokens ao lado do
# percentual ("ctx N% . ~X/200k") e o limite vem do MODELO (tabela + override
# ctxLimits no json), alimentando autocompact e a pergunta. ASCII-only (5.1).
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
function Get-MeterText($win) {
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'ModelText')))
    if (-not $el) { throw 'ModelText (medidor ctx) nao achado' }
    return [string]$el.Current.Name
}
# 'ctx 12% . ~18.2k/200k' -> 18200 (o ponto cobre o separador/maior-ou-aprox, acentuados)
function Get-TokFromMeter([string]$s) {
    if ($s -match 'ctx (\d+)% . .(\d+(?:\.\d+)?)(k?)/(\d+)k') {
        $v = [double]$Matches[2]; if ($Matches[3] -eq 'k') { $v = $v * 1000 }
        return [int]$v
    }
    return -1
}

$mark0 = [IO.File]::ReadAllText($log).Length
trap { for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; throw }

$win = Get-MainWin
# 1. medidor tem contagem + limite do modelo (antes de qualquer envio: 0 tokens)
$t0 = Get-MeterText $win
"medidor antes: $t0"
$limK = 0
if ($t0 -match 'ctx (\d+)% . .(\d+(?:\.\d+)?)(k?)/(\d+)k') { $limK = [int]$Matches[4] } else { throw "medidor sem contagem/limite: '$t0'" }
if (@(128, 200, 256) -notcontains $limK) { throw "limite estranho no medidor: ${limK}k" }
"formato ok: ${limK}k de limite"
$tok0 = Get-TokFromMeter $t0

# 2. envia uma mensagem -> medidor cresce (contagem acompanha a conversa)
Combo 0x11 0x4E; Start-Sleep -Milliseconds 700
$win = Get-MainWin
$tok = 'ctx317-' + (Get-Date -Format 'HHmmss')
$ib = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')))
$ib.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("zq317 responda apenas: $tok")
$null = Invoke-ById $win 'SendBtn'
if (-not (Wait-Log 'respondido: (\d+) chars' $mark0 120)) { throw 'sem respondido' }
'respondido'
Start-Sleep -Milliseconds 800
$win = Get-MainWin
$t1 = Get-MeterText $win
"medidor depois: $t1"
$tok1 = Get-TokFromMeter $t1
if ($tok1 -lt 0) { throw "medidor pos-resposta sem contagem: '$t1'" }
if ($tok1 -le $tok0) { throw "contagem nao cresceu (antes $tok0, depois $tok1)" }
"contagem cresceu: $tok0 -> $tok1 tokens (limite ${limK}k)"

# 3. modelo no rodape continua a abrir o medidor
if ($t1 -notmatch 'ctx \d+%') { throw 'percentual sumiu' }

# cleanup: conversa nova + apagar as de teste
Combo 0x11 0x4E; Start-Sleep -Milliseconds 400; Tap 0x1B
$fs = @(Get-ChildItem 'C:\Users\EVTU-DELL\.local\bin\zquick\history' -Filter 'conv-*.json' | Where-Object { (Get-Content $_.FullName -Raw) -match 'zq317' })
foreach ($f in $fs) { Remove-Item $f.FullName -Force }
"convs de teste apagadas: $($fs.Count)"
"VERDICTO: OK (medidor ctx com contagem de tokens + limite por modelo + cresce com a conversa)"
