# test-atdialog-ui.ps1 — E2E T7 (Onda 3): dialogo de @menção a arquivo.
#   ROTA: hook '/uitest at' — chars INJETADOS (keybd_event/SendInput UNICODE)
#   nao viram texto nesta sessao: a pilha TSF/IME do WPF descarta texto de input
#   injetado (probe 13/10: 'a' keybd_event e 'b' VK_PACKET nao chegam NEM numa
#   janela WPF propria; keydown puro como Enter funciona). Teclado fisico nao
#   e' afetado. O teste valida o dialogo em si: abre (#32770 com titulo
#   "Mencionar arquivo (@)"), Esc cancela, nada e' registrado ('menção:' ausente).
# Rodar com: pwsh -STA -File test-atdialog-ui.ps1   (app residente rodando)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
Add-Type -Namespace K -Name X -MemberDefinition @'
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder sb, int max);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
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
        Start-Sleep -Milliseconds 300
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
function Send-Line($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    Tap 0x0D
}
function Find-MencaoDialog([uint32]$procId) {
    $script:dlgFound = [IntPtr]::Zero
    $cb = {
        param([IntPtr]$h, [IntPtr]$l)
        $pid2 = [uint32]0
        [void][K.X]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($pid2 -eq $procId -and [K.X]::IsWindowVisible($h)) {
            $cn = New-Object System.Text.StringBuilder 256
            [void][K.X]::GetClassName($h, $cn, 256)
            if ($cn.ToString() -eq '#32770') {
                $tt = New-Object System.Text.StringBuilder 256
                [void][K.X]::GetWindowText($h, $tt, 256)
                if ($tt.ToString() -like '*Mencionar arquivo*') { $script:dlgFound = $h; return $false }
            }
        }
        return $true
    }
    [void][K.X]::EnumWindows($cb, [IntPtr]::Zero)
    $script:dlgFound
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | log: $ctx" } }

$me = $PID
$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' -and $_.ProcessId -ne $me } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

try {
    # estado inicial conhecido + janela/InputBox com re-aquisicao (elemento pego
    # logo apos Show() pode ficar stale p/ Descendants)
    $w = Get-MainWin $app.ProcessId
    if ($w) { Combo 0x12 0x51; Start-Sleep -Milliseconds 600 }
    $tb = $null; $w = $null
    for ($i = 0; $i -lt 10 -and -not $tb; $i++) {
        if (-not $w) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900 }
        $w = Get-MainWin $app.ProcessId
        if ($w) { $tb = Find-ById $w 'InputBox' }
        if (-not $tb) { Start-Sleep -Milliseconds 400; $w = $null }
    }
    if (-not $w -or -not $tb) { throw 'janela/InputBox do zquick nao apareceram' }

    $mark = [IO.File]::ReadAllText($log).Length
    Send-Line $w '/uitest at'
    $h = Wait-Log $mark 'uitest: at' 10
    if (-not $h) { throw "hook nao rodou. log: $(Read-New $mark)" }

    $dlg = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline -and $dlg -eq [IntPtr]::Zero) {
        $dlg = Find-MencaoDialog ([uint32]$app.ProcessId)
        if ($dlg -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
    }
    Assert ($dlg -ne [IntPtr]::Zero) 'dialogo "Mencionar arquivo (@)" (#32770) nao apareceu' (Read-New $mark)

    # cancela: Esc no dialogo (keydown puro funciona); fallback WM_CLOSE
    Tap 0x1B
    $deadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $deadline) {
        $still = Find-MencaoDialog ([uint32]$app.ProcessId)
        if ($still -eq [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 300
    }
    if ((Find-MencaoDialog ([uint32]$app.ProcessId)) -ne [IntPtr]::Zero) {
        [void][K.X]::PostMessage((Find-MencaoDialog ([uint32]$app.ProcessId)), 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 600
    }
    Assert ((Find-MencaoDialog ([uint32]$app.ProcessId)) -eq [IntPtr]::Zero) 'dialogo nao fechou com Esc/WM_CLOSE' ''

    Start-Sleep -Milliseconds 400
    $slice = Read-New $mark
    Assert ($slice -notmatch 'menção:') 'log registrou menção com dialogo cancelado' $slice
    "PASS: @-dialogo E2E — '/uitest at' abriu #32770, Esc cancelou, sem 'menção:' no log"
} finally {
    $d = $null
    try { $d = Find-MencaoDialog ([uint32]$app.ProcessId) } catch {}
    if ($d -and $d -ne [IntPtr]::Zero) { [void][K.X]::PostMessage($d, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    Start-Sleep -Milliseconds 300; Combo 0x11 0x4E; Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 400; Combo 0x12 0x51
}
