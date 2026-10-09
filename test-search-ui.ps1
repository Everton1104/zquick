# test-search-ui.ps1 — E2E da busca web pela UI: pergunta do dia -> web_search -> fontes -> resposta citada.
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

Combo 0x12 0x51; Start-Sleep -Milliseconds 900
# limpa a caixa antes de digitar (evita sobras de teste anterior)
[K.I]::keybd_event(0x11,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
[K.I]::keybd_event(0x41,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
[K.I]::keybd_event(0x41,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
[K.I]::keybd_event(0x11,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 100
[K.I]::keybd_event(0x2E,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
[K.I]::keybd_event(0x2E,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 200
$pergunta = if ($args.Count -gt 0) { [string]$args[0] } else { 'cotacao do dolar hoje' }
foreach ($ch in $pergunta.ToCharArray()) {
    if ($ch -eq ' ') { Tap 0x20 }
    else { Tap ([byte][int][char]::ToUpper($ch)) }
    Start-Sleep -Milliseconds 25
}
Start-Sleep -Milliseconds 400
Tap 0x0D
Start-Sleep -Milliseconds 600
$mark = [IO.File]::ReadAllText($log).Length
'pergunta de busca enviada, aguardando...'
$deadline = (Get-Date).AddSeconds(150); $verdict = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $new = [IO.File]::ReadAllText($log).Substring($mark)
    if ($new -match 'respondido: (\d+) chars em (\d+)s \| (.+)') { $verdict = "RESPONDIDO ($($Matches[1]) chars em $($Matches[2])s): $($Matches[3])"; break }
    if ($new -match 'engine: (.+)')  { $verdict = "ERRO ENGINE: $($Matches[1])"; break }
    if ($new -match 'FATAL')         { $verdict = 'FATAL: ' + $new; break }
}
if (-not $verdict) { $verdict = 'TIMEOUT (150s)' }
Combo 0x11 0x4E; Start-Sleep -Milliseconds 400
Tap 0x1B
$verdict
'--- log novo ---'
[IO.File]::ReadAllText($log).Substring($off)
