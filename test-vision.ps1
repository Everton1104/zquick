# Teste headless do fluxo de IMAGEM do engine ZQuick (valida Ctrl+V -> base64 -> Z.ai -> interpretacao).
$ErrorActionPreference = 'Stop'
$src = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1' -Raw
$m = [regex]::Match($src, "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'engine Cs nao extraido' }
Add-Type -TypeDefinition $m.Groups[1].Value

$sj = Get-Content "$env:USERPROFILE\.claude\settings.json" -Raw | ConvertFrom-Json

# gera imagem-teste com texto reconhecivel
Add-Type -AssemblyName System.Drawing
$bmp = [System.Drawing.Bitmap]::new(420, 120)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$g.SmoothingMode = 'AntiAlias'
$font = [System.Drawing.Font]::new('Arial', 30, [System.Drawing.FontStyle]::Bold)
$brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(20, 90, 200))
$g.DrawString('ZQUICK-77-OK', $font, $brush, [single]15, [single]38)
$g.Dispose()
$ms = [System.IO.MemoryStream]::new()
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$b64 = [Convert]::ToBase64String($ms.ToArray())
"imagem de teste gerada ($($b64.Length) chars de base64)"

$q = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()
$e = [ZQuick.Engine]::new($sj.env.ANTHROPIC_BASE_URL, $sj.env.ANTHROPIC_AUTH_TOKEN, 'glm-5.3-flash', 'glm-5.3-flash', 'glm-5.3', 300, 'bing', $q)

# validacao do caminho RSS da busca tambem (cadeia nova)
$sw = [Diagnostics.Stopwatch]::StartNew()
$imgs = [System.Collections.Generic.List[string]]::new()
$imgs.Add($b64)
$e.Ask('Leia a imagem anexada e responda SOMENTE o texto que voce ve nela, sem mais nada.', $imgs,
       'Hoje e 09/10/2026. Teste automatico de visao. Responda exatamente o texto da imagem.')

$txt = ''; $done = $false
while (-not $done -and $sw.Elapsed.TotalSeconds -lt 90) {
    Start-Sleep -Milliseconds 150
    $msg = $null
    while ($q.TryDequeue([ref]$msg)) {
        switch ($msg.Type) {
            'delta'   { $txt += $msg.Text }
            'status'  { Write-Host "[$([int]$sw.Elapsed.TotalSeconds)s] STATUS: $($msg.Text)" -ForegroundColor Cyan }
            'error'   { Write-Host "ERRO: $($msg.Text)" -ForegroundColor Red; $done = $true }
            'done'    { $done = $true }
        }
        $msg = $null
    }
}
Write-Host "`n=== RESPOSTA DE VISAO (${([int]$sw.Elapsed.TotalSeconds)}s) ===" -ForegroundColor Green
Write-Host $txt
