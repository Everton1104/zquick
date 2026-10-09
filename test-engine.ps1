# Teste headless do engine ZQuick (sem GUI): valida streaming + web_search + Bing scrape.
$ErrorActionPreference = 'Stop'
$src = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1' -Raw
$m = [regex]::Match($src, "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'engine Cs nao extraido' }
Add-Type -TypeDefinition $m.Groups[1].Value

$sj = Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw | ConvertFrom-Json
$base = $sj.env.ANTHROPIC_BASE_URL
$key = $sj.env.ANTHROPIC_AUTH_TOKEN

$q = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$e = [ZQuick.Engine]::new($base, $key, 'glm-5.3-flash', 'glm-5.3-flash', 'glm-5.3', 800, 'bing', $q)

$sw = [Diagnostics.Stopwatch]::StartNew()
$e.Ask('Qual a cotacao do dolar comercial hoje? Busque na web e responda em 2 frases citando fonte.', $null,
       'Hoje e 09/10/2026. Assistente de teste. Responda conciso em portugues, cite fontes como [n].')

$txt = ''
$done = $false
while (-not $done -and $sw.Elapsed.TotalSeconds -lt 120) {
    Start-Sleep -Milliseconds 150
    $msg = $null
    while ($q.TryDequeue([ref]$msg)) {
        switch ($msg.Type) {
            'delta'   { $txt += $msg.Text }
            'status'  { Write-Host "[$([int]$sw.Elapsed.TotalSeconds)s] STATUS: $($msg.Text)" -ForegroundColor Cyan }
            'sources' { Write-Host "[$([int]$sw.Elapsed.TotalSeconds)s] SOURCES: $($msg.Text)" -ForegroundColor DarkCyan }
            'error'   { Write-Host "ERRO: $($msg.Text)" -ForegroundColor Red; $done = $true }
            'done'    { $done = $true }
        }
        $msg = $null
    }
}
Write-Host "`n=== RESPOSTA (${([int]$sw.Elapsed.TotalSeconds)}s) ===" -ForegroundColor Green
Write-Host $txt
