# test-msi-setup-e2e.ps1 - E2E do instalador 3.26.0 (rodar apos dist\obj\prep326.ps1):
# percorre a UI basica do MSI (boas-vindas -> licenca (aceita) -> pasta ->
# chave da API (digita a chave REAL - backup/settings.json, sem logar) ->
# instalar -> concluir com "Iniciar o ZQuick agora") e confere que o app abre
# JA CONFIGURADO: zquick.setup consumido, perfil com chave, modelos varridos
# pelo provedor e sem assistente de configuracao. No fim testa a moldura
# estreita (520px): Min/Max/Close continuam visiveis dentro da janela.
#
# LICAO (probe/poke): a UI basica do msiexec expoe cada dialogo como janela
# top-level 'ZQuick Setup' e os botoes como Button hwnds OWNER-DRAW - o bridge
# MSAA->UIA nao da NENHUM pattern (nem Invoke; LegacyIAccessible nao existe no
# UIA gerenciado). Entao o instalador e' guiado por Win32 puro: FindWindowEx +
# GetWindowText p/ achar (curingas no lugar dos acentos - arquivo ASCII puro),
# BM_CLICK p/ clicar/marcar checkbox (BM_GETCHECK p/ estado) e WM_SETTEXT p/
# digitar. UIA fica so' pro app WPF (AutomationId MinBtn/MaxBtn/CloseBtn).
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$msi    = Join-Path $here 'dist\ZQuick-3.26.0.msi'
$appDir = "$env:LOCALAPPDATA\Programs\ZQuick"
$bak    = Join-Path $appDir 'zquick.json.bak-e2e'
$logF   = Join-Path $env:TEMP 'zquick.log'   # LICAO: o Log() do app escreve no %TEMP%, nao no $appDir
Remove-Item $logF -Force -ErrorAction SilentlyContinue   # log limpo = greps honestos (sem falso-pass de run anterior)
if (-not (Test-Path $msi)) { throw 'MSI nao encontrado: dist\ZQuick-3.26.0.msi' }
if (-not (Test-Path $bak)) { throw 'backup zquick.json.bak-e2e nao encontrado - rode dist\obj\prep326.ps1 antes' }

# chave real (nunca ecoar): apiKey do perfil no backup, senao o fallback que o
# proprio app usa (~/.claude/settings.json env.ANTHROPIC_AUTH_TOKEN - linha 393)
$cfgOld  = Get-Content $bak -Raw | ConvertFrom-Json
$apiKey  = $cfgOld.profiles.($cfgOld.profile).apiKey
if (-not $apiKey) {
    $sj = Get-Content (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw | ConvertFrom-Json
    $apiKey = $sj.env.ANTHROPIC_AUTH_TOKEN
}
if (-not $apiKey) { throw 'sem apiKey (backup nem settings.json) - aborta antes de instalar' }
"chave obtida: $($apiKey.Length) chars (valor oculto)"

Add-Type -Namespace W -Name N -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumChildProc cb, IntPtr l);
public delegate bool EnumChildProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder sb, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int n);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, System.Text.StringBuilder l);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
'@
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$script:npass = 0; $script:nfail = 0; $script:fails = @()
# [Console]::WriteLine (e nao string no pipeline): Pass/Fail nao podem
# poluir o retorno das funcoes - `if (-not (Click-Btn ...))` via a ver a
# string FAIL como array truthy e o fallback *Install* nunca rodava (o
# mesmo [void] engolia o "nao achei botao" sem ninguem ver).
function Pass([string]$m) { $script:npass++; [Console]::WriteLine("PASS $($script:npass): $m") }
function Fail([string]$m) { $script:nfail++; $script:fails += $m; [Console]::WriteLine("FAIL: $m") }

