# test-esc-ui.ps1 — E2E: Esc fecha a conversa (log marcador + zera) e o app segue vivo.
# Rodar com: pwsh -STA -File test-esc-ui.ps1   (app residente ja rodando)
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
"turno 1: " + (Ask-Ui 'quanto e 5 mais 5')
# Esc = fechar conversa + esconder
$mark = [IO.File]::ReadAllText($log).Length
Tap 0x1B; Start-Sleep -Milliseconds 800
$new = Read-New $mark
$escOk = $new -match 'esc: conversa fechada'
"esc fechou conversa (log): $escOk"
# Alt+Q tem que continuar vivo e abrir conversa nova
Combo 0x12 0x51; Start-Sleep -Milliseconds 900
$new2 = Read-New $mark
$reopenOk = $new2 -match 'janela reaberta: conversa nova'
"alt+q vivo apos esc (log): $reopenOk"
"turno 2: " + (Ask-Ui 'quanto e 2 vezes 2')
Start-Sleep -Milliseconds 500

$after = @(Get-ChildItem $histDir -Filter 'conv-*.json' | Sort-Object LastWriteTime -Descending)
$novos = @($after | Where-Object { $before.FullName -notcontains $_.FullName })
"arquivos novos: $($novos.Count)"
foreach ($f in $novos) {
    $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
    "  $($f.Name): msgs $(@($j.msgs).Count) | q: $($j.q)"
}
if ($escOk -and $reopenOk -and $novos.Count -eq 2) { 'VEREDITO: OK' } else { 'VEREDITO: FALHOU' }
# limpeza: esconder janela (Esc tambem fecha a conversa vazia, inofensivo)
Tap 0x1B
'--- log novo ---'
Read-New $off
