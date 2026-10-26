# test-onda7-e2e.ps1 — E2E REAL (modelo + UIA) da Onda 7 (v3.25):
#   Turno 1: todo_write (2 atualizacoes) + git_status/git_log + file_grep
#            (files e context=2) — tudo leitura, sem confirmar nada.
#   Turno 2: file_edit (diff → ConfirmYes) + git_commit (ConfirmYes) →
#            commit existe no repo e arquivo trocado; todo 4/4.
#   Requer passthrough OFF (senão o gate aprova tudo e a confirmação do
#   git_commit não é provada) — desliga/religa como o plantext faz.
# Rodar com: pwsh -STA -File test-onda7-e2e.ps1   (app dev rodando)
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
function Read-LogText {
    $fs = [IO.FileStream]::new($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Read-New([int]$mark) { try { (Read-LogText).Substring($mark) } catch { Start-Sleep -Milliseconds 300; (Read-LogText).Substring($mark) } }
function Wait-Log([int]$mark, [string]$pattern, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        try { $new = (Read-LogText).Substring($mark) } catch { $new = '' }
        if ($new -match $pattern) { return $new }
        Start-Sleep -Milliseconds 400
    }
    return ''
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
function Get-MainWin([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    foreach ($w in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($w.Current.Name -like '*ZQuick*' -and $w.Current.Name -notlike '*hist*') { return $w }
    }
    $null
}
function Find-ById($win, [string]$id) {
    for ($t = 0; $t -lt 6; $t++) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
            return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        } catch { Start-Sleep -Milliseconds 700 }
    }
    throw "UIA nao respondeu procurando '$id'"
}
function Click-Center($el) {
    $p = $el.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y); Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
function Click-Invoke($el) { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep -Milliseconds 300 }
function Send-Line($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    Click-Center $tb
    Tap 0x0D
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | log: $ctx" } }

# ---- repo rascunho hermetico ----
$repo = Join-Path $env:TEMP 'zq-onda7-e2e\repo'
if (Test-Path (Split-Path -Parent $repo)) { Remove-Item (Split-Path -Parent $repo) -Recurse -Force }
$null = New-Item -ItemType Directory -Path $repo -Force
git -C $repo init -q
git -C $repo config user.email 'zq@test.local'
git -C $repo config user.name 'ZQuick Test'
@('linha um', 'NEEDLE-E2E vela acesa', 'linha tres', 'linha quatro', 'linha cinco') | Set-Content (Join-Path $repo 'notas.txt')
git -C $repo add -A
git -C $repo commit -q -m 'base'
"repo rascunho: $repo"

$cfgPath = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json'
$passWas = [bool]((Get-Content $cfgPath -Raw | ConvertFrom-Json).passthrough)
$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick dev nao achado' }

try {
    $t0 = (Read-LogText).Length   # log tem FATAL de dias anteriores (sem data) — só o segmento do teste conta
    $w = $null
    for ($try = 0; $try -lt 6 -and -not $w; $try++) {
        Combo 0x12 0x51; Start-Sleep -Milliseconds 900
        $cand = Get-MainWin $app.ProcessId
        if ($cand -and (Find-ById $cand 'InputBox')) { $w = $cand }
    }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    # cleanup de run anterior: turno rodando -> Parar; fila -> descarta
    for ($k = 0; $k -lt 15; $k++) {
        $sb = Find-ById $w 'SendBtn'
        $busy = $sb.Current.Name -eq [string][char]0x23F9 + ' Parar'
        $del = Find-ById $w 'QDel1'
        if ($del) { Click-Invoke $del; Start-Sleep -Milliseconds 300; continue }
        if ($busy) {
            $m0 = (Read-LogText).Length
            Click-Invoke $sb
            if (-not (Wait-Log $m0 'respondido: ' 90)) { throw 'Parar não fechou o turno no cleanup' }
            Start-Sleep -Milliseconds 400; continue
        }
        break
    }

    # passthrough OFF p/ provar a confirmacao do git_commit (religa no finally)
    $mark = (Read-LogText).Length
    if ($passWas) {
        Click-Invoke (Find-ById $w 'PassBtn')
        if (-not (Wait-Log $mark 'chrome: passthrough False' 10)) { throw 'nao conseguiu desligar passthrough' }
    }

    # painel do todo pode ter ficado oculto de run anterior — o todo_write da fase 1 reabre

    # ================= TURNO 1: checklist + git leitura + grep =================
    $p1 = "Teste de ferramentas no repositorio $repo (use exatamente este caminho). Faca nesta ordem, usando SOMENTE as ferramentas (tools), nunca PowerShell: " +
          "(1) todo_write com 4 itens: 'criar repo de teste' completed, 'inspecionar repo' in_progress, 'buscar needle' pending, 'commit final' pending. " +
          "(2) git_status com repo=$repo e git_log com repo=$repo. " +
          "(3) file_grep com pattern=NEEDLE-E2E, path=$repo, mode=files; depois file_grep de novo com pattern=NEEDLE-E2E, path=$repo, context=2. " +
          "(4) todo_write atualizado: os 3 primeiros completed, 'commit final' pending. " +
          "(5) Responda em 3 linhas curtas: o que o status mostrou, quantos arquivos o grep achou, em que linha esta o needle. Nao use run_ps."
    $mark = (Read-LogText).Length
    Send-Line $w $p1

    $todo1 = Wait-Log $mark 'todo: 1/4' 240
    Assert ($todo1 -ne '') 'turno 1: primeiro todo_write (1/4) nao apareceu' (Read-New $mark)
    "PASS 1a: todo_write 1/4 (painel vivo)"
    $seg = Wait-Log $mark 'respondido: ' 300
    Assert ($seg -ne '') 'turno 1: nao fechou' (Read-New $mark)
    Assert ($seg -match 'git_status') 'turno 1: git_status nao rodou' $seg
    Assert ($seg -match 'git_log') 'turno 1: git_log nao rodou' $seg
    Assert ($seg -match 'file_grep') 'turno 1: file_grep nao rodou' $seg
    Assert ($seg -match 'todo: 3/4') 'turno 1: segunda atualizacao do checklist (3/4) nao apareceu' $seg
    Assert ($seg -notmatch 'engine: ') 'turno 1: erro de engine' $seg
    "PASS 1b: git_status + git_log + file_grep + todo 3/4"
    # painel visivel com header coerente
    $hdr = Find-ById $w 'TodoHeader'
    Assert ($null -ne $hdr -and ([string]$hdr.Current.Name) -match 'de 4') "header do todo errado: '$($hdr.Current.Name)'" ''
    "PASS 1c: header '$($hdr.Current.Name)'"

    # ================= TURNO 2: file_edit + git_commit (confirmacoes) =================
    $p2 = "Agora finalize no mesmo repo ${repo}: " +
          "(1) file_edit em $repo\notas.txt trocando old_str 'NEEDLE-E2E vela acesa' por new_str 'NEEDLE-FEITO vela apagada'. " +
          "(2) git_commit com repo=$repo, addAll=true e message 'e2e: needle trocado'. " +
          "(3) todo_write com os 4 itens completed. " +
          "Responda 1 linha com o hash do commit. Nao use run_ps nem git via PowerShell."
    $mark = (Read-LogText).Length
    $t2 = $mark   # marca FIXA do turno 2 — o mark avança a cada confirmação clicada
    Send-Line $w $p2

    # clica TODO ConfirmYes que aparecer (file_edit, git_commit) ate o turno fechar
    $nConf = 0
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
        $cur = (Read-LogText).Length
        $hit = Wait-Log $mark 'confirma: ' 20
        if ($hit) {
            $cy = Find-ById $w 'ConfirmYes'
            if ($cy) { Click-Invoke $cy; $nConf++; "  confirmacao $nConf aprovada"; Start-Sleep -Milliseconds 600 }
            $mark = (Read-LogText).Length
        }
        if ((Read-New $mark) -match 'respondido: ' -or ((Read-LogText).Length - $cur -eq 0 -and $nConf -ge 2)) { break }
        $seg2 = Read-New $mark
        if ($seg2 -match 'respondido: ') { break }
    }
    $seg2 = Read-New $mark
    if ($seg2 -notmatch 'respondido: ') {
        $seg2 = Wait-Log $mark 'respondido: ' 240
        Assert ($seg2 -ne '') 'turno 2: nao fechou' (Read-New $mark)
    }
    Assert ($nConf -ge 2) "turno 2: esperava 2+ confirmacoes (file_edit + git_commit), clicou $nConf" (Read-New $t2)
    $all = Read-New $t2
    Assert ($all -match 'confirma: Editar arquivo') 'turno 2: file_edit sem confirmacao' $all
    Assert ($all -match 'confirma: Commit no git') 'turno 2: git_commit sem confirmacao' $all
    Assert ($all -notmatch 'engine: ') 'turno 2: erro de engine' $all
    Assert ($all -notmatch 'NEGADO') 'turno 2: algo foi negado' $all
    "PASS 2a: $nConf confirmacoes aprovadas (file_edit + git_commit)"

    # resultado REAL no repo
    $head = git -C $repo log -1 --format='%h %s'
    Assert ($head -match 'e2e: needle trocado') "commit nao gravado: '$head'" $all
    $nt = Get-Content (Join-Path $repo 'notas.txt') -Raw
    Assert ($nt -match 'NEEDLE-FEITO vela apagada') "arquivo nao editado: $nt" $all
    $stat = git -C $repo status --porcelain
    Assert ([string]::IsNullOrWhiteSpace(($stat -join ''))) "working tree suja apos commit: $stat" $all
    "PASS 2b: commit '$head' + notas.txt trocado + tree limpa"

    if ($all -match 'todo: 4/4') { 'PASS 2c: todo 4/4' } else { 'AVISO: modelo nao fechou o checklist 4/4 (nao bloqueia)' }
    Assert (-not ((Read-New $t0) -match 'FATAL')) 'FATAL no log' (Read-New $t0)
    'VERDICTO: OK (Onda 7 ao vivo: checklist + git leitura em paralelo + grep + file_edit/git_commit com confirmacao)'
} finally {
    if (Test-Path (Split-Path -Parent $repo)) { Remove-Item (Split-Path -Parent $repo) -Recurse -Force }
    try {
        if ($passWas) {
            $cur = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
            if ($cur) {
                $root = [System.Windows.Automation.AutomationElement]::RootElement
                $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$cur.ProcessId)
                foreach ($cand in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
                    if ($cand.Current.Name -like '*ZQuick*' -and $cand.Current.Name -notlike '*hist*') {
                        $btn = $null
                        try { $btn = $cand.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'PassBtn'))) } catch {}
                        if ($btn) { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); break }
                    }
                }
            }
        }
    } catch { "aviso: nao religou passthrough — confira o ⚡: $_" }
    Start-Sleep -Milliseconds 400; Combo 0x12 0x51
}
