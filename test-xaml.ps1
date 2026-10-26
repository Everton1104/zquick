# test-xaml.ps1 — valida os 3 blocos XAML do zquick.ps1 (parse + XamlReader.Load + FindName).
# Rodar com: pwsh -STA -File test-xaml.ps1   (WPF exige STA)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$src = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1' -Raw

# v3.24.1: estilo da scrollbar = fragmento unico ($scrFrag); os XAMLs carregam so
# o marcador <!--SCRFRAG-->, que o Theme-Xaml injeta no parse — Check-Xaml imita
$scr = [regex]::Match($src, "(?s)\`$scrFrag = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $scr) { throw 'fragmento $scrFrag nao achado no fonte' }

$main = [regex]::Match($src, "(?s)\`$xamlStr = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$hist = [regex]::Match($src, "(?s)\`$hxStr = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$setx = [regex]::Match($src, "(?s)\`$sxStr = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $main) { throw 'XAML da janela principal nao achado no fonte' }
if (-not $hist) { throw 'XAML do dialogo de historico nao achado no fonte' }
if (-not $setx) { throw 'XAML do dialogo de configuracoes nao achado no fonte' }

function Check-Xaml([string]$xaml, [string[]]$names, [string]$rotulo) {
    $xaml = $xaml.Replace('<!--SCRFRAG-->', $scr)   # injeta como o Theme-Xaml faz
    [xml]$x = $null
    try { $x = $xaml } catch { throw "$rotulo : XML INVALIDO: $_" }
    $w = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    $missing = @()
    foreach ($n in $names) { if (-not $w.FindName($n)) { $missing += $n } }
    if ($missing.Count) { throw "$rotulo : FindName nao achou: $($missing -join ', ')" }
    "$rotulo : OK ($($names.Count) elementos)"
}

Check-Xaml $main @('ProfileBox','ModelBox','NewBtn','HistBtn','TopBtn','SettingsBtn','MinBtn','MaxBtn','CloseBtn','AttachScroll','AttachPanel','ConfirmBar','ConfirmTitle','ConfirmDetail','ConfirmYes','ConfirmNo','AskBar','AskHeader','AskTitle','AskPanel','AskInput','AskSendBtn','AskOkBtn','AskOtherBtn','AskCancelBtn','AskFreeRow','TodoBar','TodoHeader','TodoHide','TodoScroll','TodoItems','SendBtn','InputBox','StatusText','ModelText','AnswerView','AnswerDoc') 'janela principal'   # CopyBtn: runtime (Add-CopyIcon, v3.14) · TodoBar: v3.25 (todo_write)
Check-Xaml $hist @('Search','List','CountText','DelBtn','OkBtn','HistClose') 'dialogo historico'
Check-Xaml $setx @('SetClose','SetProfile','SetKey','SetBase','SetFast','SetBig','SetVision','SetModels','SetListModels','SetW','SetH','SetCenter','SetTop','SetOpacity','SetOpVal','SetFont','SetFontSize','SetColors','SetResetColors','SetSearch','SetMaxTok','SetCache','SetHideBlur','SetSys','SetStatus','SetApply','SetCancel') 'dialogo configuracoes'
'tudo OK'
