# test-v320-update-e2e.ps1 - v3.20: atualizacao automatica via GitHub.
# Cenario A (padrao): copia do app numa pasta de teste aponta updateUrl para um
# servidor falso na 127.0.0.1 que serve um "release v99.0.0" (asset = o proprio
# zquick.exe). Fluxo REAL: auto-check no boot (20s) acha -> config/Geral
# "procurar agora" confirma -> dialogo -> atualizar = baixa, troca o exe
# (atual vira .old), REINICIA sozinho, remove o .old no boot seguinte e o
# throttle nao reconsulta. O app do usuario e' parado durante o teste.
# Cenario B (-Real): aponta para o GitHub de verdade (sem updateUrl) e espera
# "versao mais recente" — rodar DEPOIS de publicar o release v3.20.0.
# ASCII-only (5.1/ANSI); acentos por codigo de caractere.
param([switch]$Real)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$repo  = 'C:\Users\EVTU-DELL\.local\bin\zquick'
$test  = Join-Path $env:TEMP 'zq-upd'
$testExe = Join-Path $test 'zquick.exe'
$log   = Join-Path $env:TEMP 'zquick.log'
$port  = 8791
$idi    = [string][char]0xE9   # i agudo (min.) para mensagens

function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }
function Wait-Log([string]$pat, [int]$mark, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 500
        if ((Read-New $mark) -match $pat) { return $true }
    }
    return $false
}
$root = [System.Windows.Automation.AutomationElement]::RootElement
function Get-ProcId { try { return (Get-Process zquick -ErrorAction Stop | Where-Object { $_.Path -eq $testExe } | Select-Object -First 1).Id } catch { return $null } }
function Find-Wins([int]$procId) {
    # dialogos com Owner ficam como FILHOS da janela dona na arvore UIA (licao do
    # E2E v3.19) — desce 2 niveis: main -> config -> dialogo de update
    $pcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    $c = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond))
    $frontier = @($c)
    for ($i = 0; $i -lt 2; $i++) {
        $next = @()
        foreach ($w in $frontier) { $next += @($w.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
        if (-not $next.Count) { break }
        $c += $next; $frontier = $next
    }
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
function Wait-Win([int]$procId, [string]$nameLike, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        $w = Find-Wins $procId | Where-Object { $_.Current.Name -like $nameLike } | Select-Object -First 1
        if ($w) { return $w }
        Start-Sleep -Milliseconds 400
    }
    return $null
}
function Wait-Text($win, [string]$id, [string]$pat, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        $el = Find-ById $win $id
        if ($el -and ([string]$el.Current.Name) -match $pat) { return [string]$el.Current.Name }
        Start-Sleep -Milliseconds 600
    }
    return $null
}

# ---- prepara a pasta de teste (exe + json proprio; log e' o mesmo do usuario) ----
Stop-Process -Name zquick -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 700
if (Test-Path $test) { Remove-Item $test -Recurse -Force }
New-Item -ItemType Directory -Force $test | Out-Null
Copy-Item (Join-Path $repo 'zquick.exe') $testExe -Force
Copy-Item (Join-Path $repo 'zquick.ps1') (Join-Path $test 'zquick.ps1') -Force
$cfg = @{
    profile = 'zai'; model = 'auto'; hotkey = 'alt+f9'; maxTokens = 2048
    checkUpdates = $true
    profiles = @{ zai = @{ label = 'teste'; baseUrl = 'http://127.0.0.1:1'; apiKey = 'x'
                           fastModel = 'a'; bigModel = 'a'; models = @('a') } }
}
if (-not $Real) { $cfg.updateUrl = ('http://127.0.0.1:' + $port + '/rel.json') }
$cfg | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $test 'zquick.json') -Encoding utf8

$srv = $null
if (-not $Real) {
    $srv = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repo 'fake-upd-server.ps1'),'-Port',"$port",'-ExePath',$testExe,'-Tag','v99.0.0') -WindowStyle Hidden -PassThru
    $dl = (Get-Date).AddSeconds(10); $up = $false
    while ((Get-Date) -lt $dl -and -not $up) {
        try { $c = [Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', $port); $c.Close(); $up = $true } catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $up) { throw 'servidor fake nao subiu' }
    'servidor fake no ar (release v99.0.0, asset = o proprio exe)'
}

$mark0 = [IO.File]::ReadAllText($log).Length
Start-Process $testExe
$pid0 = $null; $dl = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $dl -and -not $pid0) { $pid0 = Get-ProcId; if (-not $pid0) { Start-Sleep -Milliseconds 300 } }
if (-not $pid0) { throw 'exe de teste nao subiu' }
"exe de teste: PID $pid0"
trap {
    Write-Host ('ERRO-TESTE: ' + $_.Exception.Message) -ForegroundColor Red
    try { Stop-Process -Id $pid0 -Force -ErrorAction SilentlyContinue } catch {}
    throw
}

$mw = Wait-Win $pid0 '*busca*' 15
if (-not $mw) { throw 'janela principal nao abriu' }
'janela principal aberta'

# ---- 1. auto-check do boot (20s) ----
if ($Real) {
    if (-not (Wait-Log 'update: (em dia|consulta falhou)' $mark0 45)) { throw 'auto-check do boot nao logou nada' }
    $t1 = Read-New $mark0
    "auto-check: $($t1 -split "`n" | Select-String 'update:' | Select-Object -First 1)"
} else {
    if (-not (Wait-Log 'update: NOVA vers' $mark0 45)) { throw 'auto-check do boot nao achou a versao nova' }
    "auto-check do boot achou: $((((Read-New $mark0) -split "`n" | Select-String 'NOVA vers' | Select-Object -First 1).Line).Trim())"
}

# ---- 2. config -> Geral -> procurar agora ----
$null = Invoke-ById $mw 'SettingsBtn'
$sw = Wait-Win $pid0 '*configura*' 10
if (-not $sw) { throw 'configuracoes nao abriram' }
$tabCond = New-Object System.Windows.Automation.AndCondition @(
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)),
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Geral')))
$tab = $sw.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
if (-not $tab) {
    $tiCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $all = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tiCond) | ForEach-Object { $_.Current.Name })
    throw ('aba Geral nao achada; TabItems no dialogo: [' + ($all -join ' | ') + ']')
}
$tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Start-Sleep -Milliseconds 900   #TabControl so renderiza a aba selecionada (licao v3.18)
$mark1 = [IO.File]::ReadAllText($log).Length
$null = Invoke-ById $sw 'SetUpdCheck'
'procurar agora: clicado'

