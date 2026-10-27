# test-v3262-saldo-wizard-e2e.ps1 - v3.26.2: benchmark do assistente separa quem
# TEM saldo de quem NAO tem (429/1113). Fake API serve 4 modelos, 2 deles sem
# saldo (glm-5.3 e glm-5.3-air respondem 1113; glm-5.3-flash e glm-4.6 ok).
# Esperado: lista marca "sem saldo", recomendacoes (rapido/forte/visao) SO com
# quem respondeu, models gravado no perfil sem os sem-saldo, log com semsaldo=...
# ASCII-only (5.1/ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$root = 'C:\Users\EVTU-DELL\.local\bin\zquick'
$log = Join-Path $env:TEMP 'zquick.log'
$cfgFile = Join-Path $root 'zquick.json'
$snap = Join-Path $env:TEMP 'zq3262-snap.json'
$fdir = Join-Path $root 'dist\obj\zq3262'
Remove-Item $fdir -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Force -Path $fdir
Copy-Item $cfgFile $snap -Force
$instRunning = [bool](Get-Process zquick -ErrorAction SilentlyContinue)
$fake = $null
function Tap([byte]$vk) {
    [K.I]::keybd_event($vk,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
    [K.I]::keybd_event($vk,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
}
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }
function Kill-All {
    Stop-Process -Name zquick -Force -ErrorAction SilentlyContinue
    # dev rodando como pwsh/powershell -File zquick.ps1 segura o MESMO mutex
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zquick\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Cleanup {
    Kill-All
    if ($fake) { try { Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue } catch {} }
    Copy-Item $snap $cfgFile -Force
    if ($instRunning) { Start-Process (Join-Path $root 'zquick.exe') -WorkingDirectory $root }
}
$procId = 0
function Find-Wins {
    $c = @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId))))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Get-MainWin {
    $dl = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $dl) {
        $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
        if ($w) { return $w }
        Start-Sleep -Milliseconds 400
    }
    throw 'janela principal nao achou'
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
    # 1. fake API: 4 modelos, 2 sem saldo (1113), 2 respondem SSE ok
    $fake = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $root 'fake-api.ps1'), '-Dir', $fdir,
        '-Models', 'glm-5.3,glm-5.3-air,glm-5.3-flash,glm-4.6', '-NoBalance', 'glm-5.3,glm-5.3-air', '-Text', 'ok') -PassThru -WindowStyle Hidden
    $portFile = Join-Path $fdir 'port.txt'
    $dl = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $dl -and -not (Test-Path $portFile)) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path $portFile)) { throw 'fake-api nao publicou a porta' }
    $port = (Get-Content $portFile -Raw).Trim()
    "fake-api: 127.0.0.1:$port (4 modelos, 2 sem saldo)"

    # 2. app dev + abre o wizard pela toolbar
    $mark0 = [IO.File]::ReadAllText($log).Length
    Start-Process (Join-Path $root 'zquick.exe') -WorkingDirectory $root
    $dl = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $dl) { $ps = @(Get-Process zquick -ErrorAction SilentlyContinue); if ($ps.Count) { $procId = $ps[0].Id; break }; Start-Sleep -Milliseconds 300 }
    if (-not $procId) { throw 'app nao subiu' }
    $win = Get-MainWin
    if (-not (Wait-Text $win 'LogoText' 'ZQuick' 15)) { throw 'app nao abriu a janela' }
    $null = Invoke-ById $win 'WizBtn'
    $wz = Wait-Win '*assistente*' 8
    if (-not $wz) { throw 'wizard nao abriu' }
    'wizard aberto (WizBtn)'

    # 3. etapa 1: URL do fake (127.0.0.1 = perfil local; chave vazia vira "local")
    $null = Set-Val $wz 'WzUrl' ("http://127.0.0.1:$port")
    $null = Invoke-ById $wz 'WzTest'
    $c = Wait-Text $wz 'WzConn' 'conectado' 20
    if (-not $c) { throw 'conexao nao ficou OK: ' + ((Find-ById $wz 'WzConn').Current.Name) }
    "etapa 1: $c"

    # 4. etapa 2: benchmark automatico -> 2 de 4 responderam, 2 sem saldo
    $null = Invoke-ById $wz 'WzNext'
    $c = Wait-Text $wz 'WzBenchStatus' 'responderam|sem saldo' 60
    if (-not $c) { throw 'benchmark nao terminou: ' + ((Find-ById $wz 'WzBenchStatus').Current.Name) }
    "etapa 2: $c"
    if ($c -notmatch '2 de 4') { throw "status nao diz 2 de 4: '$c'" }
    if ($c -notmatch 'sem saldo') { throw "status nao menciona sem saldo: '$c'" }
    $lic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = @((Find-ById $wz 'WzBenchList').FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic) | ForEach-Object { [string]$_.Current.Name })
    if ($items.Count -ne 4) { throw "lista com $($items.Count) itens (4 modelos): $($items -join ' | ')" }
    $ns = @($items | Where-Object { $_ -match 'sem saldo' })
    if ($ns.Count -ne 2) { throw "esperava 2 itens 'sem saldo': $($items -join ' | ')" }
    if (-not ($items | Where-Object { $_ -match 'sem saldo.*glm-5\.3-air' })) { throw "glm-5.3-air nao marcado sem saldo: $($items -join ' | ')" }
    if (-not ($items | Where-Object { $_ -match 'sem saldo.*glm-5\.3$' })) { throw "glm-5.3 nao marcado sem saldo: $($items -join ' | ')" }
    "lista: $($ns.Count) sem saldo + 2 com tempo -> $($items -join ' | ')"

    # 5. recomendacao: so quem respondeu (flash e 4.6), jamais glm-5.3/glm-5.3-air
    $rec = (Find-ById $wz 'WzRec').Current.Name
    if ($rec -notmatch 'glm-4\.6') { throw "forte nao e glm-4.6: '$rec'" }
    if ($rec -notmatch 'glm-5\.3-flash') { throw "visao/rapido sem glm-5.3-flash: '$rec'" }
    if ($rec -match 'glm-5\.3(?![-\w])') { throw "recomendou glm-5.3 (sem saldo): '$rec'" }
    if ($rec -match 'glm-5\.3-air') { throw "recomendou glm-5.3-air (sem saldo): '$rec'" }
    "recomendacao so com quem tem saldo: $($rec -replace [char]10, ' / ')"

    # 6. etapa 3 -> 4, checkbox preservando o usuario, Concluir
    $null = Invoke-ById $wz 'WzNext'
    foreach ($cb in @('WzAuto', 'WzModelAuto')) {
        $el = Find-ById $wz $cb
        if ($el -and $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState.ToString() -eq 'On') {
            $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle(); Start-Sleep -Milliseconds 250
        }
    }
    $null = Invoke-ById $wz 'WzNext'
    $null = Invoke-ById $wz 'WzFinish'
    $dl = (Get-Date).AddSeconds(12); $still = $null
    while ((Get-Date) -lt $dl) {
        $still = Find-Wins | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.Name -like '*assistente*' } | Select-Object -First 1
        if (-not $still) { break }
        Start-Sleep -Milliseconds 400
    }
    if ($still) { throw 'wizard nao fechou apos Concluir' }
    'concluido e fechado'

    # 7. json: perfil local ganhou models SEM os sem-saldo + recomendacoes filtradas
    Start-Sleep -Milliseconds 600
    $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
    $pp = $j.profiles.local
    if (-not $pp) { throw 'perfil local nao criado' }
    $mdl = @($pp.models) | ForEach-Object { [string]$_ }
    if ($mdl -notcontains 'auto') { throw "models sem 'auto': $($mdl -join ',')" }
    if ($mdl.Count -ne 3) { throw "models devia ter auto+2, veio $($mdl.Count): $($mdl -join ',')" }
    if ($mdl -contains 'glm-5.3') { throw 'glm-5.3 (sem saldo) entrou na lista do perfil' }
    if ($mdl -contains 'glm-5.3-air') { throw 'glm-5.3-air (sem saldo) entrou na lista do perfil' }
    if ($mdl -notcontains 'glm-5.3-flash' -or $mdl -notcontains 'glm-4.6') { throw "faltou quem TEM saldo na lista: $($mdl -join ',')" }
    if ([string]$pp.bigModel -ne 'glm-4.6') { throw "bigModel=$($pp.bigModel) (devia glm-4.6)" }
    if ([string]$pp.visionModel -ne 'glm-5.3-flash') { throw "visionModel=$($pp.visionModel) (devia glm-5.3-flash)" }
    if (@('glm-5.3-flash', 'glm-4.6') -notcontains [string]$pp.fastModel) { throw "fastModel=$($pp.fastModel) fora do esperado" }
    "json: models=$($mdl -join ',') fast=$($pp.fastModel) forte=$($pp.bigModel) visao=$($pp.visionModel)"

    # 8. log + oracle de requests
    $seg = Read-New $mark0
    if ($seg -notmatch 'semsaldo=glm-5\.3,glm-5\.3-air') { throw 'log nao lista semsaldo=glm-5.3,glm-5.3-air: ' + (($seg -split "`n" | Select-String 'wizard' | Select-Object -Last 3) -join ' ; ') }
    if ($seg -match 'FATAL') { throw 'FATAL no log' }
    $rl = @(Get-Content (Join-Path $fdir 'req.log'))
    $nModels = @($rl | Where-Object { $_ -match '^models#' }).Count
    $n429 = @($rl | Where-Object { $_ -match 'BALANCE-429' }).Count
    $nOk = @($rl | Where-Object { $_ -match '^req#' -and $_ -notmatch 'BALANCE' }).Count
    if ($nModels -ne 1 -or $n429 -ne 2 -or $nOk -ne 2) { throw "requests: models=$nModels saldo429=$n429 ok=$nOk (esperava 1/2/2): $($rl -join ' | ')" }
    "requests no fake: 1 GET models + 2 saldo-429 + 2 ok"
    'VERDICTO: OK (benchmark marca sem saldo, recomendacao e lista do perfil so com quem tem saldo)'
} finally { Cleanup; 'limpeza: app parado, json restaurado, fake morto' }
