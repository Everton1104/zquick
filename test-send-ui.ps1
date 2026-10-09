# test-send-ui.ps1 — exerce o fluxo COMPLETO pela UI real:
# Alt+Q -> digitar -> Enter -> streaming -> resposta -> Ctrl+N -> Esc.
# (testes de toggle nao pegam o caminho de envio/scroll; este pega)
$ErrorActionPreference = 'Stop'
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$off  = [IO.File]::ReadAllText($log).Length
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

Combo 0x12 0x51                       # Alt+Q -> mostra, foca InputBox
Start-Sleep -Milliseconds 900
foreach ($ch in 'responda apenas ok'.ToCharArray()) {
    if ($ch -eq ' ') { Tap 0x20 }
    else { Tap ([byte][int][char]::ToUpper($ch)) }
    Start-Sleep -Milliseconds 25
}
Start-Sleep -Milliseconds 400
Tap 0x0D                              # Enter -> envia
'pergunta enviada, aguardando resposta...'
$deadline = (Get-Date).AddSeconds(90); $verdict = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $new = [IO.File]::ReadAllText($log).Substring($off)
    if ($new -match 'respondido: (\d+) chars em (\d+)s') { $verdict = "RESPOSTA OK ($($Matches[1]) chars em $($Matches[2])s)"; break }
    if ($new -match 'engine: (.+)')  { $verdict = "ERRO ENGINE: $($Matches[1])"; break }
    if ($new -match 'FATAL')         { $verdict = 'FATAL: ' + $new; break }
}
if (-not $verdict) { $verdict = 'TIMEOUT (90s) sem resposta' }
Combo 0x11 0x4E                       # Ctrl+N -> nova conversa (limpa)
Start-Sleep -Milliseconds 500
Tap 0x1B                              # Esc -> esconde
$verdict
'--- log novo ---'
[IO.File]::ReadAllText($log).Substring($off)
