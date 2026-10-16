# test-editmiss.ps1 - unitario do EditMissHint (v3.11): old_str com mojibake de
# emoji/acento (copiado do output do run_ps) NAO casa no arquivo UTF-8 real; a
# dica tem que devolver a linha REAL com numero. Reproduz o caso 16/10 (v3.9: ?? janela).
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'zquick.ps1'))
$m = [regex]::Match($src, "(?s)\$engineCs = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'engineCs nao extraido' }
Add-Type -TypeDefinition $m.Groups[1].Value -ReferencedAssemblies @('System.dll','System.Core.dll','Microsoft.CSharp.dll','System.Net.Http.dll')
$mi = [ZQuick.Engine].GetMethod('EditMissHint', [System.Reflection.BindingFlags]'Static,NonPublic')
if (-not $mi) { throw 'EditMissHint nao achado' }

# cenario 1: o caso real - linha com emoji (nao-ASCII) do zquick.ps1 vs old_str com '?' no lugar
$real    = "    alwaysOnTop   = `$false    # v3.9: " + [char]0x25A2 + " janela sobre as outras"
$mojibke = '    alwaysOnTop   = $false    # v3.9: ?? janela sobre as outras'   # o que o modelo viu no run_ps
$t = "linha 1 qualquer`n" + $real + "`nlinha 3 qualquer`n"
$r1 = $mi.Invoke($null, @($t, $mojibke))
"--- cenario 1 (mojibake) ---"
$r1
if ($r1 -notmatch 'ERRO') { throw 'cenario 1: devia comecar com ERRO' }
if ($r1 -notmatch '2: .*alwaysOnTop') { throw 'cenario 1: dica nao apontou a linha 2 real' }
if ($r1 -notmatch [char]0x25A2) { throw 'cenario 1: dica nao devolveu o trecho REAL (com o emoji)' }
'cenario 1 OK'

# cenario 2: old_str realmente inexistente -> dica generica, sem linhas falsas
$r2 = $mi.Invoke($null, @($t, 'esse trecho nao existe no arquivo mesmo'))
"--- cenario 2 (inexistente) ---"
$r2
if ($r2 -notmatch 'file_read|file_grep') { throw 'cenario 2: sem a orientacao generica' }
if ($r2 -match '^\d+:') { throw 'cenario 2: apontou linha sem casar nada' }
'cenario 2 OK'

# cenario 3: old_str curto demais (<10 normalizado) -> sem fuzzy
$r3 = $mi.Invoke($null, @($t, 'zz'))
if ($r3 -match 'Linha\(s\) equivalente') { throw 'cenario 3: fuzzy rodou com probe curto' }
'cenario 3 OK'
'VERDICTO: OK'
