# test-memory-ui.ps1 — E2E de memoria entre conversas (Onda 2):
#   memory_save grava fato -> Ctrl+N (conversa NOVA) -> pergunta e' respondida
#   pelo fato injetado no system prompt, sem nova chamada de tool
# Rodar com: pwsh -STA -File test-memory-ui.ps1   (app residente rodando)
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
$memFile = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick-memory.md'
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

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

$memBefore = $null
$existed = Test-Path $memFile
if ($existed) { $memBefore = [IO.File]::ReadAllText($memFile) }
try {
    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    # 1) pede p/ memorizar
    $tb = Set-InputText $w 'use a ferramenta memory_save para memorizar este fato: o servidor de planilhas do usuario fica no endereco 192.168.0.99'
    Click-Center $tb
    Tap 0x0D
    $mark = [IO.File]::ReadAllText($log).Length
    $done = Wait-Log $mark 'respondido: ' 120
    if (-not $done) { throw "turno 1 sem resposta. log: $(Read-New $mark)" }
    if ($done -match 'engine: ') { throw "erro do engine: $done" }
    if (-not (Test-Path $memFile)) { throw 'zquick-memory.md nao foi criado' }
    if (([IO.File]::ReadAllText($memFile) -notmatch '192\.168\.0\.99')) { throw "fato nao gravado na memoria: $(Get-Content $memFile -Raw)" }

    # 2) conversa NOVA: a resposta tem que vir da memoria injetada no system
    $mark2 = [IO.File]::ReadAllText($log).Length
    $tb2 = Find-ById $w 'InputBox'
    Click-Center $tb2
    Combo 0x11 0x4E      # Ctrl+N
    Start-Sleep -Milliseconds 600
    $tb = Set-InputText $w 'qual e o endereco do meu servidor de planilhas? responda só o endereco'
    Click-Center $tb
    Tap 0x0D
    $done2 = Wait-Log $mark2 'respondido: ' 120
    if (-not $done2) { throw "turno 2 sem resposta. log: $(Read-New $mark2)" }
    if ($done2 -match 'engine: ') { throw "erro do engine: $done2" }
    if ($done2 -notmatch '192\.168\.0\.99') { throw "resposta nao citou o fato memorizado. log: $done2" }
    "PASS: memoria E2E — fato gravado e lembrado em conversa NOVA (sem re-perguntar)"
} finally {
    # restaura a memoria pre-teste (nao deixa lixo de teste no estado real do usuario)
    if ($existed) { [IO.File]::WriteAllText($memFile, $memBefore) } elseif (Test-Path $memFile) { Remove-Item $memFile -Force }
    Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 500; Combo 0x12 0x51
}
