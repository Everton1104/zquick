# test-queue-ui.ps1 — E2E da fila de mensagens (Onda 2):
#   pergunta longa rolando -> Enter com nova pergunta vira fila (log 'fila:') ->
#   turno acaba -> 'fila: despachada' -> 2º respondido com a resposta da fila
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

$w = $null
for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
if (-not $w) { throw 'janela do zquick nao apareceu' }

$btnBefore = Find-ById $w 'SendBtn'
if ($btnBefore.Current.Name -eq '⏹ Parar') { throw 'app estava ocupado antes do teste' }

# 1) pergunta de geracao longa (fica rodando bastante tempo)
$tb = Set-InputText $w 'escreva a tabuada de multiplicacao do 1 ao 90, uma linha por conta no formato N x M = R, sem pular nenhuma'
Click-Center $tb
Tap 0x0D
$mark = [IO.File]::ReadAllText($log).Length
if (-not (Wait-Log $mark '1º token' 110)) { throw "streaming nao comecou. log: $(Read-New $mark)" }
Start-Sleep -Milliseconds 800

# 2) Enter durante a resposta -> fila
$tb = Set-InputText $w 'responda apenas: FILAOK7731'
Click-Center $tb
Tap 0x0D
if (-not (Wait-Log $mark 'fila: \+1 mensagem' 10)) { throw "mensagem nao foi para a fila (foi enviada?). log: $(Read-New $mark)" }
$btn = Find-ById $w 'SendBtn'
if ($btn.Current.Name -ne '⏹ Parar') { throw "botao deveria continuar Parar durante o turno (='$( $btn.Current.Name )')" }

# 3) turno 1 acaba -> fila despacha sozinha -> 2º respondido
$first = Wait-Log $mark 'respondido: ' 240
if (-not $first) { throw "turno 1 nao fechou. log: $(Read-New $mark)" }
if (-not (Wait-Log $mark 'fila: despachada' 30)) { throw "fila nao despachou. log: $(Read-New $mark)" }
$mark2 = $mark + $first.Length
$second = Wait-Log $mark2 'respondido: ' 120
if (-not $second) { throw "turno da fila nao rodou. log: $(Read-New $mark2)" }
if ($second -match 'engine: ') { throw "erro do engine: $second" }
if ($second -notmatch 'FILAOK7731') { throw "2ª resposta nao foi a da fila. log: $second" }

Start-Sleep -Milliseconds 500
Tap 0x1B; Start-Sleep -Milliseconds 500
Combo 0x12 0x51
"PASS: fila E2E — mensagem enfileirada durante a resposta e despachada sozinha no fim do turno"
