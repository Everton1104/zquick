# test-ask-ui.ps1 — E2E do ask_user (multipla escolha estilo Claude Code):
#   fase 1: escolha simples  (modelo pergunta, UIA clica AskOpt1, modelo confirma)
#   fase 2: multiSelect      (2 toggles + Confirmar escolhas)
#   fase 3: texto livre      (✎ Outra resposta… + Enviar)
# Rodar com: pwsh -STA -File test-ask-ui.ps1   (app residente rodando)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
Add-Type -Namespace K -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
'@
function Click-Center($el) {
    $p = $el.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
function Focus-Input($win) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')
    $tb = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if ($tb) { Click-Center $tb }
}
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
function Clear-Input {
    [K.I]::keybd_event(0x11,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    Tap 0x41
    [K.I]::keybd_event(0x11,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    Tap 0x2E
}
function Type-It([string]$text) {
    Clear-Input
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq ' ') { Tap 0x20 }
        elseif ($ch -eq ',') { Tap 0xBC }
        elseif ($ch -eq '.') { Tap 0xBE }
        else { Tap ([byte][int][char]::ToUpper($ch)) }
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 400
}
function Find-WindowsByProc([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))
}
function Get-MainWin([int]$procId) {
    @(Find-WindowsByProc $procId) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
}
function Invoke-ById($win, [string]$id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $btn) { throw "elemento '$id' nao encontrado via UIA" }
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Get-AskOpts($win) {
    $found = @()
    foreach ($i in 1..4) {
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, "AskOpt$i")
        $b = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($b) { $found += "AskOpt$i" }
    }
    $found
}
function Show-Window([int]$procId) {
    for ($try = 0; $try -lt 4; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $w = Get-MainWin $procId
        if ($w) { return $w }
    }
    throw 'janela do zquick nao apareceu'
}
# envia pergunta e espera o painel ask (log 'ask: ') — devolve mark APOS o ask aparecer
function Ask-And-Wait-Panel([string]$text) {
    $w0 = Get-MainWin $app.ProcessId
    if ($w0) { Focus-Input $w0 }
    Type-It $text
    Tap 0x0D
    $mark = [IO.File]::ReadAllText($log).Length
    $new = Wait-Log $mark 'ask: ' 90
    if (-not $new) { throw "painel ask nao apareceu. log: $(Read-New $mark)" }
    Start-Sleep -Milliseconds 700   # deixa o painel renderizar
    return $mark
}
# espera o turno terminar apos responder o ask
function Wait-Turn([int]$mark) {
    $new = Wait-Log $mark 'respondido: ' 90
    if ($new -match 'respondido: (\d+) chars em (\d+)s \| (.+)') { return $Matches[3] }
    if ($new -match 'engine: (.+)') { return "ERRO: $($Matches[1])" }
    return "TIMEOUT/sem resposta: $new"
}

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }
$results = @()

# ---------- fase 1: escolha simples ----------
[void](Show-Window $app.ProcessId)
$mark = Ask-And-Wait-Panel 'use a ferramenta ask_user para me perguntar se eu prefere cafe ou cha. depois que eu escolher responda em uma frase so repetindo a minha escolha'
$w = Get-MainWin $app.ProcessId
Invoke-ById $w 'AskOpt1'
$r1 = Wait-Turn $mark
"fase1 (escolha simples): $r1"
$results += "fase1: turno completou = $(-not ($r1 -match 'ERRO|TIMEOUT'))"

# ---------- fase 2: multiSelect (adaptativa: valida multi se o modelo passar o flag) ----------
$mark = Ask-And-Wait-Panel 'agora use ask_user para me perguntar quais frutas eu quero, com exatamente as tres opcoes banana maca e uva, e obrigatoriamente com multiSelect definido como true. nao use note_add. depois que eu escolher responda em uma frase listando so as que eu escolhi'
$w = Get-MainWin $app.ProcessId
$opts = Get-AskOpts $w
if ($opts.Count -lt 2) { throw "fase2: menos de 2 opcoes no painel ($($opts.Count))" }
$multi = (Read-New $mark) -match '\[multi\]'   # modo vem do log (UIA acha ate Collapsed)
if ($multi) {
    Invoke-ById $w $opts[0]
    Invoke-ById $w $opts[$opts.Count - 1]
    Invoke-ById $w 'AskOkBtn'
    $modo = 'multi'
} else {
    'fase2: modelo NAO passou multiSelect — validando como escolha simples'
    Invoke-ById $w $opts[0]
    $modo = 'simples (fallback)'
}
$r2 = Wait-Turn $mark
"fase2 ($modo): $r2"
$results += "fase2: turno completou = $(-not ($r2 -match 'ERRO|TIMEOUT'))"
$results += "fase2: multiSelect respeitado = $multi"

# ---------- fase 3: texto livre ----------
$mark = Ask-And-Wait-Panel 'agora use ask_user para me perguntar meu animal favorito. depois que eu responder responda em uma frase repetindo o que eu escrevi'
$w = Get-MainWin $app.ProcessId
Invoke-ById $w 'AskOtherBtn'
Start-Sleep -Milliseconds 500
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'AskInput')
$tb = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
if (-not $tb) { throw 'AskInput nao encontrado' }
$tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('capivara dourada')
Invoke-ById $w 'AskSendBtn'
$r3 = Wait-Turn $mark
"fase3 (texto livre): $r3"
$results += "fase3: turno completou = $(-not ($r3 -match 'ERRO|TIMEOUT'))"
$results += "fase3: ecoou texto = $($r3 -match 'capivara')"

# fecha a conversa (Esc) p/ nao sujar a proxima
Start-Sleep -Milliseconds 500
Tap 0x1B; Start-Sleep -Milliseconds 600
Combo 0x12 0x51; Start-Sleep -Milliseconds 400
$results
if ($results -match 'False') { throw 'alguma fase falhou' }
'PASS: ask_user E2E completo'
