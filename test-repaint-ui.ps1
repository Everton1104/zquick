# test-repaint-ui.ps1 — E2E do v3.23: Aplicar repinta a janela INTEIRA ao vivo.
# Antes: logo "⚡ ZQuick", combos e botões só mudavam de cor ao REINICIAR (cores
# assadas no parse do XAML). Agora Update-ThemeLive varre a árvore visual e troca
# brush cor-antiga→cor-nova + Update-ComboItemStyle + Update-TrayIcon.
#   1. themeprobe baseline (logo fg, NewBtn bg/fg, ProfileBox bg/fg)
#   2. ⚙→Aparência: sentinéis em fg (#FFB300), panel (#5C3A00), input (#26313B)
#      → Aplicar → log 'config: aplicado' + 'repintada(s) ao vivo' → fecha
#   3. themeprobe SEM reiniciar → tudo com as sentinelas (logo fg, botão, combo)
#   4. restaura as 3 cores originais → themeprobe volta ao baseline
# Rodar com: pwsh -STA -File test-repaint-ui.ps1   (app dev rodando)
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
    throw "UIA nao respondeu procurando '$id'"
}
function Invoke-ById($win, [string]$id) {
    $el = Find-ById $win $id
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
function Get-MainWin([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    foreach ($w in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($w.Current.Name -like '*ZQuick*' -and $w.Current.Name -notlike '*hist*') { return $w }
    }
    $null
}
function Find-Wins([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    $all = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))
    $mw = $all | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
    if ($mw) { $all += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($all)
}
function Click-Invoke($el) {
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 300
}
function Send-Line($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $p = $tb.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y); Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
}
Add-Type -Namespace K -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
'@
function Get-HexEdits($sw) {
    $ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec)) | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -match '^#[0-9A-Fa-f]{6}$' }
}
function Set-Val($el, [string]$v) { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v) }
function Get-ThemeProbe([int]$procId, [hashtable]$wref) {
    # envia /uitest themeprobe e devolve o hex de cada campo num hashtable
    $mark = (Read-LogText).Length
    Send-Line $wref.w '/uitest themeprobe'
    $hit = Wait-Log $mark 'themeprobe: ' 15
    if (-not $hit) { throw "themeprobe nao logou. log: $((Read-LogText).Substring($mark))" }
    $line = ($hit -split "`n" | Where-Object { $_ -match 'themeprobe' } | Select-Object -Last 1)
    if ($line -notmatch 'win bg=(#[0-9A-F]{6}); AnswerView bg=(#[0-9A-F]{6}|n/a); setSW=(#[0-9A-F]{6}|fechado|n/a); logo fg=(#[0-9A-F]{6}); NewBtn bg=(#[0-9A-F]{6})/fg=(#[0-9A-F]{6}); ProfileBox bg=(#[0-9A-F]{6})/fg=(#[0-9A-F]{6}); TopBtn bg=(#[0-9A-F]{6})/fg=(#[0-9A-F]{6}); PassBtn bg=(#[0-9A-F]{6})/fg=(#[0-9A-F]{6})') { throw "themeprobe fora do formato: $line" }
    return @{ win = $Matches[1]; logo = $Matches[4]; btnBg = $Matches[5]; btnFg = $Matches[6]; cbBg = $Matches[7]; cbFg = $Matches[8]; topBg = $Matches[9]; topFg = $Matches[10]; passBg = $Matches[11]; passFg = $Matches[12]; line = $line }
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | $ctx" } }

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }
# estado de 📌/⚡ vem do json: a cor esperada deles DEPENDE de ativo/inativo
$j = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json' -Raw | ConvertFrom-Json
$topOn = [bool]$j.alwaysOnTop; $passOn = [bool]$j.passthrough

