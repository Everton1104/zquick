# test-v319-wizard-e2e.ps1 - v3.19: assistente de configuracao (wizard 4 etapas).
# Fluxo REAL: SetWiz no config -> teste de conexao na API -> benchmark dos modelos
# (mede cada um) -> preferencias -> Concluir grava perfis/recomendacoes no json SEM
# mudar modelo/autostart do usuario (checkboxes garantidos OFF). Depois: mover a
# janela via MoveWindow e verificar posicao persistida + "centralizar" desligado
# sozinho. ASCII-only (5.1/ANSI); acentos por codigo de caractere.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$cfgFile = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json'
$snapFile = Join-Path $env:TEMP 'zq319-snap.json'
Copy-Item $cfgFile $snapFile -Force
$snap = Get-Content $snapFile -Raw | ConvertFrom-Json
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
function Wait-Log([string]$pat, [int]$mark, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 500
        $t = Read-New $mark
        if ($t -match $pat) { return $t }
    }
    return $null
}
$procId = (Get-Process zquick | Select-Object -First 1).Id
$root = [System.Windows.Automation.AutomationElement]::RootElement
$pcond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
function Find-Wins {
    $c = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $pcond))
    $mw = $c | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($mw) { $c += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($c)
}
function Get-MainWin {
    $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
    if ($w) { return $w }
    for ($try = 0; $try -lt 4; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $w = Find-Wins | Where-Object { $_.Current.Name -like '*busca*' } | Select-Object -First 1
        if ($w) { return $w }
    }
    throw 'janela principal nao achada'
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
# espera TextBlock (Name) casar o padrao
function Wait-Text([string]$id, [string]$pat, [int]$secs) {
    $dl = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 600
        $el = Find-ById $script:__win $id
        if ($el -and ([string]$el.Current.Name) -match $pat) { return [string]$el.Current.Name }
    }
    return $null
}
function Get-ToggleState([string]$id) {
    $el = Find-ById $script:__win $id
    if (-not $el) { throw "checkbox $id nao achado" }
    $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState.ToString()
}

$mark0 = [IO.File]::ReadAllText($log).Length
trap { for ($i = 0; $i -lt 3; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 400 }; throw }

# ---- 1. abre config -> botao do assistente (aba Perfil, a primeira) ----
$win = Get-MainWin
$null = Invoke-ById $win 'SettingsBtn'
$sw = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $sw) {
    Start-Sleep -Milliseconds 400
    $sw = Find-Wins | Where-Object { $_.Current.Name -like '*configura*' -and $_.Current.Name -notlike '*assistente*' } | Select-Object -First 1
}
if (-not $sw) { throw 'configuracoes nao abriram' }
'configuracoes abertas'
$null = Invoke-ById $sw 'SetWiz'

# ---- 2. wizard abre na etapa 1 (conexao) ----
$wz = $null; $dl = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $dl -and -not $wz) {
    Start-Sleep -Milliseconds 400
    $wz = Find-Wins | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.Name -like '*assistente*' } | Select-Object -First 1
}
if (-not $wz) { throw 'wizard nao abriu' }
'wizard aberto'
$script:__win = $wz
$st1 = Get-Text 'WzStep'
if ($st1 -notmatch ([char]0x31)) { throw "wizard nao abriu na etapa 1: '$st1'" }   # "Etapa 1 de 4"
$url0 = (Find-ById $wz 'WzUrl').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
if (-not $url0) { throw 'WzUrl nao veio preenchido' }
"WzUrl preenchido: $url0"

# ---- 3. testa a conexao de verdade ----
$null = Invoke-ById $wz 'WzTest'
$c3 = Wait-Text 'WzConn' 'conectado' 45
if (-not $c3) { throw 'conexao nao ficou OK: ' + (Get-Text 'WzConn') }
"conexao: $c3"

# ---- 4. avanca -> benchmark automatico (mede cada modelo) ----
$null = Invoke-ById $wz 'WzNext'
$c4 = Wait-Text 'WzBenchStatus' 'responderam' 300
if (-not $c4) { throw 'benchmark nao terminou: ' + (Get-Text 'WzBenchStatus') }
"benchmark: $c4"
$lic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
$items = @((Find-ById $wz 'WzBenchList').FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic))
if ($items.Count -lt 3) { throw "lista do benchmark com $($items.Count) itens" }
"lista: $($items.Count) modelos medidos (ex.: $($items[0].Current.Name.Trim()))"
$rec = Get-Text 'WzRec'
if ($rec -notmatch ('r' + [char]0xE1 + 'pido')) { throw "recomendacao vazia: '$rec'" }
"recomendacao ok (2 linhas+)"

# ---- 5. etapa 3 (preferencias): existe autostart + atalho ----
$null = Invoke-ById $wz 'WzNext'
$null = Get-ToggleState 'WzAuto'   # existe e exposto
$null = Get-Text 'WzHkCur'
'autostart + atalho presentes na etapa 3'

