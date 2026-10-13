# test-always-ui.ps1 — E2E do "✔ Sempre" (Onda 2):
#   run_ps confirmado com "Sempre" grava regra no zquick.json ->
#   mesma comando de novo roda SEM confirmacao
# Rodar com: pwsh -STA -File test-always-ui.ps1   (app residente rodando)
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
$cfgFile = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json'
$cmd = 'echo ZQUICK-ALWAYS-7742'
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

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

$cfgBefore = [IO.File]::ReadAllText($cfgFile)
try {
    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    # 1) comando novo -> confirma -> clica "✔ Sempre"
    $tb = Set-InputText $w "use a ferramenta run_ps para executar exatamente este comando: $cmd"
    Click-Center $tb
    Tap 0x0D
    $mark = [IO.File]::ReadAllText($log).Length
    if (-not (Wait-Log $mark 'confirma: Comando PowerShell' 90)) { throw "confirmacao nao apareceu. log: $(Read-New $mark)" }
    $null = Invoke-ById $w 'ConfirmAlwaysBtn'
    $done = Wait-Log $mark 'respondido: ' 120
    if (-not $done) { throw "turno 1 sem resposta. log: $(Read-New $mark)" }
    if ($done -match 'engine: ') { throw "erro do engine: $done" }
    if (-not (Wait-Log $mark 'sempre permitir: run_ps' 10)) { throw "regra nao foi gravada no log. log: $(Read-New $mark)" }
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if (-not $j.allow -or -not $j.allow.runPs -or (@($j.allow.runPs) -notcontains $cmd)) { throw "regra nao apareceu no zquick.json: $(Get-Content $cfgFile -Raw)" }

    # 2) MESMO comando de novo -> tem que rodar SEM confirmacao
    $mark2 = [IO.File]::ReadAllText($log).Length
    $tb = Set-InputText $w "rode de novo com run_ps exatamente o mesmo comando: $cmd"
    Click-Center $tb
    Tap 0x0D
    $done2 = Wait-Log $mark2 'respondido: ' 120
    if (-not $done2) { throw "turno 2 sem resposta. log: $(Read-New $mark2)" }
    if ($done2 -match 'engine: ') { throw "erro do engine: $done2" }
    # $done2 = trecho do mark2 ate o 2º respondido: e' exatamente a janela do turno 2
    if ($done2 -match 'confirma: ') { throw "pediu confirmacao de novo (regra nao aplicou). log: $done2" }
    "PASS: sempre-permitir E2E — regra gravada no json e 2ª execução sem confirmacao"
} finally {
    # restaura o json pre-teste (o engine em memoria guarda a regra ate reiniciar; json limpo)
    [IO.File]::WriteAllText($cfgFile, $cfgBefore)
    Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 500; Combo 0x12 0x51
}
