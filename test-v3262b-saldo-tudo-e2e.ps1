# test-v3262b-saldo-tudo-e2e.ps1 - v3.26.2, cenario extremo: TODOS os modelos
# sem saldo (conta zerada, como na maquina de testes 192.168.0.150). Fake em
# -Balance: benchmark termina com mensagem clara de recarga, ninguem e
# recomendado (WzRec so com "—") e a lista marca todos como sem saldo.
# Nao conclui o wizard (nao grava json). ASCII-only (5.1/ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$root = 'C:\Users\EVTU-DELL\.local\bin\zquick'
$log = Join-Path $env:TEMP 'zquick.log'
$fdir = Join-Path $root 'dist\obj\zq3262b'
Remove-Item $fdir -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Force -Path $fdir
$fake = $null
function Tap([byte]$vk) {
    [K.I]::keybd_event($vk,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
    [K.I]::keybd_event($vk,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
}
function Kill-All {
    Stop-Process -Name zquick -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zquick\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Cleanup { Kill-All; if ($fake) { try { Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue } catch {} } }
$procId = 0
function Find-Wins {
    $c = @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId))))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Find-ById($win, [string]$id) {
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)))
}
function Invoke-ById($win, [string]$id) {
    $el = Find-ById $win $id
    if (-not $el) { throw "elemento $id nao achado" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
function Set-Val($win, [string]$id, [string]$v) {
    $el = Find-ById $win $id
    if (-not $el) { throw "elemento $id nao achado" }
    $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v)
    return $el
}
function Wait-Win([string]$like, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 400
        $w = Find-Wins | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.Name -like $like } | Select-Object -First 1
        if ($w) { return $w }
    }
    return $null
}
function Wait-Text($win, [string]$id, [string]$pat, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 500
        $el = Find-ById $win $id
        if ($el -and ([string]$el.Current.Name) -match $pat) { return [string]$el.Current.Name }
    }
    return $null
}
trap { "ERRO(original): $_"; for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; Cleanup; throw }
try {
    # 1. fake em modo saldo TOTAL (todo POST = 429/1113)
    $fake = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $root 'fake-api.ps1'), '-Dir', $fdir,
        '-Models', 'glm-5.3,glm-5.3-flash,glm-4.6', '-Balance') -PassThru -WindowStyle Hidden
    $portFile = Join-Path $fdir 'port.txt'
    $dl = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $dl -and -not (Test-Path $portFile)) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path $portFile)) { throw 'fake-api nao publicou a porta' }
    $port = (Get-Content $portFile -Raw).Trim()
    "fake-api: 127.0.0.1:$port (saldo zerado na conta)"

    # 2. app + wizard
    $mark0 = [IO.File]::ReadAllText($log).Length
    Start-Process (Join-Path $root 'zquick.exe') -WorkingDirectory $root
    $dl = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $dl) { $ps = @(Get-Process zquick -ErrorAction SilentlyContinue); if ($ps.Count) { $procId = $ps[0].Id; break }; Start-Sleep -Milliseconds 300 }
    if (-not $procId) { throw 'app nao subiu' }
    $dl = (Get-Date).AddSeconds(12); $win = $null
    while ((Get-Date) -lt $dl -and -not $win) { $win = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1; if (-not $win) { Start-Sleep -Milliseconds 400 } }
    if (-not $win) { throw 'janela principal nao achou' }
    $null = Invoke-ById $win 'WizBtn'
    $wz = Wait-Win '*assistente*' 8
    if (-not $wz) { throw 'wizard nao abriu' }

    # 3. conecta (GET nao gasta saldo) e benchmark -> todos sem saldo
    $null = Set-Val $wz 'WzUrl' ("http://127.0.0.1:$port")
    $null = Invoke-ById $wz 'WzTest'
    if (-not (Wait-Text $wz 'WzConn' 'conectado' 20)) { throw 'conexao nao ficou OK' }
    $null = Invoke-ById $wz 'WzNext'
    $c = Wait-Text $wz 'WzBenchStatus' 'SEM SALDO' 60
    if (-not $c) { throw 'status nao mostrou saldo zerado: ' + ((Find-ById $wz 'WzBenchStatus').Current.Name) }
    if ($c -notmatch '1113') { throw "mensagem nao cita 1113: '$c'" }
    if ($c -notmatch 'Recarregue') { throw "mensagem nao pede recarga: '$c'" }
    "etapa 2: $c"
    $lic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = @((Find-ById $wz 'WzBenchList').FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic) | ForEach-Object { [string]$_.Current.Name })
    if ($items.Count -ne 3) { throw "lista com $($items.Count) itens" }
    if (@($items | Where-Object { $_ -match 'sem saldo' }).Count -ne 3) { throw "nem todos marcados sem saldo: $($items -join ' | ')" }
    $rec = (Find-ById $wz 'WzRec').Current.Name
    if ($rec -match 'glm') { throw "recomendou modelo sem saldo: '$rec'" }
    "lista: 3/3 sem saldo; recomendacao vazia (so tracos)"

    # 4. log fecha o ciclo; nao conclui (nao ha nada a gravar)
    $seg = ''
    $dl = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $dl) { try { $seg = [IO.File]::ReadAllText($log).Substring($mark0) } catch { Start-Sleep -Milliseconds 300 }; if ($seg -match 'wizard: benchmark') { break } }
    if ($seg -notmatch 'wizard: benchmark 3 modelos') { throw 'log sem benchmark 3 modelos' }
    if ($seg -notmatch 'semsaldo=glm-5\.3,glm-5\.3-flash,glm-4\.6') { throw 'log sem semsaldo completo' }
    if ($seg -match 'FATAL') { throw 'FATAL no log' }
    $null = Invoke-ById $wz 'WzClose'
    'VERDICTO: OK (conta zerada => mensagem de recarga, zero recomendacoes, todos marcados sem saldo)'
} finally { Cleanup; 'limpeza: app parado, fake morto' }
