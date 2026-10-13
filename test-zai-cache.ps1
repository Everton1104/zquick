# test-zai-cache.ps1 — sonda: o endpoint Anthropic da Z.ai aceita cache_control?
# Tres idas iguais de-stream (pra ver usage): A plain / B com cache_control(system+tools) / C repetida.
# Veredito: B HTTP 200 = aceita; usage.cache_read_input_tokens crescendo em C = cache real.
param([string]$Model = 'glm-5.3-flash')
$ErrorActionPreference = 'Stop'

$cfg  = Get-Content (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw | ConvertFrom-Json
$base = ([string]$cfg.env.ANTHROPIC_BASE_URL); if (-not $base) { $base = 'https://api.z.ai/api/anthropic' }
$key  = [string]$cfg.env.ANTHROPIC_AUTH_TOKEN
$base = $base.TrimEnd('/')

# prefixo GORDO (>1024 tokens, minimo cacheavel) p/ provar cache real
$pad = ('O ZQuick e um assistente residente no Windows que responde perguntas rapidas em portugues. ' * 60)
$sys = "Voce e um assistente de teste. Responda com uma palavra. $pad"
$msg = '{"role":"user","content":"diga ok"}'
$toolsA = '[{"name":"eco","description":"ecoa","input_schema":{"type":"object","properties":{"t":{"type":"string"}},"required":["t"]}}]'
$toolsB = '[{"name":"eco","description":"ecoa","input_schema":{"type":"object","properties":{"t":{"type":"string"}},"required":["t"]},"cache_control":{"type":"ephemeral"}}]'

function One([string]$label, [string]$sysJson, [string]$toolsJson) {
  $body = '{"model":"' + $Model + '","max_tokens":32,"stream":true,"system":' + $sysJson + ',"tools":' + $toolsJson + ',"messages":[' + $msg + ']}'
  Add-Type -AssemblyName System.Net.Http
  $client = [System.Net.Http.HttpClient]::new(); $client.Timeout = [TimeSpan]::FromSeconds(90)
  $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, ($script:base + '/v1/messages'))
  $null = $req.Headers.TryAddWithoutValidation('Authorization', "Bearer $script:key")
  $null = $req.Headers.TryAddWithoutValidation('anthropic-version', '2023-06-01')
  $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
  $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
  if (-not $resp.IsSuccessStatusCode) {
    "$label : HTTP $([int]$resp.StatusCode) — " + $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult().Substring(0, [Math]::Min(300, 999))
    return
  }
  $sr = [System.IO.StreamReader]::new($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
  $usage = ''
  while ($null -ne ($line = $sr.ReadLine())) {
    if (-not $line.StartsWith('data:')) { continue }
    $d = $line.Substring(5).Trim()
    if ($d -eq '[DONE]') { break }
    try { $o = $d | ConvertFrom-Json } catch { continue }
    if ($o.type -eq 'message_start' -and $o.message.usage) { $usage = $o.message.usage | ConvertTo-Json -Compress }
    if ($o.type -eq 'message_delta' -and $o.usage) { $usage = $o.usage | ConvertTo-Json -Compress }
  }
  $sr.Close(); $client.Dispose()
  "$label : 200 | usage: $usage"
}

One 'A plain (sem cache_control)'            ('"' + $sys + '"') $toolsA
One 'B cache_control (system array + tool)'  ('[{"type":"text","text":"' + $sys + '","cache_control":{"type":"ephemeral"}}]') $toolsB
One 'C repetida de B'                        ('[{"type":"text","text":"' + $sys + '","cache_control":{"type":"ephemeral"}}]') $toolsB
