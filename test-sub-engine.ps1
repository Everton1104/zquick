# test-sub-engine.ps1 — headless COM API REAL: subagente de leitura (Onda 5).
# SubResearch roda o loop aninhado (ate' 6 rodadas, so' leitura) contra o endpoint
# Anthropic da Z.ai e devolve o RELATORIO como viria no tool_result. A chave é lida
# AQUI do settings.json (nunca impressa). pwsh -NoProfile -File test-sub-engine.ps1
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText("$PSScriptRoot\zquick.ps1")
if ($src -notmatch "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@") { throw 'engineCs nao extraido' }
Add-Type -TypeDefinition $Matches[1]

$sj = Get-Content (Join-Path $HOME '.claude\settings.json') -Raw | ConvertFrom-Json
$base = if ($sj.env.ANTHROPIC_BASE_URL) { [string]$sj.env.ANTHROPIC_BASE_URL } else { 'https://api.z.ai/api/anthropic' }
$key = [string]$sj.env.ANTHROPIC_AUTH_TOKEN
if (-not $key) { throw 'sem ANTHROPIC_AUTH_TOKEN no settings.json' }

$queue = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$eng = [ZQuick.Engine]::new($base, $key, 'glm-5.3', $null, $null, 4096, 'bing', $queue, $false)

# cenario: achar em qual dos 3 arquivos esta' o marcador (sub precisa de file_grep/read)
$dir = Join-Path $env:TEMP ('zqsub-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $dir | Out-Null
Set-Content (Join-Path $dir 'um.txt') 'conteudo comum numero um'
Set-Content (Join-Path $dir 'dois.txt') "linha neutra`nZQ5-SUB-ALFA marcador alvo da busca`noutra linha"
Set-Content (Join-Path $dir 'tres.txt') 'conteudo comum numero tres'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = $eng.SubResearch("Na pasta $dir existe um arquivo contendo o marcador ZQ5-SUB-ALFA. Descubra qual e reporte o nome do arquivo e a linha exata que contem o marcador.", $dir, [System.Threading.CancellationToken]::None)
$secs = [int]$sw.Elapsed.TotalSeconds

# drena a fila: status do subagent chegaram? deltas do sub NAO chegaram?
$msgs = @(); $m = $null
while ($queue.TryDequeue([ref]$m)) { $msgs += [string]$m.Text; $m = $null }

$fail = @()
if ($r -notmatch 'do subagente de leitura \(\d+s\)') { $fail += "retorno sem cabecalho de relatorio: $($r.Substring(0, [Math]::Min(120, $r.Length)))" }
if ($r -notmatch 'ZQ5-SUB-ALFA') { $fail += 'relatorio sem o marcador' }
if ($r -notmatch 'dois\.txt') { $fail += 'relatorio sem o nome do arquivo certo' }
if (-not (@($msgs | Where-Object { $_ -match 'subagente' }).Count)) { $fail += 'nenhum status de subagente emitido' }
if (@($msgs | Where-Object { $_ -match '1º token em' }).Count) { $fail += 'note de TTFT do sub vazou pro card principal' }

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
if ($fail.Count) { $fail | ForEach-Object { "FAIL: $_" }; throw "test-sub-engine: $($fail.Count) falha(s)" }
"PASS: sub-engine — subagente investigou sozinho e relatou (${secs}s)"
