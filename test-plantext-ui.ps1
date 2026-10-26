# test-plantext-ui.ps1 — E2E do plano TEXTUAL (v3.21): o modelo escreveu o plano
# como TEXTO na resposta final (sem tool plan) e o turno fechou mudo — o app agora
# oferece o mesmo botão ✅ Aprovar; aprovar envia um novo turno JÁ ISENTO de
# confirmações individuais (_planOk via Ask 6º arg).
#   Fase A (sem modelo): /uitest plantext -> barra aparece -> PlanNo dispensa.
#   Fase B (real, v3.24.1): turno 1 USA uma tool de leitura (file_list) e escreve
#     o plano como TEXTO -> 'plano-texto: botão de aprovação' (o gate novo exige
#     tools no turno — resposta didática sem tool não ganha barra) ->
#     PlanYes -> 'envio:' com PLANO APROVADO -> turno 2 sem 'confirma:' e com
#     '✅ plano:' (isenção em lote) -> pastas zq-tp1/2/3 + nota.txt existem.
#   Requer passthrough OFF (senão GateConfirm aprova tudo e a isenção não é provada) —
#   o teste desliga, roda e religa o estado original.
# Rodar com: pwsh -STA -File test-plantext-ui.ps1   (app residente rodando)
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
function Read-LogText {
    $fs = [IO.FileStream]::new($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Read-New([int]$mark) { try { (Read-LogText).Substring($mark) } catch { Start-Sleep -Milliseconds 300; (Read-LogText).Substring($mark) } }
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        $new = Read-New $mark
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 400
    }
    return ''
}
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
function Get-MainWin([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    foreach ($w in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($w.Current.Name -like '*ZQuick*' -and $w.Current.Name -notlike '*hist*') { return $w }
    }
    $null
}
function Find-ById($win, [string]$id) {
    # retry: durante stream intenso o UI thread não bombeia UIA e FindFirst dá timeout
    for ($t = 0; $t -lt 6; $t++) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
            return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        } catch { Start-Sleep -Milliseconds 700 }
    }
    throw "UIA nao respondeu procurando '$id' (UI thread ocupado?)"
}
function Click-Center($el) {
    $p = $el.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y); Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
