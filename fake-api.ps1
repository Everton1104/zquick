# fake-api.ps1 — servidor HTTP falso para o teste de fallback (Onda 8).
# Responde 500 quando o request pede $BadModel, e um SSE com $Text para
# qualquer outro. Roda como processo separado (pwsh -File) e publica a
# porta em $Dir\port.txt. Atende até 20 requests e sai.
param([string]$Dir, [string]$BadModel, [string]$Text)
$ErrorActionPreference = 'Stop'
$tl = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$tl.Start()
[IO.File]::WriteAllText((Join-Path $Dir 'port.txt'), "$(([Net.IPEndPoint]$tl.LocalEndpoint).Port)")
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
            $bodyLen = if ($req -match 'Content-Length:\s*(\d+)') { [int]$Matches[1] } else { -1 }
            # Content-Length conta BYTES — comparar $req.Length (chars) nunca fecha
            # quando o body tem acento/emoji (UTF-8 = 2+ bytes por char). Headers são
            # ASCII, então headEnd em chars == bytes.
            if ($headEnd -ge 0 -and $bodyLen -ge 0 -and $total -ge $headEnd + 4 + $bodyLen) { break }
        }
        if (-not $req.StartsWith('POST')) { Add-Content -Path (Join-Path $Dir 'req.log') -Value ("skip#{0} não-POST (prewarm GET)" -f $ri) } else {
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
            $head = "HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nContent-Length: $($bb.Length)`r`n`r`n"
            $hb = [Text.Encoding]::UTF8.GetBytes($head)
            $s.Write($hb, 0, $hb.Length)
            $s.Write($bb, 0, $bb.Length)
        }
        $s.Flush()
        }
    } catch { Add-Content -Path (Join-Path $Dir 'req.log') -Value ("err#{0} {1}" -f $ri, $_.Exception.Message) } finally { $c.Close() }
}
$tl.Stop()
