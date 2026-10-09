# test-history-ui.ps1 — E2E do historico: 2 perguntas na mesma conversa ->
# valida TTFT no log + arquivo conv-*.json criado e atualizado (4 msgs).
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
function Ask-Ui([string]$text) {
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq ' ') { Tap 0x20 }
        else { Tap ([byte][int][char]::ToUpper($ch)) }
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 350
    Tap 0x0D
    Start-Sleep -Milliseconds 600
    $mark = [IO.File]::ReadAllText($log).Length   # so linhas DEPOIS deste envio
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $new = [IO.File]::ReadAllText($log).Substring($mark)
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
Start-Sleep -Milliseconds 500
"turno 2: " + (Ask-Ui 'agora multiplique por 3')
Start-Sleep -Milliseconds 500

# inspeciona o historico: esperado 2 arquivos novos (1 por pergunta), o 2o com o fio completo
$after = @(Get-ChildItem $histDir -Filter 'conv-*.json' | Sort-Object LastWriteTime -Descending)
$arquivosNovos = @($after | Where-Object { $before.FullName -notcontains $_.FullName })
"arquivos novos: $($arquivosNovos.Count)"
foreach ($f in $arquivosNovos) {
    $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
    "  $($f.Name): msgs $(@($j.msgs).Count) | q: $($j.q) | a: $($j.a)"
}

Combo 0x11 0x4E; Start-Sleep -Milliseconds 400
Tap 0x1B
'--- log novo ---'
[IO.File]::ReadAllText($log).Substring($off)
