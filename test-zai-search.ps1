# test-zai-search.ps1 — sonda: a Z.ai aceita server tool de busca no /v1/messages?
# Uso: pwsh -File test-zai-search.ps1 -ToolJson '{"type":"web_search_20250305","name":"web_search"}'
#       pwsh -File test-zai-search.ps1 -ToolJson ''   (controle: sem tools)
param(
  [string]$ToolJson = '{"type":"web_search_20250305","name":"web_search"}',
  [string]$Model = 'glm-5.3',
  [string]$Pergunta = 'Qual a cotacao do dolar comercial hoje? Use a busca (web_search) e cite a fonte com link.'
)
$ErrorActionPreference = 'Stop'

# herda config do Claude Code (mesma fonte que o ZQuick usa quando apiKey/baseUrl = null)
$cfg  = Get-Content (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw | ConvertFrom-Json
$base = [string]$cfg.env.ANTHROPIC_BASE_URL
$key  = [string]$cfg.env.ANTHROPIC_AUTH_TOKEN
if (-not $base) { $base = 'https://api.z.ai/api/anthropic' }  # default do kit
$base = $base.TrimEnd('/')
if (-not $key) { throw 'settings.json sem ANTHROPIC_AUTH_TOKEN' }
"endpoint: $base/v1/messages (chave oculta)"
"tools:    " + $(if ($ToolJson) { $ToolJson } else { '(nenhum — controle)' })

$body = @{
  model       = $Model
  max_tokens  = 1024
  stream      = $true
  messages    = @(@{ role = 'user'; content = $Pergunta })
}
if ($ToolJson) { $body.tools = @( $ToolJson | ConvertFrom-Json ) }
$json = $body | ConvertTo-Json -Depth 8 -Compress

Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(150)
$req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, ($base + '/v1/messages'))
$null = $req.Headers.TryAddWithoutValidation('Authorization', "Bearer $key")
$null = $req.Headers.TryAddWithoutValidation('anthropic-version', '2023-06-01')
$req.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
"HTTP $([int]$resp.StatusCode) (headers em $($sw.Elapsed.TotalSeconds.ToString('0.0'))s)"
if (-not $resp.IsSuccessStatusCode) {
  'ERRO BODY: ' + $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  return
}

$sr  = [System.IO.StreamReader]::new($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
$types  = @{}
$blocks = @()   # content_block_start: type/name/id
$text   = ''
$usage  = ''
while ($null -ne ($line = $sr.ReadLine())) {
  if (-not $line.StartsWith('data:')) { continue }
  $d = $line.Substring(5).Trim()
  if ($d -eq '[DONE]') { break }
  try { $o = $d | ConvertFrom-Json } catch { continue }
  if ($o.type) { $types[$o.type] = 1 + $types[$o.type] }
  if ($o.type -eq 'error') { 'STREAM ERRO: ' + $d }
  if ($o.type -eq 'content_block_start') {
    $cb = $o.content_block
    $blocks += ('[{0}] type={1} name={2} id={3}' -f $o.index, $cb.type, $cb.name, $cb.id)
    # blocos de resultado de busca: mostra o payload bruto (titulo/url) — truncado
    if ($cb.type -notIn @('text','tool_use')) {
      $raw = $cb | ConvertTo-Json -Depth 6 -Compress
      if ($raw.Length -gt 1200) { $raw = $raw.Substring(0,1200) + ' …(trunc)' }
      '  payload: ' + $raw
    }
  }
  if ($o.type -eq 'content_block_delta' -and $o.delta.type -eq 'text_delta') { $text += $o.delta.text }
  if ($o.message -and $o.message.usage) { $u = $o.message.usage | ConvertTo-Json -Compress; $usage = $u }
  if ($o.usage) { $usage = $o.usage | ConvertTo-Json -Compress }
}
$sw.Stop()

''
'== eventos =='
$types.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0,-28} x{1}' -f $_.Key, $_.Value }
''
'== blocos =='
if ($blocks) { $blocks } else { '(nenhum)' }
if ($usage)  { 'usage: ' + $usage }
''
'== texto final (inicio 300 + final 700) =='
if ($text.Length -gt 1000) { $text.Substring(0,300) + "`n…[meio cortado]…`n" + $text.Substring($text.Length-700) } else { $text }
''
"total: $($sw.Elapsed.TotalSeconds.ToString('0.0'))s"
