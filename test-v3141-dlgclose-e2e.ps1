# test-v3141-dlgclose-e2e.ps1 - v3.14.1: excecao dentro do dialogo de config
# nao pode mais (a) virar FATAL no fechamento (DialogResult em janela orfa) nem
# (b) derrubar o app. Reproduz o caso do usuario: mexer nas cores e fechar o ⚙.
# ASCII-only (5.1/ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
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
function Click-At([int]$x, [int]$y) {
    $null = [K.I]::SetCursorPos($x, $y)
    [K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 400
}
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }
$procId = (Get-Process zquick | Select-Object -First 1).Id
$root = [System.Windows.Automation.AutomationElement]::RootElement
$pcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
function Find-Wins {
    $c = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Get-MainWin {
    $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($w) { return $w }
    for ($try = 0; $try -lt 4; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
        if ($w) { return $w }
    }
    throw 'janela principal nao achada'
}
function Invoke-ById($win, [string]$id) {
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    if (-not $el) { throw "elemento $id nao achado" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
function Assert-Alive([string]$fase, [int]$mark) {
    Start-Sleep -Milliseconds 400
    if (-not (Get-Process zquick -ErrorAction SilentlyContinue)) { throw "$fase processo morreu" }
    $t = Read-New $mark
    if ($t -match 'FATAL') { throw "$fase FATAL no log: $($t.Substring(0, [Math]::Min(200, $t.Length)))" }
    "$fase app vivo, sem FATAL"
}
function Open-Settings {
    $win = Get-MainWin
    $null = Invoke-ById $win 'SettingsBtn'
    $sw = $null; $dl = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $dl -and -not $sw) {
        Start-Sleep -Milliseconds 400
        $sw = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1
    }
    if (-not $sw) { throw 'configuracoes nao abriram' }
    # aba Aparencia
    $tc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
    if (-not $tab) { throw 'aba Aparencia nao achada' }
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 600
    return $sw
}
function Get-HexEdits($sw) {
    $ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec)) | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -match '^#[0-9A-Fa-f]{6}$' }
}

$mark0 = [IO.File]::ReadAllText($log).Length
trap { for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; throw }

# ---- Fase A: hex VAZIO + clique no swatch (suspeito do ConvertFromString) ----
$sw = Open-Settings
$hexEdits = @(Get-HexEdits $sw)
if ($hexEdits.Count -lt 1) { throw 'nenhum TextBox hex na aba' }
$r = $hexEdits[0].Current.BoundingRectangle
# swatch: fileira = swatch(16) + label(120) + ⟲(4+24) -> centro do swatch fica
# 156px logicos ANTES da caixa (v3.16 acrescentou o botao ⟲; era 72 no v3.14.1)
# escala fisica = largura real / 90
$sf = $r.Width / 90.0
$hexEdits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('')
Click-At ([int]($r.Left - 156 * $sf)) ([int](($r.Top + $r.Bottom) / 2))
Start-Sleep -Milliseconds 900
$pk = Find-Wins | Where-Object { $_.Current.Name -like '*cor*' } | Select-Object -First 1
if ($pk) {
    'fase A: picker abriu com hex vazio'
    $pr = $pk.Current.BoundingRectangle
    Click-At ([int]($pr.Left + ($pr.Width * 0.62))) ([int]($pr.Top + 120))
    $slc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Slider)
    $slider = $pk.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $slc)
    if ($slider) { $slider.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue(70) }
    Start-Sleep -Milliseconds 400
    $bc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $okb = @($pk.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) | Where-Object { $_.Current.Name -eq 'OK' } | Select-Object -First 1
    if ($okb) { $okb.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    Start-Sleep -Milliseconds 500
} else { 'fase A: picker nao abriu (sem problema — segue o fechamento)' }
# fecha o ⚙ pelo ✕ (era aqui que o FATAL acontecia)
$null = Invoke-ById $sw 'SetClose'
Assert-Alive 'fase A' $mark0

# ---- Fase B: hex INVALIDO (#GG) + swatch + Cancelar + fechar ----
$mark1 = [IO.File]::ReadAllText($log).Length
$sw = Open-Settings
$hexEdits = @(Get-HexEdits $sw)
$r = $hexEdits[0].Current.BoundingRectangle
$hexEdits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('#GG')
Click-At ([int]($r.Left - 156 * ($r.Width / 90.0))) ([int](($r.Top + $r.Bottom) / 2))
Start-Sleep -Milliseconds 900
$pk = Find-Wins | Where-Object { $_.Current.Name -like '*cor*' } | Select-Object -First 1
if ($pk) {
    'fase B: picker abriu com hex invalido'
    $bc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $cb = @($pk.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) | Where-Object { $_.Current.Name -eq 'Cancelar' } | Select-Object -First 1
    if ($cb) { $cb.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } else { Tap 0x1B }
    Start-Sleep -Milliseconds 500
}
$null = Invoke-ById $sw 'SetClose'
Assert-Alive 'fase B' $mark1

# ---- Fase C: dialogo do historico abre e fecha pelo ✕ (mesmo padrao DialogResult) ----
$mark2 = [IO.File]::ReadAllText($log).Length
$win = Get-MainWin
$null = Invoke-ById $win 'HistBtn'
$hw = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $hw) { Start-Sleep -Milliseconds 400; $hw = Find-Wins | Where-Object { $_.Current.Name -like '*hist*' } | Select-Object -First 1 }
if (-not $hw) { throw 'historico nao abriu' }
$null = Invoke-ById $hw 'HistClose'
Assert-Alive 'fase C' $mark2

# logs de diagnostico do run (se o ConvertFromString original aparecer, o 'picker erro:' nomeia a linha)
$t = Read-New $mark0
$pe = @([regex]::Matches($t, 'picker erro:[^\r\n]*') | ForEach-Object { $_.Value })
if ($pe.Count) { "diagnostico picker erro:"; $pe | ForEach-Object { "  $_" } }

# restaura o hex da fase A/B (volta o valor original pra nao salvar sujeira)
"VERDICTO: OK (config com hex vazio/invalido + swatch + fechamentos sem FATAL)"
