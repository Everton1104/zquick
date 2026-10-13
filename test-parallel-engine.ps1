# test-parallel-engine.ps1 — headless: ExecTools executa tools de LEITURA em
# paralelo (#5, Onda 4) e devolve os tool_results na ORDEM original com ids
# casados. pwsh -NoProfile -File test-parallel-engine.ps1
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText("$PSScriptRoot\zquick.ps1")
if ($src -notmatch "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@") { throw 'engineCs nao extraido' }
Add-Type -TypeDefinition $Matches[1]

$queue = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$eng = [ZQuick.Engine]::new('https://api.z.ai/api/anthropic', 'x', 'glm-5.3-flash', $null, $null, 64, 'bing', $queue, $false)

# cenario: 3 tool_use de leitura (file_read + file_grep + file_list)
$dir = Join-Path $env:TEMP ('zqpar-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $dir | Out-Null
Set-Content (Join-Path $dir 'a.txt') 'ZQPAR-ALFA'
Set-Content (Join-Path $dir 'b.txt') 'ZQPAR-BETA'

function New-Blk([string]$id, [string]$name, [object]$inputObj) {
    $b = [ZQuick.Engine+Blk]::new()
    $b.Kind = 'tool_use'; $b.Id = $id; $b.Name = $name
    [void]$b.Input.Append(($inputObj | ConvertTo-Json -Compress))
    $b
}
$list = [System.Collections.Generic.List[ZQuick.Engine+Blk]]::new()
$list.Add((New-Blk 't1' 'file_read'  @{ path = (Join-Path $dir 'a.txt') }))
$list.Add((New-Blk 't2' 'file_grep'  @{ pattern = 'ZQPAR'; path = $dir }))
$list.Add((New-Blk 't3' 'file_list'  @{ path = $dir }))

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$res = $eng.ExecTools($list, [System.Threading.CancellationToken]::None)
$ms = $sw.ElapsedMilliseconds

# drena a fila p/ achar o status "N tools em paralelo"
$msgs = @(); $m = $null
while ($queue.TryDequeue([ref]$m)) { $msgs += [string]$m.Text; $m = $null }
$par = @($msgs | Where-Object { $_ -match 'em paralelo' })

$fail = @()
$i1 = $res.IndexOf('"tool_use_id":"t1"'); $i2 = $res.IndexOf('"tool_use_id":"t2"'); $i3 = $res.IndexOf('"tool_use_id":"t3"')
if ($i1 -lt 0 -or $i2 -lt 0 -or $i3 -lt 0) { $fail += "tool_results faltando (i1=$i1 i2=$i2 i3=$i3)" }
elseif (-not ($i1 -lt $i2 -and $i2 -lt $i3)) { $fail += "ordem quebrada: t1=$i1 t2=$i2 t3=$i3" }
if ($res -notmatch 'ZQPAR-ALFA') { $fail += 'file_read sem o conteudo do arquivo' }
if ($res -notmatch 'a\.txt') { $fail += 'file_grep sem resultado de a.txt' }
if ($res -notmatch 'b\.txt') { $fail += 'file_grep sem resultado de b.txt' }
if ($par.Count -eq 0) { $fail += 'status "tools em paralelo" nao emitido' }

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
if ($fail.Count) { $fail | ForEach-Object { "FAIL: $_" }; throw "test-parallel-engine: $($fail.Count) falha(s)" }
"PASS: parallel-engine — 3 tools em paralelo, resultados na ordem (t1<t2<t3), ${ms}ms"