# ---------- camada Win32 do instalador ----------
$BM_CLICK = 0xF5; $BM_GETCHECK = 0xF0; $WM_SETTEXT = 0xC
function Get-Txt([IntPtr]$h) { $sb = New-Object System.Text.StringBuilder 512; [void][W.N]::GetWindowText($h, $sb, 512); $sb.ToString() }
function Get-Cls([IntPtr]$h) { $sb = New-Object System.Text.StringBuilder 256; [void][W.N]::GetClassName($h, $sb, 256); $sb.ToString() }
# LICAO extra: FindWindow/FindWindowEx NAO veem os dialogos do msiexec (retornam
# 0 com titulo exato) - EnumWindows/EnumChildWindows veem normalmente. Usa-los.
function Find-Dlg([int]$secs = 1) {
    for ($i = 0; $i -lt ($secs * 5); $i++) {
        $script:hit = [IntPtr]::Zero
        $cb = [W.N+EnumWindowsProc]{ param($h, $l)
            $sb = New-Object System.Text.StringBuilder 256
            [void][W.N]::GetWindowText($h, $sb, 256)
            if ($sb.ToString() -eq 'ZQuick Setup' -and [W.N]::IsWindowVisible($h)) { $script:hit = $h; return $false }
            return $true
        }
        [void][W.N]::EnumWindows($cb, [IntPtr]::Zero)
        if ($script:hit -ne [IntPtr]::Zero) { return [IntPtr]$script:hit }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}
function Get-Childs([IntPtr]$dlg) {
    $script:clist = @()
    $cb = [W.N+EnumChildProc]{ param($h, $l) $script:clist += $h; return $true }
    [void][W.N]::EnumChildWindows($dlg, $cb, [IntPtr]::Zero)
    return $script:clist
}
# espera um dialogo cujo conteudo case $rxTexto (child de qualquer classe)
function Wait-DlgText([string]$pattern, [int]$secs, [string]$tag) {
    for ($i = 0; $i -lt ($secs * 5); $i++) {
        $dlg = Find-Dlg 1
        if ($dlg -ne [IntPtr]::Zero) {
            foreach ($c in (Get-Childs $dlg)) { if ((Get-Txt $c) -like $pattern) { return [IntPtr]$dlg } }
        }
        Start-Sleep -Milliseconds 200
    }
    Fail "nao apareceu '$tag' ($pattern) em ${secs}s"; return [IntPtr]::Zero
}
function Click-Btn([IntPtr]$dlg, [string[]]$patterns, [int]$secs, [string]$tag) {
    for ($i = 0; $i -lt ($secs * 5); $i++) {
        if ($dlg -eq [IntPtr]::Zero) { $dlg = Find-Dlg 1 }
        if ($dlg -ne [IntPtr]::Zero) {
            foreach ($c in (Get-Childs $dlg)) {
                if ((Get-Cls $c) -eq 'Button') {
                    # multiplos patterns: dialogos autorais = pt-BR, do WixUI =
                    # ingles ("&Install"/"&Finish") mesmo na cultura pt-BR
                    foreach ($p in $patterns) {
                        if ((Get-Txt $c) -like $p) {
                            [void][W.N]::SendMessage($c, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
                            Pass "clicou $tag"; return $true
                        }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    Fail "nao achei botao '$tag' ($($patterns -join ' / ')) em ${secs}s"; return $false
}
# checkbox = Button com estilo BS_CHECKBOX(2) ou BS_AUTOCHECKBOX(3) - LICAO do
# dump: o msiexec cria com BS_CHECKBOX (2), nao 3. Clica UMA vez so' e confia
# na navegacao (GETCHECK pode nao refletir se o proprio MSI desenhar a marca).
function Get-CheckBox([IntPtr]$dlg, [string]$pattern) {
    foreach ($c in (Get-Childs $dlg)) {
        if ((Get-Cls $c) -eq 'Button' -and (Get-Txt $c) -like $pattern) {
            $st = [W.N]::GetWindowLong($c, -16) -band 0xF
            if ($st -eq 2 -or $st -eq 3) { return $c }
        }
    }
    return [IntPtr]::Zero
}
function Is-Marcado([IntPtr]$cb) { ([W.N]::SendMessage($cb, $BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero)) -eq [IntPtr]1 }

# ---- 1: liga o instalador ----
$null = Start-Process msiexec.exe -ArgumentList '/i', $msi -PassThru
$dlg = Find-Dlg 30
if ($dlg -eq [IntPtr]::Zero) { throw 'janela do instalador nao abriu' }
Pass 'janela do instalador abriu'

# ---- 2: boas-vindas ----
$dlg = Wait-DlgText '*Bem-vindo*' 30 'boas-vindas'
if ($dlg -ne [IntPtr]::Zero) { Pass 'dialogo de boas-vindas (pt-BR)' }
[void](Click-Btn $dlg '*van?ar*' 15 'Avancar (boas-vindas)')

# ---- 3: licenca propria (ZQLicenseDlg) ----
$dlg = Wait-DlgText '*Licen?a de uso do ZQuick*' 20 'licenca-props'
if ($dlg -ne [IntPtr]::Zero) {
    Pass 'licenca propria no lugar do lorem'
    # RTF real (TERMOS DE USO) e nao o lorem do WixUI localizado pelos wxl
    foreach ($c in (Get-Childs $dlg)) {
        if ((Get-Cls $c) -like 'RichEdit*') {
            $sb = New-Object System.Text.StringBuilder 4096
            [void][W.N]::SendMessage($c, 0xD, [IntPtr]4000, $sb)
            if ($sb.ToString() -match 'TERMOS DE USO') { Pass 'RTF da licenca = termos do kit (nao lorem)' }
            else { Fail 'RTF da licenca nao e o do kit (lorem?)' }
        }
    }
}
else {
    $d2 = Find-Dlg 1
    if ($d2 -ne [IntPtr]::Zero) {
        $allTxt = ((Get-Childs $d2) | ForEach-Object { Get-Txt $_ }) -join ' | '
        if ($allTxt -match 'End-User') { Fail 'apareceu a licenca INGLESA do WixUI (roteamento falhou)' }
    }
    $dlg = [IntPtr]::Zero
}
if ($dlg -ne [IntPtr]::Zero) {
    $cb = [IntPtr]::Zero
    for ($i = 0; $i -lt 100 -and $cb -eq [IntPtr]::Zero; $i++) { $cb = Get-CheckBox $dlg '*Aceito*'; if ($cb -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 } }
    if ($cb -ne [IntPtr]::Zero) {
        [void][W.N]::SendMessage($cb, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 500
        if (Is-Marcado $cb) { Pass 'aceitou os termos' } else { Pass 'aceitou os termos (clique dado; GETCHECK nao confirma)' }
    } else { Fail 'checkbox "Aceito os termos" nao apareceu' }
    Start-Sleep -Milliseconds 300
    [void](Click-Btn $dlg '*van?ar*' 15 'Avancar (licenca)')
}

# ---- 4: pasta ----
$dlg = Wait-DlgText '*Pasta de destino*' 20 'pasta'
if ($dlg -ne [IntPtr]::Zero) { Pass 'dialogo da pasta' }
[void](Click-Btn $dlg '*van?ar*' 15 'Avancar (pasta)')

# ---- 5: chave da API (ZQKeyDlg) - LICAO: os Edits do msiexec sao classe
#      RichEdit20W (GetWindowText nao le de outro processo; WM_GETTEXT le).
#      Primeiro RichEdit = base (preenchido), ultimo = chave. ----
$dlg = [IntPtr]::Zero; $keyEdit = [IntPtr]::Zero
for ($i = 0; $i -lt 100 -and $keyEdit -eq [IntPtr]::Zero; $i++) {
    $d = Find-Dlg 1
    if ($d -ne [IntPtr]::Zero) {
        $rich = @()
        foreach ($c in (Get-Childs $d)) { if ((Get-Cls $c) -like 'RichEdit*') { $rich += $c } }
        if ($rich.Count -ge 2) { $keyEdit = $rich[-1]; $dlg = $d; break }
    }
    Start-Sleep -Milliseconds 200
}
if ($keyEdit -ne [IntPtr]::Zero) {
    Pass 'ZQKeyDlg apareceu (2 campos RichEdit)'
    # LICAO (probe-key fase A): o Edit do MSI so' comita o texto na PROPERTY
    # com a danca de foco WM_SETFOCUS -> WM_SETTEXT -> WM_KILLFOCUS - o
    # RichEdit so' notifica EN_CHANGE pro dialogo quando TEM foco; sem o
    # WM_SETFOCUS o texto aparece no campo mas a property fica vazia (a CA via
    # ZQKEY vazia e nao gravava o zquick.setup). WM_CHAR nao salva; WM_SETFOCUS
    # sim.
    [void][W.N]::SendMessage($keyEdit, 0x7, [IntPtr]::Zero, [IntPtr]::Zero)
    [void][W.N]::SendMessage($keyEdit, $WM_SETTEXT, [IntPtr]::Zero, $apiKey)
    [void][W.N]::SendMessage($keyEdit, 0x8, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    $sb = New-Object System.Text.StringBuilder 512
    [void][W.N]::SendMessage($keyEdit, 0xD, [IntPtr]500, $sb)
    $len = $sb.Length
    if ($len -eq $apiKey.Length) { Pass "chave digitada ($len chars, valor oculto)" }
    else { Fail "chave nao colou (campo com $len chars)" }
} else { Fail 'ZQKeyDlg nao apareceu (2 RichEdits nao achados)' }
[void](Click-Btn $dlg '*van?ar*' 15 'Avancar (chave)')

# ---- 6: pronto para instalar ----
$dlg = Wait-DlgText '*Pronto para instalar*' 20 'verifyready'
if ($dlg -ne [IntPtr]::Zero) { Pass 'resumo de instalacao' }
# LICAO: VerifyReady e ExitDialog sao do WixUI e os BOTOES ficam em ingles
# ("&Install"/"&Finish") mesmo com cultura pt-BR (so' titulo/descricao localizam)
# - os dialogos autorais no wxs tem texto proprio pt-BR.
[void](Click-Btn $dlg @('*Instalar*', '*Install*') 30 'Instalar')

# ---- 7: concluir (checkbox iniciar ligado) ----
# $seenSetup: a CA deferida grava zquick.setup DURANTE a instalacao (antes do
# ExitDialog) - vigia aqui pra provar que a ZQKEY chegou na property (o "apagado"
# isolado era falso-positivo quando a CA nem gravava).
$dlg = [IntPtr]::Zero; $cb = [IntPtr]::Zero; $seenSetup = $false
for ($i = 0; $i -lt 900 -and $cb -eq [IntPtr]::Zero; $i++) {
    if (-not $seenSetup -and (Test-Path "$appDir\zquick.setup")) { $seenSetup = $true }
    $d = Find-Dlg 1
    # '*ZQuick*' cobre pt-BR ("Iniciar o ZQuick agora") e o fallback en ("Launch ZQuick")
    if ($d -ne [IntPtr]::Zero) { $cb = Get-CheckBox $d '*ZQuick*' }
    if ($cb -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
}
if ($cb -ne [IntPtr]::Zero) {
    if (-not (Is-Marcado $cb)) { [void][W.N]::SendMessage($cb, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 500 }
    if (Is-Marcado $cb) { Pass 'instalacao concluida + "Iniciar o ZQuick agora" ligado' }
    else { Pass 'instalacao concluida ("Iniciar" - clique dado, GETCHECK nao confirma)' }
    $dlg = Find-Dlg 1
    [void](Click-Btn $dlg @('*Concluir*', '*Finish*') 15 'Concluir')
} else { Fail 'ExitDialog/checkbox "Iniciar o ZQuick agora" nao apareceu' }

# ---- 8: app subiu ----
$zq = $null
for ($i = 0; $i -lt 150 -and -not $zq; $i++) {
    $zq = Get-Process zquick -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$appDir*" } | Select-Object -First 1
    if (-not $zq) { Start-Sleep -Milliseconds 200 }
}
if ($zq) { Pass "app subiu (pid $($zq.Id))" } else { Fail 'zquick.exe nao subiu apos Concluir' }

# ---- 9: consumiu o zquick.setup ----
$okSetup = $false
for ($i = 0; $i -lt 250 -and -not $okSetup; $i++) {
    if ((Test-Path $logF) -and ((Get-Content $logF -Raw) -match 'configurado pelo instalador')) { $okSetup = $true }
    else { Start-Sleep -Milliseconds 200 }
}
if ($okSetup) { Pass 'log: perfil configurado pelo instalador' } else { Fail 'log nao mostra consumo do zquick.setup' }
if ($seenSetup -and -not (Test-Path "$appDir\zquick.setup")) { Pass 'zquick.setup gravado pela CA e apagado apos consumo' }
elseif (-not $seenSetup) { Fail 'zquick.setup NUNCA existiu (CA nao gravou = ZQKEY nao chegou na property)' }
else { Fail 'zquick.setup ainda existe' }

# ---- 10: varredura de modelos + json ----
$okScan = $false
for ($i = 0; $i -lt 300 -and -not $okScan; $i++) {
    if (Test-Path $logF) { if ((Get-Content $logF -Raw) -match 'modelos varridos') { $okScan = $true } }
    if (-not $okScan) { Start-Sleep -Milliseconds 200 }
}
if ($okScan) { Pass 'log: modelos varridos pelo provedor' } else { Fail 'log nao mostra varredura de modelos' }
if (Test-Path "$appDir\zquick.json") {
    $cfg = Get-Content "$appDir\zquick.json" -Raw | ConvertFrom-Json
    $prof = $cfg.profile
    $pobj = $cfg.profiles.$prof
    if ($pobj.apiKey -and $pobj.apiKey.Length -gt 10) { Pass "json: perfil '$prof' com chave ($($pobj.apiKey.Length) chars)" }
    else { Fail 'json: perfil sem apiKey' }
    $nmdl = @($pobj.models).Count
    if ($nmdl -gt 1) { Pass "json: $nmdl modelos listados" } else { Fail "json: models tem so' $nmdl item(ns)" }
} else { Fail 'zquick.json nao foi criado' }

# ---- 11: sem assistente de configuracao (UIA no app WPF) ----
$root = [Windows.Automation.AutomationElement]::RootElement
if ($zq) {
    Start-Sleep -Seconds 2
    $names = @()
    foreach ($e in $root.FindAll([Windows.Automation.TreeScope]::Children,
        (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $zq.Id)))) {
        if ($e.Current.ControlType -eq [Windows.Automation.ControlType]::Window) { $names += $e.Current.Name }
    }
    $wiz = @($names | Where-Object { $_ -match '(?i)ssist|onfig' })
    if (-not $wiz -and $names.Count -ge 1) { Pass "sem assistente (janelas: $($names -join ' | '))" }
    else { Fail "assistente abriu? janelas: $($names -join ' | ')" }
}

# ---- 12: moldura estreita (520px): botoes continuam visiveis ----
if ($zq) {
    $main = $null
    $winCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Window)
    $pidCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $zq.Id)
    for ($i = 0; $i -lt 50 -and -not $main; $i++) {
        $main = $root.FindFirst([Windows.Automation.TreeScope]::Children, (New-Object Windows.Automation.AndCondition($pidCond, $winCond)))
        if (-not $main) { Start-Sleep -Milliseconds 200 }
    }
    if ($main) {
        $r0 = $main.Current.BoundingRectangle
        $h  = [IntPtr]$main.Current.NativeWindowHandle
        [void][W.N]::SetWindowPos($h, [IntPtr]::Zero, [int]$r0.X, [int]$r0.Y, 520, [int]$r0.Height, 0x0004)
        Start-Sleep -Milliseconds 700
        $main2 = $root.FindFirst([Windows.Automation.TreeScope]::Children, (New-Object Windows.Automation.AndCondition($pidCond, $winCond)))
        if ($main2) {
            $wr = $main2.Current.BoundingRectangle
            foreach ($bn in @('MinBtn', 'MaxBtn', 'CloseBtn')) {
                $b = $main2.FindFirst([Windows.Automation.TreeScope]::Descendants,
                    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, $bn)))
                if (-not $b) { Fail "$bn nao achado na janela estreita"; continue }
                $br = $b.Current.BoundingRectangle
                if ($br.Width -gt 0 -and $br.Right -le ($wr.Right + 2) -and $br.Left -ge $wr.Left) {
                    Pass "$bn visivel dentro da janela de $([int]$wr.Width)px"
                } else { Fail "$bn fora/clipped: btn R$([int]$br.Right) vs win R$([int]$wr.Right) (w=$([int]$br.Width))" }
            }
        }
        [void][W.N]::SetWindowPos($h, [IntPtr]::Zero, [int]$r0.X, [int]$r0.Y, [int]$r0.Width, [int]$r0.Height, 0x0004)
        Pass 'tamanho original restaurado'
    } else { Fail 'janela principal nao achada p/ teste de moldura' }
}

""
"E2E MSI-SETUP: $($script:npass) pass / $($script:nfail) fail"
if ($script:fails.Count -gt 0) { $script:fails | ForEach-Object { "  - $_" }; exit 1 } else { 'E2E VERDE' }
