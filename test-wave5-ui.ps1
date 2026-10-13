# test-wave5-ui.ps1 — E2E da Onda 5 (app residente, oraculo = zquick.log):
#   fase 1: cria skills\teste-onda5.md ao lado do app + restart (lista de skills nasce
#           com o engine) — a skill manda comecar a resposta com ZQ5-SKILL-OK-777
#   fase 2: pergunta que usa a tool research (subagente de leitura) num temp dir com
#           marcador -> 'tool: 🤖 subagente' no log + resposta comecando com b.txt
#   fase 3: pergunta que carrega a skill -> 'tool: ⚙ skill_read' + ZQ5-SKILL-OK-777
#   fase 4: remove a skill de teste + restart (volta ao estado original)
# Rodar com: pwsh -STA -File test-wave5-ui.ps1
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
$skillDir = Join-Path $PSScriptRoot 'skills'
$skillFile = Join-Path $skillDir 'teste-onda5.md'
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
function Read-LogText {
    # o app segura o log por instantes no Add-Content — leitura com retry
    for ($i = 0; $i -lt 10; $i++) {
        try { return [IO.File]::ReadAllText($log) } catch { Start-Sleep -Milliseconds 150 }
    }
    throw 'log travado para leitura'
}
function Read-New([int]$mark) { (Read-LogText).Substring($mark) }
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        $new = Read-New $mark
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 500
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
function Restart-App {
    $mark = (Read-LogText).Length
    $null = schtasks /End /TN ZQuick 2>$null
    Start-Sleep -Milliseconds 1200
    Get-CimInstance Win32_Process -Filter "Name LIKE 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 1200
    $null = schtasks /Run /TN ZQuick
    if (-not (Wait-Log $mark 'hotkey .* -> True' 45)) { throw 'app nao reiniciou (sem hotkey no log)' }
    Start-Sleep -Milliseconds 600
}
function Ask-Ui([string]$text) {
    $app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' -and $_.ProcessId -ne $PID } | Select-Object -First 1
    if (-not $app) { throw 'processo zquick nao achado' }
    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }
    $tb = Find-ById $w 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $p = $tb.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
    (Read-LogText).Length
}

$fix = Join-Path $env:TEMP ('zquick-w5-' + (Get-Date -Format 'HHmmss'))
$cleaned = $false
try {
    New-Item -ItemType Directory -Force $fix | Out-Null
    Set-Content -Path (Join-Path $fix 'a.txt') -Value 'conteudo comum alfa' -Encoding utf8
    Set-Content -Path (Join-Path $fix 'b.txt') -Value "linha neutra`nZQ5-SUB-777 marcador secreto da onda cinco`noutra" -Encoding utf8
    Set-Content -Path (Join-Path $fix 'c.txt') -Value 'conteudo comum gama' -Encoding utf8

    # fase 1: skill de teste ao lado do app + restart (a lista nasce com o engine)
    New-Item -ItemType Directory -Force $skillDir | Out-Null
    Set-Content -Path $skillFile -Encoding utf8 -Value @'
---
name: teste-onda5
description: Skill de teste E2E — responde com frase fixa
---
Quando esta skill for carregada, comece IMEDIATAMENTE a resposta com a frase exata
ZQ5-SKILL-OK-777 e depois explique em 1 frase que isto foi um teste de skill.
'@
    Restart-App
    'fase 1: skill de teste criada em skills\, app reiniciado'

    # fase 2: research (subagente de leitura)
    $mark = Ask-Ui "use a tool research com esta tarefa autocontida: na pasta $fix um dos arquivos contem o marcador ZQ5-SUB-777; descubra qual e reporte o nome e a linha. Depois responda em 1 frase COMECANDO com o nome do arquivo (ex.: 'b.txt — ...') e o que a linha diz"
    $sub = Wait-Log $mark 'tool: .*subagente|engine: |FATAL' 200
    if (-not $sub) { throw "fase 2: subagente nao apareceu no log. log: $(Read-New $mark)" }
    $done = Wait-Log $mark 'respondido: |engine: |FATAL' 240
    if (-not $done) { throw "fase 2 sem resposta. log: $(Read-New $mark)" }
    if ($done -match 'FATAL') { throw "fase 2 FATAL: $done" }
    if ($done -notmatch 'subagente') { throw "fase 2: status de subagente nao logado. log: $done" }
    if ($done -notmatch 'relat.rio pronto') { throw "fase 2: subagente nao fechou relatorio. log: $done" }
    if ($done -notmatch 'respondido: \d{2,} chars') { throw "fase 2: resposta vazia. log: $done" }
    if ($done -notmatch 'b\.txt') { throw "fase 2: resposta/preview sem b.txt. log: $done" }
    'PASS fase 2: research E2E — subagente rodou, relatou e a resposta citou b.txt'
    Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 700

    # fase 3: skill_read
    $mark = Ask-Ui 'carregue a skill teste-onda5 (com skill_read) e faca exatamente o que ela manda'
    $sk = Wait-Log $mark 'tool: .*skill_read|engine: |FATAL' 120
    if (-not $sk) { throw "fase 3: skill_read nao apareceu. log: $(Read-New $mark)" }
    $done = Wait-Log $mark 'respondido: |engine: |FATAL' 180
    if (-not $done) { throw "fase 3 sem resposta. log: $(Read-New $mark)" }
    if ($done -match 'FATAL') { throw "fase 3 FATAL: $done" }
    if ($done -notmatch 'skill_read') { throw "fase 3: skill_read nao logada. log: $done" }
    if ($done -notmatch 'ZQ5-SKILL-OK-777') { throw "fase 3: resposta sem a frase da skill. log: $done" }
    'PASS fase 3: skills E2E — skill_read rodou e a resposta comecou com a frase da skill'
    Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 700
}
finally {
    # fase 4: remove skill de teste + restart (estado original)
    try {
        Remove-Item -LiteralPath $skillFile -Force -ErrorAction SilentlyContinue
        $cleaned = $true
        if (-not @(Get-ChildItem -LiteralPath $skillDir -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $skillDir -Force -ErrorAction SilentlyContinue
        }
        Restart-App
        'fase 4: skill de teste removida, app reiniciado no estado original'
    } catch { "AVISO fase 4: falha ao limpar/reiniciar — $_" }
    Remove-Item $fix -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $cleaned) { throw 'SKILL DE TESTE NAO REMOVIDA — apagar skills\teste-onda5.md na mao!' }
}
'PASS: wave5 E2E completo'
