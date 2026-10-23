# test-queue-ui.ps1 — E2E da fila de mensagens (Onda 2, v3.21):
#   pergunta longa rolando -> Enter com nova pergunta vira fila (log 'fila:') ->
#   2ª mensagem ACUMULA (não sobrescreve) -> cartão ✉ visível (QDel/QEdit) ->
#   ✕ descarta a 1ª -> ✎ devolve a 2ª ao InputBox -> Enter re-enfileira ->
#   turno acaba -> 'fila: despachada' -> resposta é a da fila
# Rodar com: pwsh -STA -File test-queue-ui.ps1   (app residente rodando)
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
# leitura tolerante a arquivo aberto pelo app (compartilha read/write em vez de brigar pelo lock)
function Read-LogText {
    $fs = [IO.FileStream]::new($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
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
            $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
            return $el
        } catch { Start-Sleep -Milliseconds 700 }
    }
    throw "UIA nao respondeu procurando '$id' (UI thread ocupado?)"
}
function Set-InputText($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $tb
}
function Get-InputText($win) {
    $tb = Find-ById $win 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
}
function Click-Center($el) {
    $p = $el.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
# Invoke clica o elemento CERTO mesmo coberto por outro painel (o AskBar por cima
# do SendBtn já desviou um clique físico para o botão errado)
function Click-Invoke($el) {
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 300
}

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

# abrir/fechar até a janela estar VISÍVEL de verdade: o toggle pode ESCONDER uma
# janela que já estava aberta, e o UIA lista janela hidden sem filhos realizados
$w = $null
for ($try = 0; $try -lt 6 -and -not $w; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    $cand = Get-MainWin $app.ProcessId
    if ($cand -and (Find-ById $cand 'InputBox')) { $w = $cand }
}
if (-not $w) { throw 'janela do zquick nao apareceu (ou InputBox nao visivel)' }

# cleanup: sobra de run anterior pode ter turno rodando E mensagens na fila (que
# despacham sozinhas quando o turno fecha) — para o turno, descarta a fila, até idle
for ($k = 0; $k -lt 15; $k++) {
    $sb = Find-ById $w 'SendBtn'
    $busy = $sb.Current.Name -eq '⏹ Parar'
    $del = Find-ById $w 'QDel1'
    if ($del) { Click-Invoke $del; Start-Sleep -Milliseconds 300; continue }
    if ($busy) {
        $m0 = (Read-LogText).Length
        Click-Invoke $sb
        if (-not (Wait-Log $m0 'respondido: ' 90)) { throw 'Parar não fechou o turno no cleanup' }
        Start-Sleep -Milliseconds 400
        continue
    }
    break
}
$btnBefore = Find-ById $w 'SendBtn'
if ($btnBefore.Current.Name -eq '⏹ Parar') { throw 'app ainda ocupado apos cleanup' }

# 1) pergunta de geracao longa em TEXTO PURO — sem tools e sem ask_user (o modelo
# resolveu a tabuada antiga com run_ps+arquivo e o turno acabou rápido demais)
$tb = Set-InputText $w 'escreva direto no texto da resposta, sem usar nenhuma ferramenta e sem me perguntar nada: conte de 1 a 300, um número por linha, no formato "N número-por-extenso" (exemplo: 7 sete), sem pular nenhum'
Click-Center $tb
Tap 0x0D
$mark = (Read-LogText).Length
if (-not (Wait-Log $mark '1º token' 110)) { throw "streaming nao comecou. log: $(Read-New $mark)" }
Start-Sleep -Milliseconds 300

# 2) Enter durante a resposta -> fila (1ª mensagem)
$tb = Set-InputText $w 'responda apenas: FILAOK7731'
Click-Center $tb
Tap 0x0D
if (-not (Wait-Log $mark 'fila: \+1 mensagem' 10)) {
    if ((Read-New $mark) -match 'envio: 27') { throw 'turno 1 acabou antes do Enter (geração rápida demais) — aumente o prompt da fase 1' }
    throw "mensagem nao foi para a fila (foi enviada?). log: $(Read-New $mark)"
}
$btn = Find-ById $w 'SendBtn'
if ($btn.Current.Name -ne '⏹ Parar') { throw "botao deveria continuar Parar durante o turno (='$( $btn.Current.Name )')" }

# 3) 2ª mensagem ACUMULA (antes sobrescrevia) e o cartão ✉ aparece com botões
$tb = Set-InputText $w 'responda apenas: FILA2OK9942'
Click-Center $tb
Tap 0x0D
if (-not (Wait-Log $mark 'fila: \+1 mensagem \(.*2 na fila\)' 10)) { throw "2ª mensagem nao acumulou na fila. log: $(Read-New $mark)" }
Start-Sleep -Milliseconds 400
$qdel = Find-ById $w 'QDel1'; $qedit = Find-ById $w 'QEdit1'
if (-not $qdel -or -not $qedit) { throw 'cartao da fila sem botoes QDel1/QEdit1' }

# 4) ✕ descarta a 1ª (FILAOK7731)
Click-Center $qdel
if (-not (Wait-Log $mark 'fila: mensagem descartada' 10)) { throw "✕ nao descartou. log: $(Read-New $mark)" }

# 5) ✎ devolve a 2ª ao InputBox -> conferir texto -> Enter re-enfileira
Click-Center (Find-ById $w 'QEdit1')
if (-not (Wait-Log $mark 'fila: mensagem devolvida' 10)) { throw "✎ nao devolveu. log: $(Read-New $mark)" }
$inbox = Get-InputText $w
if ($inbox -notmatch 'FILA2OK9942') { throw "InputBox deveria ter a mensagem devolvida (='$inbox')" }
Click-Center (Find-ById $w 'InputBox')
Tap 0x0D
if (-not (Wait-Log $mark 'fila: \+1 mensagem \(.*1 na fila\)' 10)) { throw "reenvio da editada nao voltou a fila. log: $(Read-New $mark)" }

# 6) turno 1 acaba -> fila despacha sozinha -> 2º respondido com a mensagem CERTA
$first = Wait-Log $mark 'respondido: ' 330
if (-not $first) { throw "turno 1 nao fechou. log: $(Read-New $mark)" }
if (-not (Wait-Log $mark 'fila: despachada' 30)) { throw "fila nao despachou. log: $(Read-New $mark)" }
$mark2 = $mark + $first.Length
$second = Wait-Log $mark2 'respondido: ' 120
if (-not $second) { throw "turno da fila nao rodou. log: $(Read-New $mark2)" }
if ($second -match 'engine: ') { throw "erro do engine: $second" }
if ($second -notmatch 'FILA2OK9942') { throw "2ª resposta nao foi a da fila. log: $second" }
if ($second -match 'FILAOK7731') { throw "a mensagem descartada foi enviada! log: $second" }

Start-Sleep -Milliseconds 500
Tap 0x1B; Start-Sleep -Milliseconds 500
Combo 0x12 0x51
"PASS: fila E2E v3.21 — acumula, cartão ✉ com ✎/✕, descarta, edita, despacha a certa"
