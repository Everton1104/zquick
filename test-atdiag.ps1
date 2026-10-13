# test-atdiag.ps1 — diagnostico T7: '@' via SendInput KEYEVENTF_UNICODE chega
# no InputBox? Dialogo abre? (roda ao vivo, imprime cada passo)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
Add-Type -Namespace K -Name S -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
[DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, ref INPUT inp, int size);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder sb, int max);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
"sizeof(INPUT) = $([Runtime.InteropServices.Marshal]::SizeOf([type][K.S+INPUT])) (esperado 40)"

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
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}
function Find-MencaoDialog([uint32]$procId) {
    $script:dlgFound = [IntPtr]::Zero
    $cb = {
        param([IntPtr]$h, [IntPtr]$l)
        $pid2 = [uint32]0
        [void][K.S]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($pid2 -eq $procId -and [K.S]::IsWindowVisible($h)) {
            $cn = New-Object System.Text.StringBuilder 256
            [void][K.S]::GetClassName($h, $cn, 256)
            if ($cn.ToString() -eq '#32770') { $script:dlgFound = $h; return $false }
        }
        return $true
    }
    [void][K.S]::EnumWindows($cb, [IntPtr]::Zero)
    $script:dlgFound
}

$me = $PID
$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' -and $_.ProcessId -ne $me } | Select-Object -First 1
if (-not $app) { throw 'app nao achado' }
"app PID $($app.ProcessId)"

# janela visivel?
$w = Get-MainWin $app.ProcessId
if ($w) { "janela visivel" } else { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
if (-not $w) { throw 'janela nao apareceu' }

$tb = $null
for ($i = 0; $i -lt 8 -and -not $tb; $i++) { $tb = Find-ById $w 'InputBox'; if (-not $tb) { Start-Sleep -Milliseconds 400; $w = Get-MainWin $app.ProcessId } }
if (-not $tb) { throw 'sem InputBox' }
$tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('')

# foca via clique
$p = $tb.GetClickablePoint()
Add-Type -Namespace K -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);'
$null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
Start-Sleep -Milliseconds 80
[K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 500

# injeta '@' UNICODE
$sz = [Runtime.InteropServices.Marshal]::SizeOf([type][K.S+INPUT])
$inp = New-Object K.S+INPUT
$inp.type = 1
$inp.u.ki.wVk = 0; $inp.u.ki.wScan = 0x40; $inp.u.ki.dwFlags = 4
$r1 = [K.S]::SendInput(1, [ref]$inp, $sz)
Start-Sleep -Milliseconds 80
$inp.u.ki.dwFlags = 4 -bor 2
$r2 = [K.S]::SendInput(1, [ref]$inp, $sz)
"SendInput down=$r1 up=$r2 (esperado 1 e 1; 0 = bloqueio/erro)"
"err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"

Start-Sleep -Milliseconds 1500
# dialogo?
$dlg = Find-MencaoDialog ([uint32]$app.ProcessId)
"dialogo #32770: $(if ($dlg -ne [IntPtr]::Zero) { "SIM (h=$dlg)" } else { 'NAO' })"
# quem esta' com foco de teclado + conteudo do campo
$fe = [System.Windows.Automation.AutomationElement]::FocusedElement
"foco: pid=$($fe.Current.ProcessId) id=$($fe.Current.AutomationId) tipo=$($fe.Current.ControlType.ProgrammaticName)"
$w2 = Get-MainWin $app.ProcessId
$txt = if ($w2) { [string]((Find-ById $w2 'InputBox').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Value } else { '(janela sumiu?)' }
"InputBox apos: '$txt'"
if ($dlg -ne [IntPtr]::Zero) { Tap 0x1B; Start-Sleep -Milliseconds 400; "Esc enviado p/ fechar o dialogo" }
