# valida a costura do JSON da pre-busca em isolamento
$last = '{"role":"user","content":[{"type":"text","text":"qual a versao mais recente do python"}]}'
$inj = "[O SISTEMA JA FEZ A BUSCA] linha1`nlinha2 com `"aspas`" e ]} no meio"
$ej = $inj -replace '"', '\"' -replace "`r?`n", '\n'
$p2 = $last.LastIndexOf(']}')
$block = ',{"type":"text","text":"' + $ej + '"}]}'
$fixed = $last.Substring(0, $p2) + $block
try {
    $o = $fixed | ConvertFrom-Json
    "costura JSON valida"
    "blocos no content: $(@($o.content).Count)"
    "2o bloco comeca: " + $o.content[1].text.Substring(0, 40)
} catch { "COSTURA INVALIDA: $_" }
