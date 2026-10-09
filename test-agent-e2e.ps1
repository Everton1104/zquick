# test-agent-e2e.ps1 — E2E do agente local + anexos:
#   fase 1: nota automatica (note_add, sem confirmacao)
#   fase 2: renomear a nota (confirmacao aparece, UIA clica ✅ Executar)
#   fase 3: anexo .txt via Ctrl+V (FileDropList)
#   fase 4: anexo PDF real (document block ou fallback)
# Rodar com: pwsh -STA -File test-agent-e2e.ps1   (app residente rodando)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
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
function Clear-Input {
    [K.I]::keybd_event(0x11,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    Tap 0x41
    [K.I]::keybd_event(0x11,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    Tap 0x2E
}
function Ask-Ui([string]$text) {
    Clear-Input
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
function Get-MainWin([int]$procId) {
    @(Find-WindowsByProc $procId) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
}
function Invoke-ById($win, [string]$id, [string]$label) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $btn) { throw "botao '$label' nao encontrado via UIA" }
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Show-Window([int]$procId) {
    for ($try = 0; $try -lt 4; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $w = Get-MainWin $procId
        if ($w) { return $w }
    }
    throw 'janela do zquick nao apareceu'
}

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }
# Documents pode ser redirecionado (OneDrive) — sempre GetFolderPath, igual ao engine
$notesDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ZQuick-Notas'
$results = @()

# ---------- fase 1: nota (sem confirmacao) ----------
[void](Show-Window $app.ProcessId)
$r1 = Ask-Ui 'crie uma nota com o titulo exatamente teste agente zquick e conteudo reuniao de sexta as 15h'
"fase1 (nota): $r1"
$nota = Get-ChildItem $notesDir -Filter '*teste-agente-zquick*.md' -ErrorAction SilentlyContinue | Select-Object -First 1
$results += "fase1: nota criada = $([bool]$nota) ($($nota.Name))"

# ---------- fase 2: renomear (MESMA conversa, confirmacao + clique ✅ via UIA) ----------
if ($nota) {
    $mark = [IO.File]::ReadAllText($log).Length
    Clear-Input
    foreach ($ch in 'agora renomeie esse arquivo da nota para teste-agente-renomeado.md mantendo o prefixo da data'.ToCharArray()) {
        if ($ch -eq ' ') { Tap 0x20 } else { Tap ([byte][int][char]::ToUpper($ch)) }
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 400
    Tap 0x0D
    # espera a barra de confirmacao aparecer no log e clica ✅ Executar ANTES dos 45s de expiracao
    $clicked = $false
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $clicked) {
        Start-Sleep -Milliseconds 400
        if ((Read-New $mark) -match 'confirma: ') {
            Start-Sleep -Milliseconds 500
            $w2 = Get-MainWin $app.ProcessId
            if ($w2) { Invoke-ById $w2 'ConfirmYes' 'Executar'; $clicked = $true; 'fase2: clicou ✅ Executar' }
        }
    }
    if (-not $clicked) { $results += 'fase2: barra de confirmacao NAO apareceu' }
    else {
        $r2 = $null
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if ((Read-New $mark) -match 'respondido: (\d+) chars em (\d+)s \| (.+)') { $r2 = $Matches[0]; break }
            if ((Read-New $mark) -match 'engine: (.+)') { $r2 = "ERRO: $($Matches[1])"; break }
        }
        "fase2 (renomear): $r2"
        $ren = Get-ChildItem $notesDir -Filter '*renomeado*.md' -ErrorAction SilentlyContinue | Select-Object -First 1
        $results += "fase2: renomeado = $([bool]$ren) ($($ren.Name))"
    }
}

# limpa conversa
Tap 0x1B; Start-Sleep -Milliseconds 700

# ---------- fase 3: anexo .txt via Ctrl+V ----------
$txt = 'C:\Users\EVTU-DELL\.local\bin\zquick\teste-arquivo.txt'
[IO.File]::WriteAllText($txt, 'ZQUICK-ARQ-42')
$col = [System.Collections.Specialized.StringCollection]::new()
$col.Add($txt)
[System.Windows.Clipboard]::SetFileDropList($col)
[void](Show-Window $app.ProcessId)
Combo 0x11 0x56; Start-Sleep -Milliseconds 900
$r3 = Ask-Ui 'o que esta escrito no arquivo anexado'
"fase3 (txt): $r3"
# preview do log corta em 60 chars (token inteiro nao cabe); o prefixo ZQUICK so existe no arquivo
$results += "fase3: leu o txt = $($r3 -match 'ZQUICK')"
Tap 0x1B; Start-Sleep -Milliseconds 700

# ---------- fase 4: anexo PDF real ----------
$pdf = 'C:\Users\EVTU-DELL\OneDrive\Desktop\CAROL\Plano Pri .pdf'
$col2 = [System.Collections.Specialized.StringCollection]::new()
$col2.Add($pdf)
[System.Windows.Clipboard]::SetFileDropList($col2)
[void](Show-Window $app.ProcessId)
Combo 0x11 0x56; Start-Sleep -Milliseconds 900
$r4 = Ask-Ui 'em uma frase curta do que trata o documento anexado'
"fase4 (pdf): $r4"
$pdfRejected = (Read-New $off) -match 'PDF rejeitado'
$results += "fase4: respondeu = $($r4 -match 'respondido') | fallback-sem-pdf = $pdfRejected"

# limpeza final
Tap 0x1B
[IO.File]::Delete($txt)
Get-ChildItem $notesDir -Filter '*agente*.md' -ErrorAction SilentlyContinue | ForEach-Object { try { [IO.File]::Delete($_.FullName) } catch {} }
Get-ChildItem $notesDir -Filter '*renomeado*.md' -ErrorAction SilentlyContinue | ForEach-Object { try { [IO.File]::Delete($_.FullName) } catch {} }
''
$results
$ok = ($results | Where-Object { $_ -notmatch 'True' }).Count -eq 0
if ($ok) { 'VEREDITO: OK' } else { 'VEREDITO: PARCIAL' }
'--- log novo ---'
Read-New $off
