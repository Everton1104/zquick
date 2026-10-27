# test-v3261-saldo-e2e.ps1 - v3.26.1: 429/1113 (saldo Z.ai) vira mensagem amigavel,
# SEM retry com backoff e SEM cadeia de fallback de modelo.
# Oraculo: fake-api em modo -Balance => exatamente 1 POST recebido (mais POST =
# retry ou fallback aconteceu) + log com 'respondido' contendo 'SALDO'.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = 'C:\Users\EVTU-DELL\.local\bin\zquick'
$log = Join-Path $env:TEMP 'zquick.log'
$cfgFile = Join-Path $root 'zquick.json'
$snap = Join-Path $env:TEMP 'zq3261-snap.json'
$fdir = Join-Path $root 'dist\obj\zq3261'
Remove-Item $fdir -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Force -Path $fdir
Copy-Item $cfgFile $snap -Force
$instRunning = [bool](Get-Process zquick -ErrorAction SilentlyContinue)
$fake = $null
function Cleanup {
    Stop-Process -Name zquick -Force -ErrorAction SilentlyContinue
    # dev rodando como pwsh/powershell -File zquick.ps1 segura o MESMO mutex
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zquick\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($fake) { try { Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue } catch {} }
    Copy-Item $snap $cfgFile -Force
    if ($instRunning) { Start-Process "$env:LOCALAPPDATA\Programs\ZQuick\zquick.exe" }
}
trap { "ERRO(original): $_"; Cleanup; throw }
try {
    # 1. fake API em modo saldo
    $fake = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $root 'fake-api.ps1'), '-Dir', $fdir, '-Balance') -PassThru -WindowStyle Hidden
    $portFile = Join-Path $fdir 'port.txt'
    $dl = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $dl -and -not (Test-Path $portFile)) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path $portFile)) { throw 'fake-api nao publicou a porta' }
    $port = (Get-Content $portFile -Raw).Trim()
    "fake-api: 127.0.0.1:$port (modo saldo 429/1113)"

    # 2. aponta o perfil ativo pro fake (app PARADO — exe E dev-pwsh seguram o mutex)
    Stop-Process -Name zquick -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zquick\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    $pn = [string]$j.profile
    $j.profiles.$pn.baseUrl = "http://127.0.0.1:$port"
    $j.profiles.$pn.apiKey = 'fake-key-e2e'
    $j.model = 'glm-5.3'
    $j | ConvertTo-Json -Depth 6 | ForEach-Object { [IO.File]::WriteAllText($cfgFile, $_, (New-Object Text.UTF8Encoding($false))) }

    # 3. sobe o dev e manda 'oi'
    $mark0 = [IO.File]::ReadAllText($log).Length
    Start-Process (Join-Path $root 'zquick.exe') -WorkingDirectory $root
    $procId = 0; $dl = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $dl) { $ps = @(Get-Process zquick -ErrorAction SilentlyContinue); if ($ps.Count) { $procId = $ps[0].Id; break }; Start-Sleep -Milliseconds 300 }
    if (-not $procId) { throw 'app nao subiu' }
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    $mw = $null; $dl = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $dl -and -not $mw) {
        Start-Sleep -Milliseconds 400
        $mw = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
    }
    if (-not $mw) { throw 'janela nao abriu' }
    Start-Sleep -Seconds 2
    $ib = $mw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')))
    if (-not $ib) { throw 'InputBox nao achado' }
    $ib.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('oi')
    $sb = $mw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'SendBtn')))
    if (-not $sb) { throw 'SendBtn nao achado' }
    $sb.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    'mensagem enviada'

    # 4. espera o turno fechar com o erro de saldo
    $seg = ''; $dl = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 600
        try { $seg = [IO.File]::ReadAllText($log).Substring($mark0) } catch { $seg = '' }
        if ($seg -match 'respondido') { break }
    }
    if ($seg -notmatch 'respondido') { throw 'turno nao fechou: ' + $seg }
    if ($seg -notmatch 'SALDO') { throw 'erro nao veio amigavel (SALDO): ' + ($seg -split "`n" | Select-Object -Last 5) }
    'log: erro de SALDO amigavel no respondido'

    # 5. oraculo dos requests: exatamente 1 POST (sem retry, sem fallback)
    Start-Sleep -Milliseconds 800
    $reqs = @(Get-Content (Join-Path $fdir 'req.log') | Where-Object { $_ -match '^req#' })
    "POSTs no fake: $($reqs.Count) -> $($reqs -join ' | ')"
    if ($reqs.Count -ne 1) { throw "esperava 1 POST, vieram $($reqs.Count) (retry/fallback rolando)" }
    if ($seg -match 'tentativa 2|fallback') { throw 'log mostra retry ou fallback' }
    'sem retry e sem fallback de modelo'
    if ($seg -match 'FATAL') { throw 'FATAL no log' }
    'VERDICTO: OK (429/1113 => SALDO amigavel, 1 POST so, sem retry/fallback)'
} finally { Cleanup; 'limpeza feita' }
