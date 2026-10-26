# test-onda7-engine.ps1 — v3.25 (Onda 7) headless, sem GUI e sem LLM:
# file_grep turbinado (context/modes/max), git_status/diff/log (repo temp real),
# ResolveGitRepo via _shCwd, todo_write (evento 'todo' na fila + clear).
# git_commit NAO roda aqui (GateConfirm precisa de UI) — E2E cobre depois.
# Rodar com: pwsh -NoProfile -File test-onda7-engine.ps1
$ErrorActionPreference = 'Stop'
$src = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1' -Raw
$m = [regex]::Match($src, "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'engine Cs nao extraido' }
Add-Type -TypeDefinition $m.Groups[1].Value

function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FALHOU: $msg" } }

# ---- repo git temp (hermetico: 2 arquivos, 1 commit) ----
$repo = Join-Path $env:TEMP 'zq-onda7\repo'
if (Test-Path (Split-Path -Parent $repo)) { Remove-Item (Split-Path -Parent $repo) -Recurse -Force }
$null = New-Item -ItemType Directory -Path $repo -Force
git -C $repo init -q 2>$null
if ($LASTEXITCODE -ne 0) { throw 'git nao disponivel (PATH?)' }
git -C $repo config user.email 'zq@test.local'
git -C $repo config user.name 'ZQuick Test'
@('alpha needle one', 'beta', 'gamma two', 'delta', 'epsilon', 'zeta needle three') | Set-Content (Join-Path $repo 'a.txt')
@('Get-Needle', 'other-line') | Set-Content (Join-Path $repo 'src.ps1')
git -C $repo add -A
git -C $repo commit -q -m 'base'
"repo temp: $repo (commit base)"

# ---- engine + fila ----
$q = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$e = [ZQuick.Engine]::new('http://localhost:1', 'x', 'glm-5.3-flash', 'glm-5.3-flash', 'glm-5.3', 800, 'bing', $q, $false)
$rp = $repo -replace '\\', '\\\\'   # p/ embutir em JSON

function Invoke-Tool([string]$tool, [string]$json) {
    $b = [ZQuick.Engine+Blk]::new()
    $b.Kind = 'tool_use'; $b.Name = $tool; $b.Id = 't' + ($script:tn++)
    [void]$b.Input.Append($json)
    $lst = [System.Collections.Generic.List[ZQuick.Engine+Blk]]::new()
    $lst.Add($b)
    $raw = $e.ExecTools($lst, [System.Threading.CancellationToken]::None)
    # ExecTools devolve o envelope tool_result — o conteudo util vem no 'content'
    return ([string]($raw | ConvertFrom-Json).content)
}
function Drain-Queue {
    $out = @()
    $msg = $null
    while ($q.TryDequeue([ref]$msg)) { $out += $msg; $msg = $null }
    return $out
}
$script:tn = 0

# ---- 1. file_grep padrao (regressao: file:line: text) ----
$r = Invoke-Tool 'file_grep' ('{"pattern":"needle","path":"' + $rp + '"}')
Assert ($r -match 'a\.txt:1: ') "grep padrao: linha 1 de a.txt nao veio: $r"
Assert ($r -match 'a\.txt:6: ') "grep padrao: linha 6 de a.txt nao veio: $r"
"PASS 1: file_grep content (file:line: text)"

# ---- 2. context=1: vizinhas com '- ', grupos separados por '--', lacuna fora ----
$r = Invoke-Tool 'file_grep' ('{"pattern":"needle","path":"' + $rp + '","context":1}')
Assert ($r -match 'a\.txt:2- beta') "context: linha vizinha 2 sem sufixo '- ': $r"
Assert ($r -match 'a\.txt:1: alpha needle one') "context: match nao marcado com ': ': $r"
Assert ($r -match "--") "context: sem separador '--' entre grupos distantes: $r"
Assert ($r -match 'a\.txt:5- epsilon') "context: vizinha de cima do 2o grupo nao veio: $r"
Assert ($r -notmatch 'a\.txt:4') "context: linha de lacuna (4) impressa sem ser contexto: $r"
"PASS 2: file_grep context=1 (vizinhas + separador + lacuna fora)"

# ---- 3. mode=files: so caminhos ----
$r = Invoke-Tool 'file_grep' ('{"pattern":"needle","path":"' + $rp + '","mode":"files"}')
Assert ($r -match 'arquivo\(s\) com ocorr') "files: header errado: $r"
Assert ($r -match 'a\.txt') "files: a.txt ausente: $r"
Assert ($r -match 'src\.ps1') "files: src.ps1 ausente: $r"
Assert ($r -notmatch 'a\.txt:\d') "files: veio linha numerada (devia ser so path): $r"
"PASS 3: file_grep mode=files"

# ---- 4. mode=count: N TAB file, desc ----
$r = Invoke-Tool 'file_grep' ('{"pattern":"needle","path":"' + $rp + '","mode":"count"}')
Assert ($r -match '2\t') "count: a.txt devia ter 2: $r"
Assert ($r -match '1\t') "count: src.ps1 devia ter 1: $r"
Assert ($r.IndexOf("2`t") -lt $r.IndexOf("1`t")) "count: ordem nao e desc: $r"
"PASS 4: file_grep mode=count (desc)"

# ---- working tree suja (APOS os greps) ----
Set-Content (Join-Path $repo 'a.txt') 'CHANGED needle one'

# ---- 5. git_status (repo explicito) ----
$r = Invoke-Tool 'git_status' ('{"repo":"' + $rp + '"}')
Assert ($r.StartsWith('EXIT 0')) "git_status: exit nao 0: $r"
Assert ($r -match '## ') "git_status: sem branch: $r"
Assert ($r -match 'M a\.txt') "git_status: modificacao de a.txt nao apareceu: $r"
"PASS 5: git_status (branch + M a.txt)"

# ---- 6. git_diff (working tree suja) ----
$r = Invoke-Tool 'git_diff' ('{"repo":"' + $rp + '"}')
Assert ($r.StartsWith('EXIT 0')) "git_diff: exit nao 0: $r"
Assert ($r -match '\-alpha needle one') "git_diff: linha antiga ausente: $r"
Assert ($r -match '\+CHANGED needle one') "git_diff: linha nova ausente: $r"
"PASS 6: git_diff (-alpha/+CHANGED)"

# ---- 7. git_log ----
$r = Invoke-Tool 'git_log' ('{"repo":"' + $rp + '","n":5}')
Assert ($r.StartsWith('EXIT 0')) "git_log: exit nao 0: $r"
Assert ($r -match ' base \(ZQuick Test\)') "git_log: commit 'base (autor)' ausente: $r"
"PASS 7: git_log (commit base listado)"

# ---- 8. repo invalido + default via _shCwd ----
$r = Invoke-Tool 'git_status' '{"repo":"C:\\Windows"}'
Assert ($r -match 'ERRO') "git_status sem repo: devia dar ERRO: $r"
$e._shCwd = $repo
$r = Invoke-Tool 'git_status' '{}'
Assert ($r.StartsWith('EXIT 0')) "git_status via _shCwd: nao resolveu: $r"
"PASS 8: repo invalido -> ERRO; _shCwd -> resolve"

# ---- 9. todo_write: evento 'todo' + status; status invalido vira pending ----
$null = Drain-Queue
$r = Invoke-Tool 'todo_write' '{"todos":[{"content":"passo 1","status":"completed"},{"content":"passo 2","status":"in_progress"},{"content":"passo 3","status":"xinvalido"}]}'
Assert ($r -match '3 itens, 1 conclu') "todo_write: retorno errado: $r"
$msgs = @(Drain-Queue)
$todo = $msgs | Where-Object { $_.Type -eq 'todo' } | Select-Object -First 1
Assert ($null -ne $todo) 'todo_write: nenhum evento todo na fila'
$tj = @($todo.Text | ConvertFrom-Json)
Assert ($tj.Count -eq 3) "todo_write: esperava 3 itens, veio $($todo.Text)"
Assert ($tj[0].status -eq 'completed' -and $tj[1].status -eq 'in_progress') "todo_write: status errado: $($todo.Text)"
Assert ($tj[2].status -eq 'pending') "todo_write: 'xinvalido' nao virou pending: $($todo.Text)"
$st = $msgs | Where-Object { $_.Type -eq 'status' -and $_.Text -match 'checklist' } | Select-Object -First 1
Assert ($st -and $st.Text -match '1/3') "todo_write: status do checklist errado: $($st.Text)"
"PASS 9: todo_write (evento todo, coercao de status, status 1/3)"

# ---- 10. todo_write clear ----
$r = Invoke-Tool 'todo_write' '{"todos":[]}'
Assert ($r -match 'LIMPO') "todo_write clear: retorno errado: $r"
$todo2 = @(Drain-Queue) | Where-Object { $_.Type -eq 'todo' } | Select-Object -First 1
Assert ($todo2 -and $todo2.Text -match 'clear') "todo_write clear: evento errado: $($todo2.Text)"
"PASS 10: todo_write clear (painel fecha)"

# ---- limpeza ----
Remove-Item (Split-Path -Parent $repo) -Recurse -Force
"VERDICTO: OK (grep 4 modos + git status/diff/log + _shCwd + todo_write)"
