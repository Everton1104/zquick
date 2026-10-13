# test-panel-ui.ps1 — E2E T4+T5 (Onda 3): paineis ask_user multi-pergunta e plan.
#   T4: '/uitest ask2' -> AskBar com 2 perguntas; UIA clica AskQ1Opt1 (Resumo) +
#       toggles AskQ2Opt1 (Gráficos) e AskQ2Opt2 (Fontes) + AskOkBtn ->
#       log 'ask resposta: ✅ Resumo · ✅ Gráficos + Fontes'.
#   T5: '/uitest plan' -> PlanBar 'Teste de plano (uitest) (3 passos)' ->
#       UIA PlanYes -> log 'plano: aprovado'.
# Rodar com: pwsh -STA -File test-panel-ui.ps1   (app residente rodando)
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
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        $new = Read-New $mark
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 300
    }
    return ''
}
function Get-MainWin([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    foreach ($w in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($w.Current.Name -like '*ZQuick*' -and $w.Current.Name -notlike '*hist*') { return $w }
    }
    $null
}
function Find-ById($win, [string]$id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}
function Invoke-ById($win, [string]$id) {
    $el = Find-ById $win $id
    if (-not $el) { throw "elemento '$id' nao encontrado" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 250
    $el
}
function Set-InputText($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $tb
}
function Send-Line($win, [string]$text) {
    $tb = Set-InputText $win $text
    $p = $tb.GetClickablePoint()
    $null = Add-Type -Namespace K -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);'
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | log: $ctx" } }

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

try {
    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    # ---- T4: /uitest ask2 -> painel 2 perguntas ----
    $mark = [IO.File]::ReadAllText($log).Length
    Send-Line $w '/uitest ask2'
    $t4 = Wait-Log $mark 'uitest: ask2|ask: 2 perguntas' 15
    if (-not $t4) { throw "T4: painel ask nao abriu. log: $(Read-New $mark)" }
    # (AskBar e' um Border — sem automation peer; os botoes e' que aparecem na UIA)
    Invoke-ById $w 'AskQ1Opt1' | Out-Null   # Resumo
    Invoke-ById $w 'AskQ2Opt1' | Out-Null   # Gráficos (toggle)
    Invoke-ById $w 'AskQ2Opt2' | Out-Null   # Fontes (toggle)
    Invoke-ById $w 'AskOkBtn'  | Out-Null   # confirmar escolhas
    $t4b = Wait-Log $mark 'ask resposta: ' 10
    if (-not $t4b) { throw "T4: sem 'ask resposta'. log: $(Read-New $mark)" }
    Assert ($t4b -match 'ask resposta: ✅ Resumo · ✅ Gráficos \+ Fontes') 'resposta do painel veio errada' $t4b
    "T4 OK — $($Matches[0])"

    # ---- T5: /uitest plan -> PlanBar ----
    $mark2 = [IO.File]::ReadAllText($log).Length
    Send-Line $w '/uitest plan'
    $t5 = Wait-Log $mark2 'plano: Teste de plano \(uitest\) \(3 passos\)' 15
    if (-not $t5) { throw "T5: PlanBar nao abriu. log: $(Read-New $mark2)" }
    Invoke-ById $w 'PlanYes' | Out-Null
    $t5b = Wait-Log $mark2 'plano: aprovado' 10
    if (-not $t5b) { throw "T5: plano nao aprovado. log: $(Read-New $mark2)" }
    "T5 OK — plano proposto (3 passos) e aprovado via UIA"
    "PASS: paineis ask2 + plan E2E"
} finally {
    Start-Sleep -Milliseconds 400; Combo 0x11 0x4E; Start-Sleep -Milliseconds 500; Tap 0x1B; Start-Sleep -Milliseconds 500; Combo 0x12 0x51
}
