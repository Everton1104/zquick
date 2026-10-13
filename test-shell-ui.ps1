# test-shell-ui.ps1 — E2E T3 (Onda 3): sessão de shell PERSISTENTE.
#   run_ps #1 seta $zqSessao=41 -> ConfirmYes; run_ps #2 (mesma conversa) roda
#   $zqSessao+1 na MESMA sessão -> modelo responde 42 (variável sobreviveu).
# Rodar com: pwsh -STA -File test-shell-ui.ps1   (app residente rodando)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
Add-Type -Namespace K -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
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
        Start-Sleep -Milliseconds 400
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
function Invoke-ById($win, [string]$id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $el) { throw "elemento '$id' nao encontrado via UIA" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $el
}
function Find-ById($win, [string]$id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}
function Set-InputText($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $tb
}
function Click-Center($el) {
    $p = $el.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | log: $ctx" } }

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

try {
    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    # ---- comando 1: cria a variável na sessão persistente ----
    $mark = [IO.File]::ReadAllText($log).Length
    $tb = Set-InputText $w 'use a ferramenta run_ps para executar exatamente este comando: $zqSessao=41 — não confirme o valor, apenas responda "feito"'
    Click-Center $tb
    Tap 0x0D
    if (-not (Wait-Log $mark 'confirma: Comando PowerShell' 90)) { throw "confirmacao 1 nao apareceu. log: $(Read-New $mark)" }
    $null = Invoke-ById $w 'ConfirmYes'
    $t1 = Wait-Log $mark 'respondido: ' 120
    if (-not $t1) { throw "turno 1 sem resposta. log: $(Read-New $mark)" }
    Assert ($t1 -match 'tool: .*run_ps') 'run_ps 1 nao rodou' $t1
    Assert ($t1 -notmatch 'engine: ') 'erro do engine' $t1

    # ---- comando 2: MESMA conversa -> variável tem que existir ----
    $mark2 = [IO.File]::ReadAllText($log).Length
    $tb = Set-InputText $w 'agora use run_ps para executar exatamente: $zqSessao+1 — responda APENAS o número que apareceu na saída'
    Click-Center $tb
    Tap 0x0D
    if (-not (Wait-Log $mark2 'confirma: Comando PowerShell' 90)) { throw "confirmacao 2 nao apareceu. log: $(Read-New $mark2)" }
    $null = Invoke-ById $w 'ConfirmYes'
    $t2 = Wait-Log $mark2 'respondido: ' 120
    if (-not $t2) { throw "turno 2 sem resposta. log: $(Read-New $mark2)" }
    Assert ($t2 -notmatch 'engine: ') 'erro do engine no turno 2' $t2
    $prev = if ($t2 -match 'respondido: \d+ chars em \d+s \| (.+)') { $Matches[1] } else { '(preview?)' }
    Assert ($prev -match '42') "a resposta não contém 42 (sessão não persistiu?): $prev" $t2
    "PASS: shell persistente E2E — `$zqSessao sobreviveu entre chamadas (41+1=42): $prev"
} finally {
    Start-Sleep -Milliseconds 400; Combo 0x11 0x4E; Start-Sleep -Milliseconds 500; Tap 0x1B; Start-Sleep -Milliseconds 500; Combo 0x12 0x51
}
