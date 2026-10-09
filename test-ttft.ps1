# test-ttft.ps1 — mede onde o tempo vai: TTFT (1o token) vs total, frio vs quente.
$ErrorActionPreference = 'Stop'
$src = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1' -Raw
$m = [regex]::Match($src, "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'engine Cs nao extraido' }
Add-Type -TypeDefinition $m.Groups[1].Value
$sj = Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw | ConvertFrom-Json

$q = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$e = [ZQuick.Engine]::new($sj.env.ANTHROPIC_BASE_URL, $sj.env.ANTHROPIC_AUTH_TOKEN,
     'auto', 'glm-5.3-flash', 'glm-5.3', 300, 'bing', $q)

function Ask-Measure([string]$label, [string]$text) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ttft = -1.0; $txt = ''; $done = $false
    $e.Ask($text, $null, 'Responda de forma extremamente curta.')
    while (-not $done -and $sw.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 30
        $msg = $null
        while ($q.TryDequeue([ref]$msg)) {
            switch ($msg.Type) {
                'delta' { if ($ttft -lt 0) { $ttft = $sw.Elapsed.TotalSeconds }; $txt += $msg.Text }
                'error' { $txt += " [ERRO: $($msg.Text)]"; $done = $true }
                'done'  { $done = $true }
            }
            $msg = $null
        }
    }
    "{0,-10} TTFT {1,5:N2}s | total {2,5:N2}s | {3}" -f $label, $ttft, $sw.Elapsed.TotalSeconds, ($txt -replace '\s+',' ').Trim()
}

Ask-Measure 'frio'    'quanto e 2+2? responda so o numero'
Ask-Measure 'quente1' 'quanto e 3+3? responda so o numero'
Ask-Measure 'quente2' 'quanto e 4+4? responda so o numero'
