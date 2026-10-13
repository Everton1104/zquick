# test-par4-ui.ps1 — E2E da Onda 4 (app residente, oráculo = zquick.log):
#   fase 1: injeta mcpServers (fixture stdio) no zquick.json AO VIVO + restart
#   fase 2: pergunta que pede file_list + file_read juntos -> tools de leitura
#           (paralelismo #5; headless ja' provou ordem/ids — aqui prova o caminho real)
#   fase 3: pergunta que usa a tool MCP -> note 'mcp fixture: 1 tool' +
#           '⚙ mcp_fixture_echo' + resposta com o eco
#   fase 4: restaura o json original + restart + mata sobras do fixture
# Rodar com: pwsh -STA -File test-par4-ui.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
Add-Type -Namespace K -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$cfgPath = Join-Path $PSScriptRoot 'zquick.json'
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
function Read-LogText {
    # o app segura o log por instantes no Add-Content — leitura com retry
    for ($i = 0; $i -lt 10; $i++) {
        try { return [IO.File]::ReadAllText($log) } catch { Start-Sleep -Milliseconds 150 }
    }
    throw 'log travado para leitura'
}
function Read-New([int]$mark) { (Read-LogText).Substring($mark) }
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        $new = Read-New $mark
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 500
    }
    return ''
}
function Get-MainWin([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    foreach ($w in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($w.Current.Name -like '*ZQuick*' -and $w.Current.Name -notlike '*hist*') { return $w }
    }
    $null
}
function Find-ById($win, [string]$id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}
function Restart-App {
    $mark = (Read-LogText).Length
    $null = schtasks /End /TN ZQuick 2>$null
    Start-Sleep -Milliseconds 1200
    Get-CimInstance Win32_Process -Filter "Name LIKE 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 1200
    $null = schtasks /Run /TN ZQuick
    if (-not (Wait-Log $mark 'hotkey .* -> True' 45)) { throw 'app nao reiniciou (sem hotkey no log)' }
    Start-Sleep -Milliseconds 600
}
function Ask-Ui([string]$text) {
    $app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' -and $_.ProcessId -ne $PID } | Select-Object -First 1
    if (-not $app) { throw 'processo zquick nao achado' }
    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }
    $tb = Find-ById $w 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $p = $tb.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
    (Read-LogText).Length
}

$cfgBak = Get-Content $cfgPath -Raw
$fix = Join-Path $env:TEMP ('zquick-par4-' + (Get-Date -Format 'HHmmss'))
$fixture = Join-Path $PSScriptRoot 'test-mcp-server.ps1'
$restored = $false
try {
    New-Item -ItemType Directory -Force $fix | Out-Null
    Set-Content -Path (Join-Path $fix 'a.txt') -Value 'ZQ4-E2E-PAR conteudo alfa' -Encoding utf8
    Set-Content -Path (Join-Path $fix 'b.txt') -Value 'conteudo beta comum' -Encoding utf8

    # fase 1: injeta mcpServers no json ao vivo + restart
    $j = $cfgBak | ConvertFrom-Json
    $j | Add-Member -NotePropertyName mcpServers -NotePropertyValue (
        [pscustomobject]@{ fixture = [pscustomobject]@{ command = 'pwsh'; args = @('-NoProfile', '-File', $fixture) } }) -Force
    $j | ConvertTo-Json -Depth 8 | Set-Content -Path $cfgPath -Encoding utf8
    Restart-App
    'fase 1: mcpServers injetado, app reiniciado'

    # fase 2: leitura dupla (file_list + file_read) num turno so
    $mark = Ask-Ui "faca de uma vez, sem me perguntar nada: (1) use file_list na pasta $fix e (2) use file_read no arquivo $fix\a.txt; depois responda em 1 frase quantos arquivos ha na pasta e qual o texto exato do arquivo a.txt"
    $done = Wait-Log $mark 'respondido: |engine: |FATAL' 150
    if (-not $done) { throw "fase 2 sem resposta. log: $(Read-New $mark)" }
    if ($done -match 'FATAL') { throw "fase 2 FATAL: $done" }
    if ($done -notmatch 'file_list') { throw "fase 2: file_list nao rodou. log: $done" }
    if ($done -notmatch 'file_read') { throw "fase 2: file_read nao rodou. log: $done" }
    if ($done -notmatch 'ZQ4-E2E-PAR') { throw "fase 2: resposta sem o conteudo lido. log: $done" }
    $parInfo = if ($done -match '(\d+) tools em paralelo') { "PARALELO CONFIRMADO ($($Matches[1]) tools)" } else { 'nota: modelo emitiu as tools em rodadas separadas (paralelismo nao exercitado neste turno)' }
    "PASS fase 2: leitura dupla OK — $parInfo"
    Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 700

    # fase 3: tool MCP ao vivo (o note 'mcp fixture: N tools' sai so' no 1o turno
    # do app — na fase 2 — pois McpInit e' idempotente; aqui valida a chamada)
    $mark = Ask-Ui 'use a ferramenta mcp_fixture_echo passando o texto ONDA4-LIVE e me diga exatamente qual texto ela devolveu (copie a resposta da ferramenta)'
    $srvUp = Wait-Log $mark 'mcp_fixture_echo|engine: |FATAL' 90
    if (-not $srvUp) { throw "fase 3: tool mcp nao apareceu. log: $(Read-New $mark)" }
    $done = Wait-Log $mark 'respondido: |engine: |FATAL' 150
    if (-not $done) { throw "fase 3 sem resposta. log: $(Read-New $mark)" }
    if ($done -match 'FATAL') { throw "fase 3 FATAL: $done" }
    if ($done -notmatch 'mcp_fixture_echo') { throw "fase 3: tool mcp nao foi chamada. log: $done" }
    if ($done -notmatch 'ONDA4-LIVE') { throw "fase 3: resposta sem o eco. log: $done" }
    'PASS fase 3: MCP ao vivo — servidor subiu, tool chamada, eco voltou na resposta'
    Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 700
}
finally {
    # fase 4: restaura config original + restart + sweep
    try {
        Set-Content -Path $cfgPath -Value $cfgBak -Encoding utf8 -NoNewline
        $restored = $true
        Restart-App
        'fase 4: json original restaurado, app reiniciado no config limpo'
    } catch { "AVISO fase 4: falha ao restaurar/reiniciar — $_" }
    Start-Sleep -Milliseconds 800
    $left = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'pwsh%'" |
        Where-Object { $_.CommandLine -like '*test-mcp-server.ps1*' -and $_.ProcessId -ne $PID })
    if ($left.Count -gt 0) { $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; "fase 4: $($left.Count) processo(s) fixture órfão(s) encerrado(s) a forca" }
    Remove-Item $fix -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $restored) { throw 'CONFIG NAO RESTAURADO — mexer zquick.json na mao!' }
}
'PASS: par4 E2E completo'
