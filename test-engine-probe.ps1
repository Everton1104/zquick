# test-engine-probe.ps1 — sonda HEADLESS do Engine C# (sem UI, sem drain, sem log):
# extrai $engineCss de zquick.ps1, instancia com a config viva (zai-server) e
# imprime CADA UiMsg na ordem de emissao. Decide se o bug e' engine ou UI.
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText('C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1')
if ($src -notmatch "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@") { throw 'engineCs nao extraido' }
$engineCs = $Matches[1]
Add-Type -TypeDefinition $engineCs

# config viva (mesma fonte do app)
$jq = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json' -Raw | ConvertFrom-Json
$sj = Get-Content (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw | ConvertFrom-Json
$base = [string]$sj.env.ANTHROPIC_BASE_URL; if (-not $base) { $base = 'https://api.z.ai/api/anthropic' }
$key  = [string]$sj.env.ANTHROPIC_AUTH_TOKEN
$p = $jq.profiles.($jq.profile)

$queue = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$eng = [ZQuick.Engine]::new($base, $key, 'auto', [string]$p.fastModel, [string]$p.bigModel,
    [int]$jq.maxTokens, [string]$jq.searchEngine, $queue, [bool]$jq.promptCache)
$eng.SetVisionModel([string]$p.visionModel)
$eng.PsExe = 'pwsh.exe'

"== engine: search=$($jq.searchEngine) cache=$($jq.promptCache) — Ask() =="
$eng.Ask('cotação do dólar hoje? resposta curta com o valor', $null, $null, $null, 'Você é o ZQuick. Responda curto.')
$deadline = (Get-Date).AddSeconds(150)
$stats = @{}
while ((Get-Date) -lt $deadline) {
    $m = $null
    $drained = $false
    while ($queue.TryDequeue([ref]$m)) {
        $drained = $true
        $t = [string]$m.Type
        if (-not $stats.ContainsKey($t)) { $stats[$t] = 0 }
        $stats[$t]++
        $txt = [string]$m.Text
        $one = $txt -replace "\s+", ' '
        if ($one.Length -gt 110) { $one = $one.Substring(0, 110) + '…' }
        "[$t] $one"
        if ($t -eq 'done' -or $t -eq 'error') { $deadline = (Get-Date).AddSeconds(-1) }
    }
    if (-not $drained) { Start-Sleep -Milliseconds 150 }
}
""
"== contagem por tipo =="
$stats.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0,-10} x{1}' -f $_.Key, $_.Value }
""
"== historico final (blocos da resposta) =="
foreach ($h in @($eng.GetHistory())) {
    foreach ($b in @((($h | ConvertFrom-Json)).content)) {
        $bj = $b | ConvertTo-Json -Compress -Depth 6
        if ($bj.Length -gt 160) { $bj = $bj.Substring(0, 160) + '…' }
        "  $bj"
    }
}
