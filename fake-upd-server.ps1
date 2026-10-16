# fake-upd-server.ps1 - serve um "release" falso na 127.0.0.1 para o E2E do
# auto-update (v3.20). Rotas: GET /rel.json (feed no formato do GitHub) e
# GET /zquick.exe (o payload indicado, com o tamanho real no JSON).
# Uso: powershell -NoProfile -File fake-upd-server.ps1 -Port 8791 -ExePath <exe> -Tag v99.0.0
# ASCII-only (5.1/ANSI).
param([int]$Port = 8791, [string]$ExePath, [string]$Tag = 'v99.0.0')
$ErrorActionPreference = 'Stop'
if (-not $ExePath -or -not (Test-Path $ExePath)) { throw 'ExePath invalido' }
$bytes = [IO.File]::ReadAllBytes($ExePath)
$base = 'http://127.0.0.1:' + $Port
$json = ('{"tag_name":"' + $Tag + '","html_url":"' + $base + '/","name":"fake","body":"' +
         'Release falso para o teste do auto-update (E2E v3.20).",' +
         '"assets":[{"name":"zquick.exe","browser_download_url":"' + $base + '/zquick.exe","size":' +
         $bytes.Length + '}]}')
$jl = [Text.Encoding]::UTF8.GetBytes($json)
$listener = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $buf = New-Object byte[] 8192
            $n = $stream.Read($buf, 0, 8192)
            $req = [Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Max(0, $n))
            if ($req -match '^GET /(rel\.json|zquick\.exe) ') {
                $path = $Matches[1]
                if ($path -eq 'rel.json') { $body = $jl; $ct = 'application/json' }
                else { $body = $bytes; $ct = 'application/octet-stream' }
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: $ct`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length)
                $stream.Write($body, 0, $body.Length)
                $stream.Flush()
            } else {
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length)
            }
            Start-Sleep -Milliseconds 120   # da tempo do flush sair antes do Close
        } catch {} finally { try { $client.Close() } catch {} }
    }
} finally { try { $listener.Stop() } catch {} }