if ($Real) {
    $st = Wait-Text $sw 'SetUpdStatus' ('mais recente|n' + [char]0xE3 + 'o consegui') 45
    if (-not $st) { throw 'SetUpdStatus nao respondeu' }
    if ($st -notmatch 'mais recente') { throw "esperava 'mais recente', veio: $st" }
    "GitHub real: $st"
    # fecha config e encerra
    $null = Invoke-ById $sw 'SetClose'
    Start-Sleep -Milliseconds 600
    if (-not (Get-Process -Id $pid0 -ErrorAction SilentlyContinue)) { throw 'processo morreu sem motivo' }
    if ((Read-New $mark0) -match 'FATAL') { throw 'FATAL no log' }
    Stop-Process -Id $pid0 -Force
} else {
    $st = Wait-Text $sw 'SetUpdStatus' 'dispon' 45
    if (-not $st) { throw 'SetUpdStatus nao mostrou a versao nova' }
    "status no config: $st"

    # ---- 3. dialogo de atualizacao -> atualizar e reiniciar ----
    $uw = Wait-Win $pid0 '*atualiza*' 10
    if (-not $uw) { throw 'dialogo de atualizacao nao abriu' }
    'dialogo de atualizacao aberto'
    $ver = [string](Find-ById $uw 'UpdVer').Current.Name
    if ($ver -notmatch '99\.0\.0') { throw "UpdVer nao cita 99.0.0: '$ver'" }
    "dialogo diz: $ver"
    try { $null = Invoke-ById $uw 'UpdGo' } catch {}   # o processo morre durante o Invoke — normal
    'atualizar clicado (baixa + troca + reinicia)'

    # ---- 4. trocou o exe (.old), reiniciou sozinho e o .old sumiu no boot ----
    if (-not (Wait-Log 'instalado.*reiniciando' $mark1 40)) { throw 'nao logou a troca do exe' }
    $old = $testExe + '.old'
    $dl = (Get-Date).AddSeconds(15); $sawOld = $false
    while ((Get-Date) -lt $dl -and -not $sawOld) { if (Test-Path $old) { $sawOld = $true } else { Start-Sleep -Milliseconds 150 } }
    if (-not $sawOld) { 'aviso: .old nao visto no disco (pode ter sido limpo rapido) — confere pelo log' }
    $pid1 = $null; $dl = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $dl -and -not $pid1) { $pp = Get-ProcId; if ($pp -and $pp -ne $pid0) { $pid1 = $pp } else { Start-Sleep -Milliseconds 400 } }
    if (-not $pid1) { throw 'app nao reiniciou sozinho apos a troca' }
    "reiniciou sozinho: PID $pid0 -> $pid1"
    # a limpeza do .old roda no boot da nova copia (~2s) — espera o log, nao o disco na hora
    if (-not (Wait-Log 'update: removeu zquick\.exe\.old' $mark1 40)) { throw 'novo boot nao removeu o .old' }
    if (Test-Path $old) { throw '.old ainda no disco apos o log de limpeza' }
    '.old removido no boot da nova copia'

    # ---- 5. throttle: nova instancia NAO reconsulta (consultou ha pouco) ----
    $mark2 = [IO.File]::ReadAllText($log).Length
    if (-not (Wait-Log 'update: pulou \(consultou' $mark2 40)) { throw 'throttle nao pulou a consulta no novo boot' }
    'throttle ok (nao reconsultou)'
    if ((Read-New $mark0) -match 'FATAL') { throw 'FATAL no log' }
    Stop-Process -Id $pid1 -Force
}

# ---- limpeza e app do usuario de volta ----
if ($srv) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500
Remove-Item $test -Recurse -Force -ErrorAction SilentlyContinue
Start-Process (Join-Path $repo 'zquick.exe')
$dl = (Get-Date).AddSeconds(20); $okBoot = $false
while ((Get-Date) -lt $dl) {
    $t = try { [IO.File]::ReadAllText($log) } catch { '' }
    if ($t -match 'engine compilado') { $okBoot = $true; break }
    Start-Sleep -Milliseconds 400
}
if (-not $okBoot) { throw 'app do usuario nao voltou limpo' }
'app do usuario de volta no ar'
if ($Real) { "VERDICTO: OK (GitHub real consultado pelo app; versao mais recente reconhecida)" }
else { "VERDICTO: OK (auto-check no boot + manual no config + download + troca do exe + reinicio sozinho + limpeza do .old + throttle)" }
