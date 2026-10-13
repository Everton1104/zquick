# test-zaiserver-ui.ps1 — E2E T2 (Onda 3): busca server-side Z.ai (web_search_prime).
#   1) pergunta "fato atual" -> status "busca Z.ai (no servidor)" (NAO pré-busca Bing),
#      server tool roda no /v1/messages, tool_result alimenta o rodape "fontes: N";
#   2) follow-up NA MESMA conversa -> replay do historico com blocos do servidor
#      tem que ser aceito (nenhuma note "não aceita" = sem fallback 400).
# Rodar com: pwsh -STA -File test-zaiserver-ui.ps1   (app residente rodando)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
Add-Type -Namespace K -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
function Tap([byte]$vk) {
    [K.I]::keybd_event($vk,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
    [K.I]::keybd_event($vk,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 45
}
function Combo([byte]$mod,[byte]$vk) {
    [K.I]::keybd_event($mod,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($vk,0,0,[UIntPtr]::Zero);  Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($vk,0,2,[UIntPtr]::Zero);  Start-Sleep -Milliseconds 70
    [K.I]::keybd_event($mod,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 200
}
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        $new = Read-New $mark
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 400
    }
    return ''
}
function Get-MainWin([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    foreach ($w in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($w.Current.Name -like '*ZQuick*' -and $w.Current.Name -notlike '*hist*') { return $w }
    }
    $null
}
function Find-ById($win, [string]$id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}
function Set-InputText($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $tb
}
function Click-Center($el) {
    $p = $el.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | log: $ctx" } }

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

try {
    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    # ---- turno 1: fato atual -> caminho zai-server ----
    $mark = [IO.File]::ReadAllText($log).Length
    $tb = Set-InputText $w 'cotação do dólar hoje? resposta curta com o valor'
    Click-Center $tb
    Tap 0x0D
    $t1 = Wait-Log $mark 'respondido: ' 150
    if (-not $t1) { throw "turno 1 sem resposta. log: $(Read-New $mark)" }
    Assert ($t1 -match 'busca Z\.ai \(no servidor\)') 'status zai-server nao apareceu' $t1
    Assert ($t1 -notmatch 'pré-busca') 'rodou pré-busca Bing (devia pular no modo zai-server)' $t1
    Assert ($t1 -match 'fontes: (\d+)') 'rodapé "fontes: N" nao apareceu (tool_result não colhido)' $t1
    Assert ([int]$Matches[1] -ge 1) 'fontes = 0' $t1
    Assert ($t1 -notmatch 'não aceita') 'fallback 400 disparou (server tool ou cache rejeitados)' $t1
    Assert ($t1 -notmatch 'engine: ') 'erro do engine' $t1
    $prev = if ($t1 -match 'respondido: \d+ chars em \d+s \| (.+)') { $Matches[1] } else { '(preview?)' }
    Assert ($prev -notmatch 'web_search_prime_result_summary') 'dump cru do servidor vazou para a resposta (filtro SrvTrace não pegou)' $t1
    "turno 1 OK — resposta: $prev"

    # ---- turno 2: follow-up NA MESMA conversa -> replay do historico com blocos server ----
    $mark2 = [IO.File]::ReadAllText($log).Length
    $tb = Set-InputText $w 'e o euro? resposta curta'
    Click-Center $tb
    Tap 0x0D
    $t2 = Wait-Log $mark2 'respondido: ' 120
    if (-not $t2) { throw "turno 2 sem resposta. log: $(Read-New $mark2)" }
    Assert ($t2 -notmatch 'não aceita') 'replay do historico com blocos do servidor foi rejeitado (400)' $t2
    Assert ($t2 -notmatch 'engine: ') 'erro do engine no turno 2' $t2
    "PASS: zai-server E2E — server tool + rodapé de fontes + replay do histórico OK"
} finally {
    Start-Sleep -Milliseconds 400; Combo 0x11 0x4E; Start-Sleep -Milliseconds 500; Tap 0x1B; Start-Sleep -Milliseconds 500; Combo 0x12 0x51
}