# ---- 6. etapa 4: resumo + garante modelo-auto e autostart OFF (nao mexe no usuario) ----
$null = Invoke-ById $wz 'WzNext'
$sum = Get-Text 'WzSum'
if ($sum.Length -lt 10) { throw 'resumo vazio' }
"resumo: $($sum.Split([char]10).Count) linhas"
if ((Get-ToggleState 'WzModelAuto') -eq 'On') {
    (Find-ById $wz 'WzModelAuto').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Start-Sleep -Milliseconds 300
    if ((Get-ToggleState 'WzModelAuto') -ne 'Off') { throw 'WzModelAuto nao desligou' }
}
'modo auto: OFF (modelo do usuario preservado)'
if ((Get-ToggleState 'WzAuto') -eq 'On') {
    (Find-ById $wz 'WzAuto').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Start-Sleep -Milliseconds 300
}
'autostart: OFF'

# ---- 7. Concluir: grava e fecha ----
$null = Invoke-ById $wz 'WzFinish'
if (-not (Wait-Log 'wizard: configurado' $mark0 20)) { throw 'nao logou wizard: configurado' }
$dl = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $dl) {
    # so JANELAS: o status '✔ configurado pelo assistente' (Wz-Finish grava) e'
    # um filho da janela principal e casava com '*assistente*' por 12s
    $still = Find-Wins | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.Name -like '*assistente*' } | Select-Object -First 1
    if (-not $still) { break }
    Start-Sleep -Milliseconds 500
}
if ($still) { throw 'wizard nao fechou apos Concluir (12s)' }
'wizard concluido e fechado'

# fecha o config e confere que o app segue vivo
$script:__win = $sw
$null = Invoke-ById $sw 'SetClose'
Start-Sleep -Milliseconds 700
if (-not (Get-Process zquick -ErrorAction SilentlyContinue)) { throw 'processo morreu' }
if ((Read-New $mark0) -match 'FATAL') { throw 'FATAL no log' }
'app vivo, sem FATAL'

# ---- 8. json: perfis ganharam lista + recomendacoes; modelo/atalho intactos ----
$j = Get-Content $cfgFile -Raw | ConvertFrom-Json
$pp = $j.profiles.($j.profile)
$mdl = @($pp.models) | ForEach-Object { [string]$_ }
if ($mdl -notcontains 'auto') { throw "models sem 'auto': $($mdl -join ',')" }
if ($mdl.Count -lt 3) { throw "models veio curto: $($mdl.Count)" }
if (-not $pp.fastModel) { throw 'fastModel nao gravado' }
if ([string]$j.model -ne [string]$snap.model) { throw "model mudou: era $($snap.model), veio $($j.model)" }
if ([string]$j.hotkey -ne [string]$snap.hotkey) { throw 'hotkey mudou sem motivo' }
"json ok: $($mdl.Count) modelos (auto incluso), fastModel=$($pp.fastModel), bigModel=$($pp.bigModel), model/hotkey intactos"
$rk = $null
try { $rk = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ZQuick' -ErrorAction Stop).'ZQuick' } catch {}
if ($rk) { throw 'run key ZQuick foi criada (autostart deveria ficar OFF)' }
'autostart nao criado no registro'

# ---- 9. posicao da janela: mover -> salva nova posicao; "centralizar" so desliga se estava ligado ----
$win = Get-MainWin
$hadCenter = [bool]$j.window.center
$beforeXY = "$($j.window.x),$($j.window.y)"
$hwnd = [IntPtr]$win.Current.NativeWindowHandle
$r = $win.Current.BoundingRectangle
"janela em ($([int]$r.Left),$([int]$r.Top)) center=$hadCenter"
$mark1 = [IO.File]::ReadAllText($log).Length
[K.I]::MoveWindow($hwnd, [int]$r.Left + 37, [int]$r.Top + 23, [int]$r.Width, [int]$r.Height, $true) | Out-Null
if ($hadCenter -and -not (Wait-Log 'janela: movida' $mark1 10)) { throw 'mover nao desligou o centralizar (sem log)' }
Start-Sleep -Milliseconds 2600   # debounce de 1200ms + folga
$j2 = Get-Content $cfgFile -Raw | ConvertFrom-Json
if ($hadCenter -and [bool]$j2.window.center) { throw 'center continua true apos mover' }
if ("$($j2.window.x),$($j2.window.y)" -eq $beforeXY) { throw 'posicao nao persistiu apos mover' }
"posicao persistiu: ($beforeXY) -> ($($j2.window.x),$($j2.window.y)), center=$($j2.window.center)"

# ---- 10. restaura o estado do usuario e reinicia ----
Stop-Process -Name zquick -Force; Start-Sleep -Milliseconds 800
$j2.window.center = $hadCenter
$j2.window.x = $j.window.x; $j2.window.y = $j.window.y
if ($snap.profiles.($snap.profile).fastModel) {
    $j2.profiles.($j2.profile).fastModel = [string]$snap.profiles.($snap.profile).fastModel
}
$j2 | ConvertTo-Json -Depth 6 | Set-Content $cfgFile -Encoding utf8
Start-Process 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.exe'
$dl = (Get-Date).AddSeconds(20); $okBoot = $false
while ((Get-Date) -lt $dl) {
    $t = try { [IO.File]::ReadAllText($log) } catch { '' }
    if ($t -match 'engine compilado') { $okBoot = $true; break }
    Start-Sleep -Milliseconds 400
}
if (-not $okBoot) { throw 'app nao reiniciou limpo' }
'estado do usuario restaurado (center/x/y/fastModel), app reiniciado limpo'
"VERDICTO: OK (wizard 4 etapas com API real + benchmark + gravacao no json + posicao da janela persistida + centralizar desliga ao mover)"
