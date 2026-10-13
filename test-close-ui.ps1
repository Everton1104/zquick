# test-close-ui.ps1 — E2E: X nativo/Alt+F4 so' oculta; proximo toggle reabre sem crash.
# Regressao do bug "Show() apos Close() -> InvalidOperationException (dialogo JIT no tray)".
# Rodar com: pwsh -STA -File test-close-ui.ps1   (app residente ja rodando)
$ErrorActionPreference = 'Stop'
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
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
    [K.I]::keybd_event($mod,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 300
}
# espera ate 'padrao' aparecer no trecho novo do log (ou estourar o prazo)
function Wait-New([int]$mark, [string]$pattern, [int]$secs = 12) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        try { $new = [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 200; continue }
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 400
    }
    return ''
}

# 1) garante janela VISIVEL (estado inicial desconhecido: toggle pode abrir ou fechar)
$mark = [IO.File]::ReadAllText($log).Length
Combo 0x12 0x51
$new = Wait-New $mark 'toggle'
if (-not $new) { throw "alt+q 1 nao chegou (nada no log)" }
if ($new -notmatch 'janela reaberta') {
    # o toggle escondeu (estava visivel) — abre de novo
    $mark = [IO.File]::ReadAllText($log).Length
    Combo 0x12 0x51
    $new = Wait-New $mark 'janela reaberta'
    if (-not $new) { throw "janela nao abriu. log novo: $new" }
}

# 2) Alt+F4 na janela do ZQuick — deve so' ocultar (Closing cancelado)
$mark = [IO.File]::ReadAllText($log).Length
Combo 0x12 0x73
$new = Wait-New $mark 'X/Alt\+F4: ocultando'
$hideOk = [bool]$new
"alt+f4 -> ocultou (log): $hideOk"
if (-not $hideOk) { throw "Alt+F4 nao foi interceptado. log novo: $new" }

# 3) Alt+Q de novo — tem que reabrir SEM exception (antes: dialogo JIT)
$mark = [IO.File]::ReadAllText($log).Length
Combo 0x12 0x51
$new = Wait-New $mark 'janela reaberta: conversa nova'
$reopenOk  = [bool]$new
$toggleErr = $new -match 'toggle erro'
"alt+q reabriu:            $reopenOk"
"toggle com erro (log):    $toggleErr"
if (-not $reopenOk) { throw "reabertura falhou. log novo: $new" }
if ($toggleErr)     { throw "toggle erro apos Alt+F4. log novo: $new" }

# 4) deixa oculto (estado normal de bandeja)
Combo 0x12 0x51; Start-Sleep -Milliseconds 600
'PASS: X/Alt+F4 oculta e o toggle seguinte reabre sem crash'
