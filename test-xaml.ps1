# test-xaml.ps1 — valida os 3 blocos XAML do zquick.ps1 (parse + XamlReader.Load + FindName).
# Rodar com: pwsh -STA -File test-xaml.ps1   (WPF exige STA)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$src = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1' -Raw

$main = [regex]::Match($src, "(?s)\`$xamlStr = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$hist = [regex]::Match($src, "(?s)\`$hxStr = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$setx = [regex]::Match($src, "(?s)\`$sxStr = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $main) { throw 'XAML da janela principal nao achado no fonte' }
if (-not $hist) { throw 'XAML do dialogo de historico nao achado no fonte' }
if (-not $setx) { throw 'XAML do dialogo de configuracoes nao achado no fonte' }

function Check-Xaml([string]$xaml, [string[]]$names, [string]$rotulo) {
    [xml]$x = $null
    try { $x = $xaml } catch { throw "$rotulo : XML INVALIDO: $_" }
    $w = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    $missing = @()
    foreach ($n in $names) { if (-not $w.FindName($n)) { $missing += $n } }
    if ($missing.Count) { throw "$rotulo : FindName nao achou: $($missing -join ', ')" }
    "$rotulo : OK ($($names.Count) elementos)"
}

Check-Xaml $main @('ProfileBox','ModelBox','CopyBtn','NewBtn','HistBtn','TopBtn','SettingsBtn','MinBtn','MaxBtn','CloseBtn','AttachScroll','AttachPanel','ConfirmBar','ConfirmTitle','ConfirmDetail','ConfirmYes','ConfirmNo','AskBar','AskHeader','AskTitle','AskPanel','AskInput','AskSendBtn','AskOkBtn','AskOtherBtn','AskCancelBtn','AskFreeRow','SendBtn','InputBox','StatusText','ModelText','AnswerView','AnswerDoc') 'janela principal'
Check-Xaml $hist @('Search','List','CountText','DelBtn','OkBtn','HistClose') 'dialogo historico'
Check-Xaml $setx @('SetClose','SetProfile','SetKey','SetBase','SetFast','SetBig','SetVision','SetModels','SetListModels','SetW','SetH','SetCenter','SetTop','SetOpacity','SetOpVal','SetFont','SetFontSize','SetColors','SetResetColors','SetSearch','SetMaxTok','SetCache','SetHideBlur','SetSys','SetStatus','SetApply','SetCancel') 'dialogo configuracoes'
'tudo OK'
