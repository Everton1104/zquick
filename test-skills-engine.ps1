# test-skills-engine.ps1 — headless: skills (Onda 5). Sem API — valida o caminho local:
# SetSkills liga a tool skill_read no BuildBody; LocalTool devolve o corpo do .md;
# nome desconhecido lista as disponíveis. pwsh -NoProfile -File test-skills-engine.ps1
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText("$PSScriptRoot\zquick.ps1")
if ($src -notmatch "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@") { throw 'engineCs nao extraido' }
Add-Type -TypeDefinition $Matches[1]

$queue = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$eng = [ZQuick.Engine]::new('https://api.z.ai/api/anthropic', 'x', 'glm-5.3-flash', $null, $null, 64, 'bing', $queue, $false)

# fixture: 2 skills num temp dir
$dir = Join-Path $env:TEMP ('zqskill-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $dir | Out-Null
$f1 = Join-Path $dir 'alfa.md'; Set-Content $f1 "ZQ5-SKILL-ALFA corpo da skill alfa"
$f2 = Join-Path $dir 'beta.md'; Set-Content $f2 "corpo beta"
$cfg = ConvertTo-Json -InputObject @(
    @{ name = 'alfa'; file = $f1 }, @{ name = 'beta'; file = $f2 }) -Compress

function New-Blk([string]$id, [string]$name, [object]$inputObj) {
    $b = [ZQuick.Engine+Blk]::new()
    $b.Kind = 'tool_use'; $b.Id = $id; $b.Name = $name
    [void]$b.Input.Append(($inputObj | ConvertTo-Json -Compress))
    $b
}

$fail = @()
# research entra sempre; skill_read so' depois de SetSkills
if (-not $eng.ToolDeclared('research')) { $fail += 'tool research nao declarada no BuildBody' }
if ($eng.ToolDeclared('skill_read')) { $fail += 'skill_read declarada SEM skills configuradas' }
$eng.SetSkills($cfg)
if ($eng.SkillCount() -ne 2) { $fail += "SkillCount esperava 2, veio $($eng.SkillCount())" }
if (-not $eng.ToolDeclared('skill_read')) { $fail += 'skill_read nao declarada apos SetSkills' }

# skill_read via ExecTools (caminho real que o modelo usa)
$list = [System.Collections.Generic.List[ZQuick.Engine+Blk]]::new()
$list.Add((New-Blk 't1' 'skill_read' @{ name = 'alfa' }))
$res = $eng.ExecTools($list, [System.Threading.CancellationToken]::None)
if ($res -notmatch 'ZQ5-SKILL-ALFA') { $fail += "skill_read nao devolveu o corpo: $res" }
if ($res -notmatch 'alfa\.md') { $fail += "skill_read sem o caminho do arquivo: $res" }

# nome desconhecido -> erro com a lista
$list2 = [System.Collections.Generic.List[ZQuick.Engine+Blk]]::new()
$list2.Add((New-Blk 't2' 'skill_read' @{ name = 'nadinha' }))
$res2 = $eng.ExecTools($list2, [System.Threading.CancellationToken]::None)
if ($res2 -notmatch 'skill desconhecida' -or $res2 -notmatch 'alfa' -or $res2 -notmatch 'beta') { $fail += "nome desconhecido nao listou as skills: $res2" }

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
if ($fail.Count) { $fail | ForEach-Object { "FAIL: $_" }; throw "test-skills-engine: $($fail.Count) falha(s)" }
'PASS: skills-engine — SetSkills/skill_read/BuildBody/listagem de desconhecidas'