try {
    $w = $null
    for ($try = 0; $try -lt 6 -and -not $w; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $cand = Get-MainWin $app.ProcessId
        if ($cand -and (Find-ById $cand 'InputBox')) { $w = $cand }
    }
    if (-not $w) { throw 'janela do zquick nao apareceu' }
    $wref = @{ w = $w }

    # ---- 1. baseline ----
    $base = Get-ThemeProbe $app.ProcessId $wref
    "baseline: $($base.line)"
    Assert ($base.logo -ne '#FFB300') 'sentinela fg ja presente no tema (troque as sentinelas do teste)' $base.line

    # ---- 2. sentinelas no ⚙ ----
    $null = Invoke-ById $w 'SettingsBtn'
    $sw = $null; $dl = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $dl -and -not $sw) {
        Start-Sleep -Milliseconds 400
        $sw = Find-Wins $app.ProcessId | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1
    }
    if (-not $sw) { throw 'configuracoes nao abriram' }
    $tc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
    if (-not $tab) { throw 'aba Aparencia nao achada' }
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 700
    $hexEdits = @(Get-HexEdits $sw)
    Assert ($hexEdits.Count -ge 15) "esperava >=15 hex, achei $($hexEdits.Count)" ''
    # ordem = $colorKeys: bg,card,PANEL,INPUT,border,FG,dim,status,q,ACCENT,...
    $oldPanel = $hexEdits[2].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    $oldInput = $hexEdits[3].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    $oldFg    = $hexEdits[5].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    $oldAccent = $hexEdits[9].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    Set-Val $hexEdits[2] '#5C3A00'
    Set-Val $hexEdits[3] '#26313B'
    Set-Val $hexEdits[5] '#FFB300'
    Set-Val $hexEdits[9] '#E0559C'
    $mark = (Read-LogText).Length
    $null = Invoke-ById $sw 'SetApply'
    $hit = Wait-Log $mark 'config: aplicado' 15
    if (-not $hit) { throw "Aplicar nao logou. log: $((Read-LogText).Substring($mark))" }
    if (-not (Wait-Log $mark 'repintada\(s\) ao vivo' 10)) { throw "repaint ao vivo nao logou. log: $((Read-LogText).Substring($mark))" }
    $null = Invoke-ById $sw 'SetClose'
    Start-Sleep -Milliseconds 500
    Assert (Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' }) 'processo morreu apos fechar o ⚙' ''
    'sentinelas aplicadas, ⚙ fechado sem crash'

    # ---- 3. themeprobe SEM reiniciar: tudo repintado? ----
    $after = Get-ThemeProbe $app.ProcessId $wref
    "apos apply: $($after.line)"
    Assert ($after.logo -eq '#FFB300') "logo nao repintou (fg): $($after.logo)" $after.line
    Assert ($after.btnBg -eq '#5C3A00') "botao nao repintou (panel): $($after.btnBg)" $after.line
    Assert ($after.btnFg -eq '#FFB300') "texto do botao nao repintou (fg): $($after.btnFg)" $after.line
    Assert ($after.cbBg -eq '#26313B') "combo nao repintou (input): $($after.cbBg)" $after.line
    Assert ($after.cbFg -eq '#FFB300') "texto do combo nao repintou (fg): $($after.cbFg)" $after.line
    # 📌/⚡: pintados POR CODIGO — ativos = accent (#E0559C, contraste branco), inativos = panel/fg
    $expTopBg  = $(if ($topOn)  { '#E0559C' } else { '#5C3A00' })
    $expPassBg = $(if ($passOn) { '#E0559C' } else { '#5C3A00' })
    $expTopFg  = $(if ($topOn)  { '#FFFFFF' } else { '#FFB300' })
    $expPassFg = $(if ($passOn) { '#FFFFFF' } else { '#FFB300' })
    Assert ($after.topBg -eq $expTopBg) "TopBtn (📌 ativo=$topOn) nao seguiu o tema: $($after.topBg), esperava $expTopBg" $after.line
    Assert ($after.topFg -eq $expTopFg) "TopBtn fg errado: $($after.topFg), esperava $expTopFg" $after.line
    Assert ($after.passBg -eq $expPassBg) "PassBtn (⚡ ativo=$passOn) nao seguiu o tema: $($after.passBg), esperava $expPassBg" $after.line
    Assert ($after.passFg -eq $expPassFg) "PassBtn fg errado: $($after.passFg), esperava $expPassFg" $after.line
    'PASS: logo + botao + combo + 📌/⚡ repintaram AO VIVO (sem reiniciar)'

    # ---- 4. restaura ----
    $null = Invoke-ById $w 'SettingsBtn'
    $sw = $null; $dl = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $dl -and -not $sw) {
        Start-Sleep -Milliseconds 400
        $sw = Find-Wins $app.ProcessId | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1
    }
    if (-not $sw) { throw 'configuracoes nao reabriram p/ restaurar' }
    $tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 700
    $hexEdits = @(Get-HexEdits $sw)
    Set-Val $hexEdits[2] $oldPanel
    Set-Val $hexEdits[3] $oldInput
    Set-Val $hexEdits[5] $oldFg
    Set-Val $hexEdits[9] $oldAccent
    $mark = (Read-LogText).Length
    $null = Invoke-ById $sw 'SetApply'
    if (-not (Wait-Log $mark 'config: aplicado' 15)) { throw "Aplicar restaurador nao logou. log: $((Read-LogText).Substring($mark))" }
    $null = Invoke-ById $sw 'SetClose'
    Start-Sleep -Milliseconds 500
    $back = Get-ThemeProbe $app.ProcessId $wref
    "restaurado: $($back.line)"
    Assert ($back.logo -eq $base.logo -and $back.btnBg -eq $base.btnBg -and $back.cbBg -eq $base.cbBg) 'restauracao nao voltou ao baseline' $back.line
    Assert (-not ((Read-LogText).Substring($mark) -match 'FATAL')) 'FATAL no log' ''
    Assert (Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' }) 'processo morreu no fim' ''

    'VERDICTO: OK (Aplicar repinta logo/botoes/combos ao vivo e restaura limpo)'
} finally {
    for ($i = 0; $i -lt 2; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 300 }
    Start-Sleep -Milliseconds 400
    try { Combo 0x12 0x51 } catch {}
}
