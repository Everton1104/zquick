# fake-api.ps1 — servidor HTTP falso para o teste de fallback (Onda 8).
# Responde 500 quando o request pede $BadModel, e um SSE com $Text para
# qualquer outro. Roda como processo separado (pwsh -File) e publica a
# porta em $Dir\port.txt. Atende até 20 requests e sai.
# v3.26.1: -Balance => TODO POST responde 429 + code 1113 (saldo Z.ai).
# v3.26.2: -Models "a,b,c" => GET responde a lista /v1/models (etapa 1 do
#          wizard); -NoBalance "a,b" => só esses modelos respondem 429/1113.
param([string]$Dir, [string]$BadModel, [string]$Text, [switch]$Balance, [string]$Models, [string]$NoBalance)
$ErrorActionPreference = 'Stop'
$tl = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$tl.Start()
[IO.File]::WriteAllText((Join-Path $Dir 'port.txt'), "$(([Net.IPEndPoint]$tl.LocalEndpoint).Port)")
$nbList = @($NoBalance -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
for ($ri = 0; $ri -lt 20; $ri++) {
    $c = $tl.AcceptTcpClient()
    try {
        Add-Content -Path (Join-Path $Dir 'req.log') -Value ("acc#{0} {1:HH:mm:ss.fff}" -f $ri, (Get-Date))
        $s = $c.GetStream()
        $req = ''
        $buf = New-Object byte[] 65536
        $total = 0
        while ($true) {
            $n = $s.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
            $req += [Text.Encoding]::UTF8.GetString($buf, 0, $n)
            $headEnd = $req.IndexOf("`r`n`r`n")
            # Content-Length conta BYTES — comparar $req.Length (chars) nunca fecha
            # quando o body tem acento/emoji (UTF-8 = 2+ bytes por char). Headers são
            # ASCII, então headEnd em chars == bytes. GET sem Content-Length: headers
            # completos já fecha o read (cliente espera resposta — não vai fechar).
            $bodyLen = if ($req -match 'Content-Length:\s*(\d+)') { [int]$Matches[1] } else { -1 }
            if ($headEnd -ge 0 -and $bodyLen -lt 0) { break }
            if ($headEnd -ge 0 -and $bodyLen -ge 0 -and $total -ge $headEnd + 4 + $bodyLen) { break }
        }
        if (-not $req.StartsWith('POST')) {
            if ($Models -and $req.StartsWith('GET')) {
                $ids = @($Models -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $json = '{"data":[' + (($ids | ForEach-Object { '{"id":"' + $_ + '"}' }) -join ',') + ']}'
                $pl = [Text.Encoding]::UTF8.GetBytes($json)
                $hdr = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nConnection: close`r`nContent-Length: $($pl.Length)`r`n`r`n"
                $hb = [Text.Encoding]::UTF8.GetBytes($hdr)
                $s.Write($hb, 0, $hb.Length); $s.Write($pl, 0, $pl.Length)
                Add-Content -Path (Join-Path $Dir 'req.log') -Value ("models#{0} {1} ids" -f $ri, $ids.Count)
            } else {
                Add-Content -Path (Join-Path $Dir 'req.log') -Value ("skip#{0} não-POST (prewarm GET)" -f $ri)
            }
        } else {
        $isNb = $nbList.Count -gt 0 -and ($req -match ('"model"\s*:\s*"(' + (($nbList | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')"'))
        if ($Balance -or $isNb) {
            $json = '{"type":"error","error":{"type":"rate_limit_error","code":"1113","message":"[1113][Insufficient balance or no resource package. Please recharge.][fake]","request_id":"fake"}}'
            $pl = [Text.Encoding]::UTF8.GetBytes($json)
            $hdr = "HTTP/1.1 429 Too Many Requests`r`nContent-Type: application/json`r`nConnection: close`r`nContent-Length: $($pl.Length)`r`n`r`n"
            $hb = [Text.Encoding]::UTF8.GetBytes($hdr)
            $s.Write($hb, 0, $hb.Length); $s.Write($pl, 0, $pl.Length)
            Add-Content -Path (Join-Path $Dir 'req.log') -Value ("req#{0} {1:HH:mm:ss.fff} BALANCE-429" -f $ri, (Get-Date))
        } else {
        $isBad = $req -match ('"model"\s*:\s*"' + [regex]::Escape($BadModel) + '"')
        Add-Content -Path (Join-Path $Dir 'req.log') -Value ("req#{0} {1:HH:mm:ss.fff} len={2} bad={3}" -f $ri, (Get-Date), $req.Length, $isBad)
        if ($isBad) {
            $b = [Text.Encoding]::UTF8.GetBytes("HTTP/1.1 500 Internal Server Error`r`nContent-Length: 5`r`n`r`nfalse")
            $s.Write($b, 0, $b.Length)
        } else {
            $sse = "data: {""type"":""content_block_start"",""index"":0,""content_block"":{""type"":""text"",""text"":""""}}`r`n`r`n" +
                   "data: {""type"":""content_block_delta"",""index"":0,""delta"":{""type"":""text_delta"",""text"":""$Text""}}`r`n`r`n" +
                   "data: {""type"":""content_block_delta"",""index"":0,""delta"":{""type"":""text_delta"",""text"":"" ok""}}`r`n`r`n" +
                   "data: {""type"":""message_delta"",""delta"":{""stop_reason"":""end_turn""}}`r`n`r`n" +
                   "data: {""type"":""message_stop""}`r`n`r`n"
            $bb = [Text.Encoding]::UTF8.GetBytes($sse)
            $head = "HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nConnection: close`r`nContent-Length: $($bb.Length)`r`n`r`n"
            $hb = [Text.Encoding]::UTF8.GetBytes($head)
            $s.Write($hb, 0, $hb.Length)
            $s.Write($bb, 0, $bb.Length)
        }
        $s.Flush()
        }
        }
    } catch { Add-Content -Path (Join-Path $Dir 'req.log') -Value ("err#{0} {1}" -f $ri, $_.Exception.Message) } finally { $c.Close() }
}
$tl.Stop()
