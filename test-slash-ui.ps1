# test-slash-ui.ps1 — Onda 8: slash commands do usuário na UI real (E2E).
# Cria commands\zz-probe.md temporário, envia '/zz-probe ALPHA-BETA',
# confere expansão no log + turno respondido; /zz-naoexiste NÃO envia.
# Roda contra a instância dev (pwsh -File zquick.ps1) em execução.
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
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        try { $new = (Read-LogText).Substring($mark) } catch { $new = '' }
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
    [K.I]::keybd_event($mod,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 250
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
    for ($t = 0; $t -lt 6; $t++) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
            return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        } catch { Start-Sleep -Milliseconds 600 }
    }
    throw "UIA nao respondeu procurando '$id'"
}
function Click-Center($el) {
    $p = $el.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y); Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
function Click-Invoke($el) { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep -Milliseconds 350 }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FALHOU: $msg" } }

$cmdFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'commands\zz-probe.md'
$null = New-Item -ItemType Directory -Force (Split-Path -Parent $cmdFile)
Set-Content $cmdFile 'Responda apenas: PROBE $ARGUMENTS' -Encoding UTF8

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'dev instance nao rodando' }
try {
    $w = $null
    for ($try = 0; $try -lt 6 -and -not $w; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $cand = Get-MainWin $app.ProcessId
        if ($cand -and (Find-ById $cand 'InputBox')) { $w = $cand }
    }
    if (-not $w) { throw 'janela nao apareceu' }
    # cleanup: turno rodando -> Parar
    for ($k = 0; $k -lt 10; $k++) {
        $sb = Find-ById $w 'SendBtn'
        if ($sb.Current.Name -eq [string][char]0x23F9 + ' Parar') {
            $m0 = (Read-LogText).Length
            Click-Invoke $sb
            $null = Wait-Log $m0 'respondido: ' 90
            Start-Sleep -Milliseconds 400
        } else { break }
    }

    # 1. /zz-probe ALPHA-BETA -> expande e envia
    $mark = (Read-LogText).Length
    $tb = Find-ById $w 'InputBox'
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('/zz-probe ALPHA-BETA')
    $p = $tb.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y); Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
    $hit = Wait-Log $mark 'slash: /zz-probe expandido' 10
    Assert ($hit -ne '') "expansao nao logada. log: $((Read-LogText).Substring($mark))"
    "PASS 1: '/zz-probe' -> 'slash: /zz-probe expandido' no log"
    $seg = Wait-Log $mark 'respondido: ' 120
    Assert ($seg -ne '') "turno do slash nao fechou. log: $((Read-LogText).Substring($mark))"
    Assert ($seg -notmatch 'engine: ') 'erro de engine no turno do slash'
    "PASS 2: turno enviado com o prompt expandido e respondido"

    # 2. /zz-naoexiste -> NAO envia (hint no status, nada no log)
    $mark = (Read-LogText).Length
    $tb = Find-ById $w 'InputBox'
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('/zz-naoexiste teste')
    $p = $tb.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y); Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
    Start-Sleep -Seconds 4
    $seg = (Read-LogText).Substring($mark)
    Assert ($seg -notmatch 'envio:') "comando desconhecido ENVIOU algo: $seg"
    Assert ($seg -notmatch 'slash:') "comando desconhecido logou slash: $seg"
    "PASS 3: '/zz-naoexiste' nao envia (hint no status, nada pro modelo)"

    Assert (-not ((Read-LogText).Substring($mark) -match 'FATAL')) 'FATAL no log'
    'VERDICTO: OK (slash commands: expansão $ARGUMENTS + turno real + desconhecido não envia)'
} finally {
    Remove-Item $cmdFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300; Combo 0x12 0x51
}
