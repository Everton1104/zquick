# probe-matrix-cycle.ps1 — reproduz o ciclo do usuario (matrix -> aplicar ->
# padrao -> aplicar) lendo o log instrumentado (winbg pos-apply / themeprobe)
# a cada passo. Nao deixa lixo: termina com padrao aplicado (= estado atual do
# json do usuario, theme=null/defaults).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
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
    [K.I]::keybd_event($mod,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 200
}
function Find-ById($win, [string]$id) {
    for ($t = 0; $t -lt 6; $t++) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
            return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        } catch { Start-Sleep -Milliseconds 700 }
    }
    throw "UIA timeout '$id'"
}
function Invoke-ById($win, [string]$id) {
    $el = Find-ById $win $id
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'zquick nao esta rodando' }
$root = [System.Windows.Automation.AutomationElement]::RootElement
$pcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$app.ProcessId)
function Find-Wins {
    $c = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond))
    $mw = $c | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*configura*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
$w = $null
for ($try = 0; $try -lt 6 -and -not $w; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    $w = Find-Wins | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*configura*' -and $_.Current.Name -notlike '*hist*' -and (Find-ById $_ 'InputBox') } | Select-Object -First 1
}
if (-not $w) { throw 'janela principal nao acessivel' }
'janela ok'

function Send-Cmd([string]$cmd) {
    $mark = (Read-LogText).Length
    $tb = Find-ById $w 'InputBox'
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($cmd)
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($cmd)
    $p = $tb.GetClickablePoint()
    Add-Type -Namespace K -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
'@ -ErrorAction SilentlyContinue
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y); Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
    return $mark
}

function Apply-Theme([string]$name) {
    $null = Invoke-ById $w 'SettingsBtn'
    $sw = $null; $dl = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $dl -and -not $sw) {
        Start-Sleep -Milliseconds 400
        $sw = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1
    }
    if (-not $sw) { throw 'configuracoes nao abriram' }
    $tc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 700
    $cb = Find-ById $sw 'SetThemeList'
    $cb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Start-Sleep -Milliseconds 400
    $lic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $li = @($cb.FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic)) | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
    if (-not $li) { throw "tema '$name' nao achado na lista" }
    $li.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 300
    try { $cb.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch {}
    $null = Invoke-ById $sw 'SetThemeLoad'
    Start-Sleep -Milliseconds 300
    $mark = (Read-LogText).Length
    $null = Invoke-ById $sw 'SetApply'
    $hit = Wait-Log $mark 'winbg pos-apply' 15
    if (-not $hit) { throw "apply de '$name' nao logou winbg" }
    ($hit -split "`n" | Where-Object { $_ -match 'winbg pos-apply|tema: \d+ pintura|config: aplicado' })
    $null = Invoke-ById $sw 'SetClose'
    Start-Sleep -Milliseconds 600
}

# baseline
$mark = Send-Cmd '/uitest themeprobe'
$hit = Wait-Log $mark 'themeprobe: ' 15
'--- baseline ---'
($hit -split "`n" | Where-Object { $_ -match 'themeprobe' } | Select-Object -Last 1)

'--- aplicando matrix ---'
Apply-Theme 'matrix'
$mark = Send-Cmd '/uitest themeprobe'
$hit = Wait-Log $mark 'themeprobe: ' 15
($hit -split "`n" | Where-Object { $_ -match 'themeprobe' } | Select-Object -Last 1)

'--- aplicando padrao ---'
Apply-Theme ([char]0x70 + 'adr' + [char]0xE3 + 'o')
$mark = Send-Cmd '/uitest themeprobe'
$hit = Wait-Log $mark 'themeprobe: ' 15
($hit -split "`n" | Where-Object { $_ -match 'themeprobe' } | Select-Object -Last 1)

# estado final = padrao (json volta a theme=null, como estava)
'probe fim'
