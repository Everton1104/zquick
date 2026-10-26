# test-onda8-engine.ps1 — v3.26 (Onda 8) headless, sem GUI:
#   hooks: PreToolUse exit 2 (nega tool + motivo pro modelo), exit 0 (política —
#   pula o GateConfirm: file_write executa SEM confirmação), PostToolUse (async),
#   TurnEnd (async, fim do turno real);
#   fallback: fake server 500 p/ 'glm-a' → cadeia troca p/ 'glm-b' → SSE 200 →
#   turno responde em vez de morrer; modelo do ⚙ restaurado no fim.
# Rodar com: pwsh -NoProfile -File test-onda8-engine.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Get-Content (Join-Path $here 'zquick.ps1') -Raw
$m = [regex]::Match($src, "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'engine Cs nao extraido' }
Add-Type -TypeDefinition $m.Groups[1].Value

function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FALHOU: $msg" } }

# ---- sandbox ----
$box = Join-Path $env:TEMP 'zq-onda8'
if (Test-Path $box) { Remove-Item $box -Recurse -Force }
$null = New-Item -ItemType Directory -Path $box -Force

# ---- hooks scripts (rodam via cmd /c powershell -File; sem espaços no path) ----
$denyPs1  = Join-Path $box 'deny.ps1'
$allowPs1 = Join-Path $box 'allow.ps1'
$postPs1  = Join-Path $box 'post.ps1'
$endPs1   = Join-Path $box 'end.ps1'
@'
$i = [Console]::In.ReadToEnd()
Write-Output 'fora da janela de manutencao'
exit 2
'@ | Set-Content $denyPs1 -Encoding ASCII
@'
$i = [Console]::In.ReadToEnd()
exit 0
'@ | Set-Content $allowPs1 -Encoding ASCII
@'
$i = [Console]::In.ReadToEnd()
Add-Content -Path ($PSScriptRoot + '\postlog.txt') -Value $i
exit 0
'@ | Set-Content $postPs1 -Encoding ASCII
@'
$i = [Console]::In.ReadToEnd()
Add-Content -Path ($PSScriptRoot + '\endlog.txt') -Value ("turnend:" + (Get-Date -Format HH:mm:ss))
exit 0
'@ | Set-Content $endPs1 -Encoding ASCII

# ---- engine 1: hooks (sem rede — só ExecTools) ----
$q = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$e = [ZQuick.Engine]::new('http://localhost:1', 'x', 'glm-5.3', 'glm-5.3-flash', 'glm-5.3', 800, 'bing', $q, $false)
# caminhos dentro de JSON: barra invertida DOBRADA
$denyJ  = $denyPs1  -replace '\\', '\\'
$allowJ = $allowPs1 -replace '\\', '\\'
$postJ  = $postPs1  -replace '\\', '\\'
$e.HooksJson = '{"PreToolUse":[{"tool":"file_write","run":"powershell -NoProfile -ExecutionPolicy Bypass -File ' + $allowJ + '"},' +
               '{"tool":"file_move","run":"powershell -NoProfile -ExecutionPolicy Bypass -File ' + $denyJ + '"}],' +
               '"PostToolUse":[{"tool":"file_grep","run":"powershell -NoProfile -ExecutionPolicy Bypass -File ' + $postJ + '"}]}'

function Invoke-Tool([string]$tool, [string]$json) {
    $b = [ZQuick.Engine+Blk]::new()
    $b.Kind = 'tool_use'; $b.Name = $tool; $b.Id = 't' + ($script:tn++)
    [void]$b.Input.Append($json)
    $lst = [System.Collections.Generic.List[ZQuick.Engine+Blk]]::new()
    $lst.Add($b)
    $raw = $e.ExecTools($lst, [System.Threading.CancellationToken]::None)
    return ([string]($raw | ConvertFrom-Json).content)
}
function Drain-Queue {
    $out = @(); $msg = $null
    while ($q.TryDequeue([ref]$msg)) { $out += $msg; $msg = $null }
    return $out
}
$script:tn = 0

# ---- 1. PreToolUse exit 2: nega file_move, motivo devolvido, nada move ----
$srcFile = Join-Path $box 'origem.txt'
'dado original' | Set-Content $srcFile
$dstFile = Join-Path $box 'destino.txt'
$r = Invoke-Tool 'file_move' ('{"src":"' + ($srcFile -replace '\\', '\\') + '","dest":"' + ($dstFile -replace '\\', '\\') + '"}')
Assert ($r -match 'NEGADO pelo hook') "deny: resultado errado: $r"
Assert ($r -match 'fora da janela de manutencao') "deny: motivo do hook nao veio: $r"
Assert (Test-Path $srcFile) 'deny: origem sumiu'
Assert (-not (Test-Path $dstFile)) 'deny: destino existe (devia nao mover)'
"PASS 1: PreToolUse exit 2 nega a tool (motivo no tool_result, arquivo intacto)"

# ---- 2. PreToolUse exit 0: política — file_write EXECUTA sem GateConfirm ----
# (headless não tem UI p/ confirmar; se o bypass não funcionasse, o gate
# expiraria em 45s e negaria — arquivo criado = bypass provado)
$alvo = Join-Path $box 'alvo8.txt'
$t0 = Get-Date
$r = Invoke-Tool 'file_write' ('{"path":"' + ($alvo -replace '\\', '\\') + '","content":"ESCRITO PELO HOOK"}')
Assert ($r -notmatch 'NEGADO') "allow: foi negado: $r"
Assert (Test-Path $alvo) 'allow: arquivo nao foi escrito'
Assert ((Get-Content $alvo -Raw) -match 'ESCRITO PELO HOOK') 'allow: conteudo errado'
Assert (((Get-Date) - $t0).TotalSeconds -lt 40) 'allow: demorou demais (gate esperando?)'
$st = @(Drain-Queue) | Where-Object { $_.Type -eq 'status' -and $_.Text -match 'pass: hook aprovou' }
Assert ($st.Count -ge 1) 'allow: status "pass: hook aprovou" nao emitido'
"PASS 2: PreToolUse exit 0 = política — file_write sem confirmação (pass: logado)"

# ---- 3. PostToolUse (async): hook recebe tool_name + resultado ----
'linha com AGULHA-8' | Set-Content (Join-Path $box 'busca.txt')
$r = Invoke-Tool 'file_grep' ('{"pattern":"AGULHA-8","path":"' + ($box -replace '\\', '\\') + '"}')
Assert ($r -match 'busca\.txt') "grep: resultado errado: $r"
$postLog = Join-Path $box 'postlog.txt'
$hit = $null
for ($i = 0; $i -lt 20 -and -not $hit; $i++) {
    Start-Sleep -Milliseconds 300
    if (Test-Path $postLog) { $hit = Select-String -Path $postLog -Pattern 'tool_name' -Raw }
}
Assert ($hit -match 'file_grep') "posthook: log sem tool_name file_grep: $hit"
Assert ($hit -match 'tool_result') 'posthook: payload sem tool_result'
"PASS 3: PostToolUse dispara async com {tool_name, tool_result}"

# ---- 4. tool sem hook casando: fluxo normal ----
$r = Invoke-Tool 'file_read' ('{"path":"' + (($box + '\busca.txt') -replace '\\', '\\') + '"}')
Assert ($r -match 'AGULHA-8') "sem hook: file_read falhou: $r"
Assert ($r -notmatch 'NEGADO') "sem hook: negado sem hook: $r"
"PASS 4: tool sem hook no matcher roda normal (fail-open)"

# ---- 5. fallback: fake server 500 p/ glm-a, SSE 200 p/ glm-b ----
$fakeDir = Join-Path $box 'fake'
$null = New-Item -ItemType Directory -Path $fakeDir -Force
$fake = Start-Process pwsh -ArgumentList '-NoProfile','-File',(Join-Path $here 'fake-api.ps1'),'-Dir',$fakeDir,'-BadModel','glm-a','-Text','OK-FALLBACK' -WindowStyle Hidden -PassThru
try {
    $port = $null
    for ($i = 0; $i -lt 40 -and -not $port; $i++) {
        Start-Sleep -Milliseconds 250
        $pf = Join-Path $fakeDir 'port.txt'
        if (Test-Path $pf) { $port = [int](Get-Content $pf -Raw) }
    }
    Assert ($port) 'fake server nao publicou a porta'

    $q2 = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
    $e2 = [ZQuick.Engine]::new("http://localhost:$port", 'x', 'glm-a', 'glm-b', '', 800, 'bing', $q2, $false)
    $e2.HooksJson = '{"TurnEnd":[{"run":"powershell -NoProfile -ExecutionPolicy Bypass -File ' + ($endPs1 -replace '\\', '\\') + '"}]}'
    $null = Drain-Queue
    $t0 = Get-Date
    $e2.Ask('diga teste', $null, 'voce e um teste')
    $events = @(); $done = $false; $err = $false
    for ($i = 0; $i -lt 300 -and -not ($done -or $err); $i++) {
        Start-Sleep -Milliseconds 300
        $msg = $null
        while ($q2.TryDequeue([ref]$msg)) {
            $events += $msg
            if ($msg.Type -eq 'done') { $done = $true }
            if ($msg.Type -eq 'error') { $err = $true }
            $msg = $null
        }
    }
    $dump = ($events | ForEach-Object { $_.Type + ':' + $_.Text }) -join ' | '
    Assert ($done) "fallback: turno nao fechou (err=$err). eventos: $dump"
    Assert (-not $err) 'fallback: erro no fim do turno'
    $noteFb = $events | Where-Object { $_.Text -match 'fallback' }
    Assert ($noteFb.Count -ge 1) 'fallback: nota de fallback nao emitida'
    $stFb = $events | Where-Object { $_.Type -eq 'status' -and $_.Text -match 'tentando glm-b' }
    Assert ($stFb.Count -ge 1) 'fallback: status "tentando glm-b" nao emitido'
    $txt = ($events | Where-Object { $_.Type -eq 'delta' } | ForEach-Object { $_.Text }) -join ''
    Assert ($txt -match 'OK-FALLBACK') "fallback: resposta do modelo B nao chegou: $txt"
    Assert ($txt -match 'ok') "fallback: 2o delta ausente: $txt"
    "PASS 5: 500 no glm-a (4 tentativas c/ backoff) -> troca p/ glm-b -> turno responde"

    # modelo do ⚙ restaurado no fim do turno
    for ($i = 0; $i -lt 20 -and $e2.Busy; $i++) { Start-Sleep -Milliseconds 200 }
    Assert ($e2.CurModel -eq 'glm-a') "restore: CurModel=$($e2.CurModel) devia voltar a glm-a"
    "PASS 6: CurModel restaurado p/ glm-a (o do ⚙)"

    # ---- 6. TurnEnd (async): hook disparou no fim do turno ----
    $endLog = Join-Path $box 'endlog.txt'
    $hitEnd = $null
    for ($i = 0; $i -lt 20 -and -not $hitEnd; $i++) {
        Start-Sleep -Milliseconds 300
        if (Test-Path $endLog) { $hitEnd = Select-String -Path $endLog -Pattern 'turnend:' -Raw }
    }
    Assert ($null -ne $hitEnd -and "$hitEnd" -ne '') 'TurnEnd: hook nao rodou'
    "PASS 7: TurnEnd dispara no fim do turno"

    $dur = [int]((Get-Date) - $t0).TotalSeconds
    "(fallback completo em ${dur}s — 3 backoffs 1+3+8s inclusos)"
} finally {
    if ($fake -and -not $fake.HasExited) { Stop-Process -Id $fake.Id -Force }
    Start-Sleep -Milliseconds 400
    Remove-Item $box -Recurse -Force -ErrorAction SilentlyContinue
}
"VERDICTO: OK (hooks pre-deny/pre-allow/post/turnend + fallback de modelo)"
