# test-stop-ui.ps1 — E2E do botao Parar (Onda 1):
#   pergunta longa -> 1o token chega -> clicar SendBtn (agora "⏹ Parar") ->
#   log 'parar: cancel solicitado' + 'respondido: ' com resposta PARCIAL, sem 'engine:'
# Rodar com: pwsh -STA -File test-stop-ui.ps1   (app residente rodando)
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
# InputBox via ValuePattern (caminho com barra invertida nao da p/ digitar com keybd_event)
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

# mostra a janela (Alt+Q e toggle: repete ate abrir)
$w = $null
for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
if (-not $w) { throw 'janela do zquick nao apareceu' }

# botao deve estar em modo enviar ANTES do turno
$btnBefore = Find-ById $w 'SendBtn'
if ($btnBefore.Current.Name -eq '⏹ Parar') { throw 'app estava ocupado antes do teste (turno em curso?)' }

# pergunta de geracao longa sem raciocinio (flash: bloco thinking come o maxTokens —
# ensaio "de 1500 palavras" voltou 0 chars por isso; contagem numera direto)
$tb = Set-InputText $w 'escreva a tabuada de multiplicacao do 1 ao 120, uma linha por conta no formato N x M = R, sem pular nenhuma'
Click-Center $tb          # foco no InputBox p/ o Enter chegar
Tap 0x0D
$mark = [IO.File]::ReadAllText($log).Length

if (-not (Wait-Log $mark '1º token' 110)) { throw "streaming nao comecou. log: $(Read-New $mark)" }
Start-Sleep -Milliseconds 700    # acumula parcial (a tabuada gera por muitos segundos)

$null = Invoke-ById $w 'SendBtn'   # ocupado -> e o botao Parar
if (-not (Wait-Log $mark 'parar: cancel solicitado' 10)) { throw 'clique em Parar nao registrou (turno ja tinha acabado?)' }
$done = Wait-Log $mark 'respondido: ' 40
if (-not $done) { throw "turno nao fechou apos parar. log: $(Read-New $mark)" }
if ($done -match 'engine: ') { throw "erro do engine apos parar: $done" }
if ($done -notmatch 'respondido: (\d+) chars em (\d+)s \| (.+)') { throw 'formato respondido inesperado: ' + $done }
$chars = [int]$Matches[1]
if ($chars -lt 50) { throw "parcial pequena demais ($chars chars) — parou antes de acumular texto?" }

# botao voltou a "Enviar"?
$btn = Find-ById $w 'SendBtn'
if ($btn.Current.Name -ne 'Enviar') { throw "botao nao voltou a Enviar (='$($btn.Current.Name)')" }

# fecha a conversa p/ nao sujar a proxima (Esc esconde; Alt+Q reabre limpa)
Start-Sleep -Milliseconds 500
Tap 0x1B; Start-Sleep -Milliseconds 500
Combo 0x12 0x51
"PASS: parar OK — parcial de $chars chars preservada, botao voltou a Enviar, sem erro do engine"
