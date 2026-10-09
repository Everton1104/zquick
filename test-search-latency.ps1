# test-search-latency.ps1 — mede a latencia BRUTA das fontes de busca (sem LLM)
$q = [uri]::EscapeDataString('cotacao do dolar hoje')
function Timed($name, $url) {
    1..3 | ForEach-Object {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
            $req.Timeout = 15000
            $resp = $req.GetResponse()
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            $len = $sr.ReadToEnd().Length
            $resp.Close()
            "{0}  tentativa {1}: {2:0.00}s  ({3} bytes)" -f $name, $_, $sw.Elapsed.TotalSeconds, $len
        } catch { "{0}  tentativa {1}: ERRO {2}" -f $name, $_, $_.Exception.Message }
    }
}
Timed 'Bing RSS ' "https://www.bing.com/search?q=$q&format=rss&setlang=pt&count=12"
Timed 'Bing HTML' "https://www.bing.com/search?q=$q&setlang=pt&count=12"
Timed 'Z.ai ping' 'https://api.z.ai/'
