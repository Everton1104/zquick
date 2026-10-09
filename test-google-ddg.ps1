# test-google-ddg.ps1 — Google gbv=1 e DDG Instant Answer: acessivel? parseavel? rapido?
$q = 'cotacao do dolar hoje'
function Get-Timed($name, $url, $ua) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = $ua
        $req.Accept = 'text/html,application/xhtml+xml'
        $req.Headers.Add('Accept-Language', 'pt-BR,pt;q=0.9')
        $req.Timeout = 15000
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $html = $sr.ReadToEnd()
        $resp.Close()
        $len = $html.Length
        $marker = @()
        if ($html -match 'href="/url\?q=' -or $html -match '<a href="http(?!.*google)') { $marker += 'links-de-resultado' }
        if ($html -match 'detalhes') { }
        $googleLinks = ([regex]::Matches($html, '/url\?q=(http[^&"]+)')).Count
        $plainLinks = ([regex]::Matches($html, '<a[^>]+href="(https?://(?!www\.google|accounts\.google|support\.google|policies\.google)[^"]+)"')).Count
        $captcha = $html -match 'captcha|unusual traffic|CAPTCHA'
        $consent = $html -match 'consent\.google|Before you continue'
        "{0}: {1:0.00}s | {2} bytes | links /url?q=: {3} | links diretos: {4} | captcha: {5} | consent: {6}" -f $name, $sw.Elapsed.TotalSeconds, $len, $googleLinks, $plainLinks, $captcha, $consent
        # salva p/ inspecao
        $f = Join-Path $env:TEMP ("src-" + $name.Replace(' ', '') + ".html")
        [IO.File]::WriteAllText($f, $html)
        "  salvo: $f"
    } catch { "{0}: ERRO {1} ({2:0.00}s)" -f $name, $_.Exception.Message, $sw.Elapsed.TotalSeconds }
}
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$eq = [uri]::EscapeDataString($q)
Get-Timed 'Google gbv=1 ' "https://www.google.com/search?q=$eq&gbv=1&hl=pt-BR&num=10" $ua
Get-Timed 'Google normal' "https://www.google.com/search?q=$eq&hl=pt-BR&num=10" $ua
Get-Timed 'DDG api      ' "https://api.duckduckgo.com/?q=$eq&format=json&no_html=1&skip_disambig=1" $ua
# DDG api: mostra o abstract (resposta pronta)
try {
    $ddg = Invoke-RestMethod "https://api.duckduckgo.com/?q=$eq&format=json&no_html=1&skip_disambig=1" -TimeoutSec 15
    "DDG AbstractText: '$($ddg.AbstractText)' | AbstractURL: $($ddg.AbstractURL)"
    "DDG Heading: $($ddg.Heading) | RelatedTopics: $(@($ddg.RelatedTopics).Count)"
} catch { "DDG api parse: ERRO $_" }