function Click-Invoke($el) {
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 300
}
function Send-Line($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    Click-Center $tb
    Tap 0x0D
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | log: $ctx" } }

$desk = [Environment]::GetFolderPath('Desktop')
$dirs = @((Join-Path $desk 'zq-tp1'), (Join-Path $desk 'zq-tp2'), (Join-Path $desk 'zq-tp3'))
$cfgPath = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json'
$passWas = [bool](Get-Content $cfgPath -Raw | ConvertFrom-Json).passthrough

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

try {
    # janela VISÍVEL de verdade (toggle pode esconder; hidden não tem filhos realizados)
    $w = $null
    for ($try = 0; $try -lt 6 -and -not $w; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $cand = Get-MainWin $app.ProcessId
        if ($cand -and (Find-ById $cand 'InputBox')) { $w = $cand }
    }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    # cleanup de run anterior: turno rodando -> Parar; fila -> descarta
    for ($k = 0; $k -lt 15; $k++) {
        $sb = Find-ById $w 'SendBtn'
        $busy = $sb.Current.Name -eq '⏹ Parar'
        $del = Find-ById $w 'QDel1'
        if ($del) { Click-Invoke $del; Start-Sleep -Milliseconds 300; continue }
        if ($busy) {
            $m0 = (Read-LogText).Length
            Click-Invoke $sb
            if (-not (Wait-Log $m0 'respondido: ' 90)) { throw 'Parar não fechou o turno no cleanup' }
            Start-Sleep -Milliseconds 400; continue
        }
        break
    }

    # passthrough OFF (prova a isenção; religa no finally)
    $mark = (Read-LogText).Length
    if ($passWas) {
        Click-Invoke (Find-ById $w 'PassBtn')
        if (-not (Wait-Log $mark 'chrome: passthrough False' 10)) { throw 'nao conseguiu desligar passthrough' }
    }

    # ---- FASE A: barra textual sem modelo (/uitest plantext -> PlanNo dispensa) ----
    $mark = (Read-LogText).Length
    Send-Line $w '/uitest plantext'
    if (-not (Wait-Log $mark 'plano-texto: botão de aprovação oferecido \(3 passos\)' 15)) { throw "fase A: barra nao apareceu. log: $(Read-New $mark)" }
    $py = Find-ById $w 'PlanYes'; $pn = Find-ById $w 'PlanNo'
    Assert ($null -ne $py -and $null -ne $pn) 'fase A: PlanYes/PlanNo nao encontrados' ''
    Click-Invoke $pn
    if (-not (Wait-Log $mark 'plano-texto: dispensado' 10)) { throw "fase A: PlanNo nao dispensou. log: $(Read-New $mark)" }
    "PASS fase A: barra textual aparece e PlanNo dispensa"

    # ---- FASE B: turno com TOOL + plano em texto -> aprovar -> lote isento ----
    # v3.24.1: o gate da barra textual exige tools EXECUTADAS no turno — então o
    # pedido manda listar a Desktop (leitura livre) ANTES de escrever o plano
    $mark = (Read-LogText).Length
    Send-Line $w 'Primeiro use a ferramenta file_list para listar os arquivos da minha Desktop (só isso, não execute mais nada). Depois, DIRETO NO TEXTO DA RESPOSTA, escreva um plano numerado (1. 2. 3.) com exatamente 3 passos para criar na minha Desktop as pastas zq-tp1, zq-tp2 e zq-tp3, cada uma com um arquivo nota.txt dentro (conteúdos: tp ok 1, tp ok 2, tp ok 3). Não use a ferramenta plan, não execute os passos — escreva o plano como texto e PARE.'
    $first = Wait-Log $mark 'respondido: ' 120
    if (-not $first) { throw "fase B: turno 1 nao fechou. log: $(Read-New $mark)" }
    if ($first -match 'plano: .+\(\d+ passos?\)') { throw "fase B: modelo usou tool plan apesar do pedido. log: $first" }
    Assert ($first -match 'tool: ') 'turno 1 nao executou tool (gate novo exige para a barra textual)' $first
    if (-not (Wait-Log $mark 'plano-texto: botão de aprovação oferecido \(\d+ passos\)' 15)) { throw "fase B: deteccao de plano textual nao disparou. log: $(Read-New $mark)" }
    $py = Find-ById $w 'PlanYes'
    Assert ($null -ne $py) 'fase B: PlanYes nao encontrado' ''
    Click-Invoke $py

    if (-not (Wait-Log $mark 'plano-texto: aprovado — executando' 10)) { throw "fase B: aprovacao nao logou. log: $(Read-New $mark)" }

    # 'envio:' só loga a contagem de chars — a mensagem de aprovação aparece no
    # segmento do turno 2 (logo após o respondido do turno 1)
    $mark2 = $mark + $first.Length
    $second = Wait-Log $mark2 'respondido: ' 240
    if (-not $second) { throw "fase B: turno 2 (execucao) nao fechou. log: $(Read-New $mark2)" }
    Assert ($second -match 'envio: ') 'mensagem de aprovacao nao foi enviada (sem 2º envio)' $second
    Assert ($second -notmatch 'confirma:') 'apareceu ConfirmBar no turno aprovado (devia rodar em lote)' $second
    Assert ($second -match '✅ plano:') 'isencao em lote (✅ plano:) nao apareceu no log' $second
    Assert ($second -notmatch 'engine: ') 'erro do engine' $second
    foreach ($d in $dirs) {
        Assert (Test-Path (Join-Path $d 'nota.txt')) "pasta/nota.txt nao criada: $d" $second
    }
    $c1 = Get-Content (Join-Path $dirs[0] 'nota.txt') -Raw
    Assert ($c1 -match 'tp ok 1') "conteudo nota 1 errado: $c1" $second

    "PASS: plano textual E2E — barra no fim do turno, ✅ executa em lote isento, 3 pastas criadas"
} finally {
    foreach ($d in $dirs) { if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
    # religa passthrough se estava ligado
    try {
        if ($passWas) {
            $cur = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
            if ($cur) {
                $root = [System.Windows.Automation.AutomationElement]::RootElement
                $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$cur.ProcessId)
                foreach ($cand in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
                    if ($cand.Current.Name -like '*ZQuick*' -and $cand.Current.Name -notlike '*hist*') {
                        $btn = $null
                        try { $btn = $cand.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PassBtn'))) } catch {}
                        if ($btn) { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); break }
                    }
                }
            }
        }
    } catch { "avisO: nao religou passthrough — confira o ⚡: $_" }
    Start-Sleep -Milliseconds 400; Combo 0x12 0x51
}
