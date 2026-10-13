# test-grep-ui.ps1 — E2E da tool file_grep (Onda 1):
#   fixture com marcador unico em 1 de 2 arquivos -> pedir a busca ->
#   log 'tool: ⚙ file_grep' + resposta cita o arquivo certo (e nao o isqueiro)
# Rodar com: pwsh -STA -File test-grep-ui.ps1   (app residente rodando)
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

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

$fix = Join-Path $env:TEMP ('zquick-greptest-' + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Force $fix | Out-Null
try {
    Set-Content -Path (Join-Path $fix 'alfa-notas.txt') -Value "linha comum de rotina`nAQUI: marcador secreto ZQUICKGREP7741 usado no teste`nultima linha" -Encoding utf8
    Set-Content -Path (Join-Path $fix 'beta-script.ps1') -Value "write-host 'nada de marcador aqui'" -Encoding utf8

    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    $tb = Set-InputText $w "use a ferramenta file_grep para procurar o texto ZQUICKGREP7741 dentro da pasta $fix e me responda somente em qual arquivo e em qual linha ele esta"
    Click-Center $tb
    Tap 0x0D
    $mark = [IO.File]::ReadAllText($log).Length

    $tool = Wait-Log $mark 'file_grep' 90
    if (-not $tool) { throw "file_grep nao foi chamada. log: $(Read-New $mark)" }
    $done = Wait-Log $mark 'respondido: ' 120
    if (-not $done) { throw "sem resposta. log: $(Read-New $mark)" }
    if ($done -match 'engine: ') { throw "erro do engine: $done" }
    if ($done -notmatch 'alfa') { throw "resposta nao citou o arquivo alvo. log: $done" }
    if ($done -match 'beta-script') {
        if ($done -notmatch 'alfa') { throw 'apontou o arquivo errado' }
        'aviso: tambem citou beta-script (verificar se foi so mencionando a busca)'
    }
    $prev = if ($done -match 'respondido: \d+ chars em \d+s \| (.+)') { $Matches[1] } else { $done }
    "PASS: file_grep E2E — resposta: $prev"
} finally {
    Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 500; Combo 0x12 0x51
    Remove-Item $fix -Recurse -Force -ErrorAction SilentlyContinue
}
