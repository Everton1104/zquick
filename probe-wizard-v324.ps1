# probe-wizard-v324.ps1 — valida a Etapa 1 do assistente v3.24 (presets de
# provedor + LLM local): abre ⚙→🧙, confere os 7 botões, clica Ollama (URL muda
# p/ localhost:11434, rótulo da chave vira "opcional"), clica Z.ai (volta ao
# base de nuvem e rótulo padrão), testa conexão no provedor de nuvem (✕ ou ✔
# serve — prova que o teste roda com o base novo) e fecha sem FATAL.
# NÃO clica em Concluir: nada é gravado no zquick.json.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$mark0 = [IO.File]::ReadAllText($log).Length
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }
function Wait-Log([string]$pat, [int]$mark, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) { Start-Sleep -Milliseconds 400; $t = Read-New $mark; if ($t -match $pat) { return $t } }
    return $null
}
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
$procId = (Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1).ProcessId
if (-not $procId) { throw 'processo zquick dev nao achado' }
$root = [System.Windows.Automation.AutomationElement]::RootElement
$pcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$procId)
function Find-Wins {
    $c = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Invoke-ById($win, [string]$id) {
    $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    if (-not $el) { throw "elemento $id nao achado" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
function Find-ById($win, [string]$id) {
    $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)))
}
function Get-Text([string]$id) {
    $el = Find-ById $script:__win $id
    if (-not $el) { throw "texto $id nao achado" }
    [string]$el.Current.Name
}
function Wait-Text([string]$id, [string]$pat, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 500
        $el = Find-ById $script:__win $id
        if ($el -and ([string]$el.Current.Name) -match $pat) { return [string]$el.Current.Name }
    }
    return $null
}
function Get-Val([string]$id) {
    $el = Find-ById $script:__win $id
    if (-not $el) { throw "caixa $id nao achada" }
    $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
}
trap { Write-Host "ERRO: $_" -ForegroundColor Red; for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; throw }

# ---- 1. abre a janela, ⚙ e o assistente ----
$mw = $null
for ($try = 0; $try -lt 6 -and -not $mw; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    $mw = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' -and (Find-ById $_ 'InputBox') } | Select-Object -First 1
}
if (-not $mw) { throw 'janela principal nao apareceu' }
'janela ok'
$null = Invoke-ById $mw 'SettingsBtn'
$sw = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $sw) { Start-Sleep -Milliseconds 400; $sw = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' -and $_.Current.Name -notlike '*assistente*' } | Select-Object -First 1 }
if (-not $sw) { throw 'configuracoes nao abriram' }
$null = Invoke-ById $sw 'SetWiz'
$wz = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $wz) { Start-Sleep -Milliseconds 400; $wz = Find-Wins | Where-Object { $_.Current.Name -like '*assistente*' } | Select-Object -First 1 }
if (-not $wz) { throw 'wizard nao abriu' }
$script:__win = $wz
'wizard aberto'

# ---- 2. os 7 botões de preset + rótulo da chave nomeado ----
$st1 = Get-Text 'WzStep'
if ($st1 -notmatch 'Etapa 1') { throw "abriu fora da etapa 1: '$st1'" }
foreach ($b in 'WzPrZai','WzPrKimi','WzPrDeepseek','WzPrOllama','WzPrLmstudio','WzPrLlama','WzPrOutro') {
    if (-not (Find-ById $wz $b)) { throw "botao de preset $b nao achado" }
}
if (-not (Find-ById $wz 'WzKeyLabel')) { throw 'WzKeyLabel nao achado' }
'7 presets + WzKeyLabel presentes'
$zaiBase = 'https://api.z.ai/api/anthropic'
$url0 = Get-Val 'WzUrl'
"url inicial: $url0"

# ---- 3. clica Ollama: URL local + chave opcional ----
$null = Invoke-ById $wz 'WzPrOllama'
Start-Sleep -Milliseconds 500
$u1 = Get-Val 'WzUrl'
if ($u1 -ne 'http://localhost:11434') { throw "Ollama nao setou a URL (veio '$u1')" }
$l1 = Get-Text 'WzKeyLabel'
if ($l1 -notmatch 'opcional') { throw "rotulo da chave nao virou opcional: '$l1'" }
"ollama: URL=$u1 | rotulo='$l1'"

# ---- 4. clica Z.ai: volta ao base de nuvem + rotulo padrao ----
$null = Invoke-ById $wz 'WzPrZai'
Start-Sleep -Milliseconds 500
$u2 = Get-Val 'WzUrl'
if ($u2 -ne $zaiBase) { throw "Z.ai nao restaurou a URL (veio '$u2')" }
$l2 = Get-Text 'WzKeyLabel'
if ($l2 -match 'opcional') { throw "rotulo da chave continuou opcional: '$l2'" }
"zai: URL=$u2 | rotulo='$l2'"

# ---- 5. teste de conexao com o base novo (✕ ou ✔ — ambos provam o fluxo) ----
$null = Invoke-ById $wz 'WzTest'
$c5 = $null
$c5 = Wait-Text 'WzConn' '([✖✕✔xX])|conectado' 40
if (-not $c5) { throw 'WzTest nao respondeu: ' + (Get-Text 'WzConn') }
"teste de conexao: $c5"

# ---- 6. fecha tudo; nada foi gravado (sem Concluir) ----
$null = Invoke-ById $wz 'WzClose'
Start-Sleep -Milliseconds 500
$null = Invoke-ById $sw 'SetClose'
Start-Sleep -Milliseconds 500
if (-not (Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' })) { throw 'processo morreu' }
if ((Read-New $mark0) -match 'FATAL') { throw 'FATAL no log' }
'app vivo, sem FATAL, config intacta (Concluir nao foi clicado)'
"VERDICTO: OK (7 presets, Ollama->URL local + chave opcional, Z.ai volta ao base, teste de conexao respondeu, fecha limpo)"
