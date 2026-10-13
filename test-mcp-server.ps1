# test-mcp-server.ps1 — FIXTURE: servidor MCP minimo em PowerShell (stdio JSON-RPC).
# Usado pelo test-mcp-engine.ps1 para validar o cliente MCP do ZQuick sem
# depender de node/python. Responde initialize / tools/list / tools/call.
# A tool "echo" tem "pattern" no schema DE PROPOSITO — o cliente tem que saneá-lo.
$ErrorActionPreference = 'Stop'
try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

function Send-Resp($id, $result) {
    $o = [ordered]@{ jsonrpc = '2.0'; id = $id; result = $result }
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Depth 10 -Compress))
    [Console]::Out.Flush()
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if (-not $line.Trim()) { continue }
    try { $m = $line | ConvertFrom-Json } catch { continue }
    if ($null -eq $m.id) { continue }   # notification (notifications/initialized etc.)
    switch ([string]$m.method) {
        'initialize' {
            Send-Resp $m.id @{ protocolVersion = '2024-11-05'; capabilities = @{}; serverInfo = @{ name = 'zq-fixture'; version = '1.0' } }
        }
        'tools/list' {
            Send-Resp $m.id @{ tools = @(
                @{ name = 'echo'
                   description = 'Ecoa o texto recebido'
                   inputSchema = @{ type = 'object'; properties = @{ texto = @{ type = 'string'; pattern = '^.+$' } }; required = @('texto') } }
            ) }
        }
        'tools/call' {
            $t = [string]$m.params.arguments.texto
            Send-Resp $m.id @{ content = @( @{ type = 'text'; text = ('eco: ' + $t) } ) }
        }
        default { Send-Resp $m.id @{} }
    }
}
