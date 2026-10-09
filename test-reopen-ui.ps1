# test-reopen-ui.ps1 — E2E: fechar/abrir a janela zera a conversa (item novo, sem contexto anterior).
$ErrorActionPreference = 'Stop'
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
function Ask-Ui([string]$text) {
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq ' ') { Tap 0x20 }
        else { Tap ([byte][int][char]::ToUpper($ch)) }
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 350
    Tap 0x0D
    Start-Sleep -Milliseconds 600
    $mark = [IO.File]::ReadAllText($log).Length
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $new = Read-New $mark
        if ($new -match 'respondido: (\d+) chars em (\d+)s \| (.+)') { return $Matches[0] }
        if ($new -match 'engine: (.+)') { return "ERRO: $($Matches[1])" }
        if ($new -match 'FATAL')        { return 'FATAL' }
    }
    return 'TIMEOUT'
}

$histDir = 'C:\Users\EVTU-DELL\.local\bin\zquick\history'
$before = @(Get-ChildItem $histDir -Filter 'conv-*.json' -ErrorAction SilentlyContinue)

Combo 0x12 0x51; Start-Sleep -Milliseconds 900
"turno 1: " + (Ask-Ui 'quanto e 7 mais 7')
# esconde (Esc) e reabre (Alt+Q) — precisa vir conversa nova
Tap 0x1B; Start-Sleep -Milliseconds 700
Combo 0x12 0x51; Start-Sleep -Milliseconds 900
$mid = [IO.File]::ReadAllText($log).Length
"turno 2 (apos reabrir): " + (Ask-Ui 'quanto e 3 vezes 3')
Start-Sleep -Milliseconds 500

$after = @(Get-ChildItem $histDir -Filter 'conv-*.json' | Sort-Object LastWriteTime -Descending)
$novos = @($after | Where-Object { $before.FullName -notcontains $_.FullName })
"arquivos novos: $($novos.Count)"
foreach ($f in $novos) {
    $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
    "  $($f.Name): msgs $(@($j.msgs).Count) | q: $($j.q)"
}
$chk = [IO.File]::ReadAllText($log).Substring($off)
"reset ao reabrir (log): " + ($chk -match 'janela reaberta: conversa nova')
# expectativa: 2 arquivos novos, ambos msgs=2 (o 2o SEM o contexto do 1o)
if ($novos.Count -eq 2 -and @(Get-Content $novos[0].FullName -Raw | ConvertFrom-Json).msgs.Count -eq 2 -and @((Get-Content $novos[1].FullName -Raw | ConvertFrom-Json)).msgs.Count -eq 2) { 'VEREDITO: OK' } else { 'VEREDITO: FALHOU' }
Combo 0x11 0x4E; Start-Sleep -Milliseconds 400
Tap 0x1B
'--- log novo ---'
$chk