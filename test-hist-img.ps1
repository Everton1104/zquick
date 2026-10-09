# test-hist-img.ps1 — E2E: print anexado vira conversa salva COM a imagem embutida,
# e retomar pelo 🕘 devolve os pixels ao modelo (pergunta follow-up le o texto de novo).
# Rodar com: pwsh -STA -File test-hist-img.ps1   (app residente rodando)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$histDir = 'C:\Users\EVTU-DELL\.local\bin\zquick\history'
$off = [IO.File]::ReadAllText($log).Length
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
function Ask-Ui([string]$text) {
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq ' ') { Tap 0x20 }
        else { Tap ([byte][int][char]::ToUpper($ch)) }
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 400
    Tap 0x0D
    Start-Sleep -Milliseconds 600
    $mark = [IO.File]::ReadAllText($log).Length
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $new = Read-New $mark
        if ($new -match 'respondido: (\d+) chars em (\d+)s \| (.+)') { return $Matches[0] }
        if ($new -match 'engine: (.+)') { return "ERRO: $($Matches[1])" }
        if ($new -match 'FATAL')        { return 'FATAL' }
    }
    return 'TIMEOUT'
}
function Find-WindowsByProc([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))
}
function Invoke-Button($win, [string]$name, [string]$label, [switch]$byId) {
    if ($byId) {
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $name)
    } else {
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
    }
    $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $btn) { throw "botao '$label' nao encontrado via UIA" }
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

# 1. PNG marcado -> clipboard (mesmo formato da Ferramenta de Captura)
$bmp = [System.Drawing.Bitmap]::new(460, 120)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$g.SmoothingMode = 'AntiAlias'
$font = [System.Drawing.Font]::new('Arial', 28, [System.Drawing.FontStyle]::Bold)
$brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(20, 90, 200))
$g.DrawString('ZQUICK-HIST-77', $font, $brush, [single]12, [single]40)
$g.Dispose()
$ms = [System.IO.MemoryStream]::new()
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$ms.Position = 0
$frame = [System.Windows.Media.Imaging.BitmapFrame]::Create($ms, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
[System.Windows.Clipboard]::SetImage($frame)
'imagem no clipboard'

# 2. abre, cola, pergunta, envia
$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }
$win = $null
for ($try = 0; $try -lt 3 -and -not $win; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    $win = @(Find-WindowsByProc $app.ProcessId) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
}
if (-not $win) { throw 'janela do zquick nao achada via UIA' }
Combo 0x11 0x56; Start-Sleep -Milliseconds 900     # Ctrl+V -> anexa
"turno 1: " + (Ask-Ui 'o que esta escrito na imagem')

# 3. o arquivo da conversa tem a imagem embutida?
$f = @(Get-ChildItem $histDir -Filter 'conv-*.json' | Sort-Object LastWriteTime -Descending)[0]
$raw = [IO.File]::ReadAllText($f.FullName)
# msgs sao strings JSON escapadas no arquivo -> aspas internas vem como \" ; cada imagem tem 1 source base64
$imgs = ([regex]::Matches($raw, 'base64')).Count
$j = $raw | ConvertFrom-Json
"arquivo: $($f.Name) | {0:N0} KB | msgs: $(@($j.msgs).Count) | blocos de imagem: $imgs" -f ($f.Length/1KB)

# 4. fecha a conversa (Esc) e RETOMA pelo 🕘 (item mais recente)
Tap 0x1B; Start-Sleep -Milliseconds 800
Combo 0x12 0x51; Start-Sleep -Milliseconds 900
$win = $null
for ($try = 0; $try -lt 3 -and -not $win; $try++) {
    $win = @(Find-WindowsByProc $app.ProcessId) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
    if (-not $win) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900 }
}
$mark = [IO.File]::ReadAllText($log).Length
Invoke-Button $win 'HistBtn' 'relogio/historico' -byId   # x:Name -> AutomationId (imune a emoji/encoding)
$okDialogo = $false
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ((Read-New $mark) -match 'historico: dialogo \((\d+) itens\)') { $okDialogo = $true; break }
}
if (-not $okDialogo) { throw 'dialogo nao abriu' }
# OkBtn e' IsDefault: Enter em qualquer foco (inclui o campo de busca) retoma o item selecionado
Start-Sleep -Milliseconds 700
Tap 0x0D
$okLoad = $false
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ((Read-New $mark) -match 'historico: retomou (\d+) msgs') { $okLoad = $true; "retomou $($Matches[1]) msgs"; break }
}
if (-not $okLoad) { throw 'conversa nao carregou' }

# 5. follow-up: o modelo AINDA ve a imagem retomada?
$t2 = Ask-Ui 'repita o texto da imagem'
"turno 2 (pos-retomar): $t2"
Start-Sleep -Milliseconds 500
$chk = Read-New $off
$semErroImg = $chk -notmatch 'hist-img:'

# limpeza: Esc fecha conversa e esconde
Tap 0x1B
if ($imgs -ge 1 -and $semErroImg -and $t2 -match 'ZQUICK-HIST-77') { 'VEREDITO: OK (imagem salva + retomada + lida de novo)' } else { 'VEREDITO: PARCIAL — conferir acima' }
'--- log novo ---'
$chk
