# test-mcp-engine.ps1 — headless: cliente MCP minimo (Onda 4). Sobe o fixture
# test-mcp-server.ps1 por stdio JSON-RPC e valida: initialize -> tools/list ->
# saneamento de "pattern" -> tools/call round-trip -> shutdown mata o filho.
# pwsh -NoProfile -File test-mcp-engine.ps1
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText("$PSScriptRoot\zquick.ps1")
if ($src -notmatch "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@") { throw 'engineCs nao extraido' }
Add-Type -TypeDefinition $Matches[1]

$queue = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$eng = [ZQuick.Engine]::new('https://api.z.ai/api/anthropic', 'x', 'glm-5.3-flash', $null, $null, 64, 'bing', $queue, $false)

$fixture = Join-Path $PSScriptRoot 'test-mcp-server.ps1'
$cfg = @{ fixture = @{ command = 'pwsh'; args = @('-NoProfile', '-File', $fixture) } } | ConvertTo-Json -Depth 5 -Compress
$eng.SetMcpConfig($cfg)

try {
    $fail = @()
    $n = $eng.McpInit()
    if ($n -ne 1) {
        $msgs = @(); $m = $null
        while ($queue.TryDequeue([ref]$m)) { $msgs += [string]$m.Text; $m = $null }
        throw "McpInit esperava 1 tool, veio $n — notas: $($msgs -join ' | ')"
    }
    $schema = $eng.McpToolSchema('mcp_fixture_echo')
    if (-not $schema) { $fail += 'schema da tool MCP nao encontrado' }
    else {
        if ($schema -notmatch 'mcp_fixture_echo') { $fail += 'schema sem o nome prefixado' }
        if ($schema -match '"pattern"') { $fail += 'pattern NAO foi saneado (Z.ai rejeitaria, erro 1210)' }
        if ($schema -notmatch '\[MCP fixture\]') { $fail += 'descricao sem o rotulo [MCP fixture]' }
    }
    $out = $eng.McpCall('mcp_fixture_echo', '{"texto":"ZQ-MCP-OK"}')
    if ($out -notmatch 'eco: ZQ-MCP-OK') { $fail += "round-trip tools/call falhou: $out" }
    $unk = $eng.McpCall('mcp_fixture_nada', '{}')
    if ($unk -notmatch 'tool desconhecida') { $fail += "tool inexistente nao reportou erro: $unk" }

    if ($fail.Count) { $fail | ForEach-Object { "FAIL: $_" }; throw "test-mcp-engine: $($fail.Count) falha(s)" }
    'PASS: mcp-engine — initialize/tools/list/sanitize/call round-trip'
}
finally {
    $eng.ShutdownMcp()
    Start-Sleep -Milliseconds 800
    $left = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'pwsh%'" |
        Where-Object { $_.CommandLine -like '*test-mcp-server.ps1*' -and $_.ProcessId -ne $PID })
    if ($left.Count -gt 0) { throw "fixture ainda vivo apos ShutdownMcp: $($left.ProcessId -join ',')" }
    'PASS: mcp-shutdown — processo filho encerrado'
}
