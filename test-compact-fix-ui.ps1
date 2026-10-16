# test-compact-fix-ui.ps1 — E2E do fix da compactacao (16/10): arquivo de historia com fragmentos
# truncados (deficit "]}") e' retomado pelo 🕘, SetHistory repara, e o envio seguinte NAO da 400.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$histDir = Join-Path $PSScriptRoot 'history'
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
function Find-WindowsByProc([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))
}
function Invoke-Button($win, [string]$name, [string]$label) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $btn) { throw "botao '$label' nao encontrado via UIA" }
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    "invocado: $label"
}
function Read-New([int]$mark) { try { [IO.File]::ReadAllText($log).Substring($mark) } catch { Start-Sleep -Milliseconds 300; [IO.File]::ReadAllText($log).Substring($mark) } }

# 1) arquivo de conversa com o par [RESUMO] truncado EXATAMENTE como o bug gerava
$testFile = Join-Path $histDir ('conv-{0:yyyyMMdd-HHmmss-fff}.json' -f (Get-Date))
$conv = [ordered]@{
    time = (Get-Date).ToString('s')
    profile = 'zai'
    model = 'glm-5.3'
    q = 'ZZ-COMPACTFIX pergunta de teste'
    a = 'resposta antiga'
    msgs = @(
        '{"role":"user","content":[{"type":"text","text":"[RESUMO da conversa anterior, gerado automaticamente]"}',
        '{"role":"assistant","content":[{"type":"text","text":"resumo sintetico antigo"}',
        '{"role":"user","content":[{"type":"text","text":"pergunta antiga"}]}',
        '{"role":"assistant","content":[{"type":"text","text":"resposta antiga"}]}'
    )
}
$conv | ConvertTo-Json -Depth 4 | Out-File $testFile -Encoding utf8
"arquivo de teste: $(Split-Path -Leaf $testFile) (msgs 0-1 truncadas)"

try {
    # 2) acha o processo e a janela (exe: processo chama zquick; tarefa: pwsh com zquick.ps1)
    $app = Get-Process zquick -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $app) {
        $app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
        $procId = [int]$app.ProcessId
    } else { $procId = $app.Id }
    if (-not $procId) { throw 'processo zquick nao achado' }
    "pid: $procId"
    $win = $null
    for ($try = 0; $try -lt 3 -and -not $win; $try++) {
        $win = @(Find-WindowsByProc $procId) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
        if (-not $win) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900 }
    }
    if (-not $win) { throw 'janela do zquick nao achada via UIA' }
    $mark = [IO.File]::ReadAllText($log).Length

    # 3) abre o 🕘 (por AutomationId — Name com emoji nao casa entre camadas de encoding) e
    #    retoma o item 0 (mais recente = arquivo de teste)
    $hbCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'HistBtn')
    $histBtn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $hbCond)
    if (-not $histBtn) { throw 'HistBtn nao achado por AutomationId' }
    $histBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    "invocado: relogio/historico (AutomationId HistBtn)"
    $okDialogo = $false
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if ((Read-New $mark) -match 'historico: dialogo \((\d+) itens\)') { $okDialogo = $true; "dialogo aberto com $($Matches[1]) itens"; break }
        if ((Read-New $mark) -match 'historico-ui: (.+)') { throw "dialogo ERRO: $($Matches[1])" }
    }
    if (-not $okDialogo) { throw 'dialogo nao abriu (sem log)' }
    $mark2 = [IO.File]::ReadAllText($log).Length
    # dialogo com moldura propria (v3.9.2) aninha como FILHO da main na arvore UIA — e o
    # elemento $win pode ficar stale apos o ShowDialog: readquirir a cada retry
    $dlg = $null
    $deadline = (Get-Date).AddSeconds(6)
    while (-not $dlg -and (Get-Date) -lt $deadline) {
        $win2 = @(Find-WindowsByProc $procId) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
        if ($win2) {
            $win = $win2
            foreach ($d in @($win.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))) {
                if ($d.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) { $dlg = $d; break }
            }
        }
        if (-not $dlg) { $dlg = @(Find-WindowsByProc $procId) | Where-Object { $_.Current.Name -like '*hist*' } | Select-Object -First 1 }
        if (-not $dlg) { Start-Sleep -Milliseconds 300 }
    }
    if (-not $dlg) { throw 'dialogo nao visivel via UIA' }
    Invoke-Button $dlg 'Retomar' 'Retomar'

    # 4) retomou 4 msgs E o reparo (2 fragmentos) — log do PS (load-history) OU nota do engine
    $okLoad = $false; $okFix = $false; $nFix = -1; $nDrop = -1
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline -and -not ($okLoad -and $okFix)) {
        Start-Sleep -Milliseconds 400
        $t = Read-New $mark2
        if (-not $okLoad -and $t -match 'historico: retomou (\d+) msgs') { $okLoad = $true; "retomou $($Matches[1]) msgs (esperado 4)" }
        if (-not $okFix -and $t -match 'load-history: (\d+) fragmento\(s\) reparado\(s\), (\d+) descartado\(s\)') { $okFix = $true; $nFix = [int]$Matches[1]; $nDrop = [int]$Matches[2]; "reparo PS: $nFix reparado(s), $nDrop descartado(s) (esperado 2/0)" }
        if (-not $okFix -and $t -match 'retomado: (\d+) reparada\(s\), (\d+) corrompida') { $okFix = $true; $nFix = [int]$Matches[1]; $nDrop = [int]$Matches[2]; "reparo engine: $nFix reparada(s), $nDrop ignorada(s) (esperado 2/0)" }
    }
    if (-not $okLoad) { throw 'conversa nao carregou' }
    if (-not $okFix) { throw 'log de reparo nao apareceu (nem PS nem engine)' }
    if ((Read-New $mark2) -match 'retomou (\d+) msgs' -and [int]$Matches[1] -ne 4) { throw "msgs retomadas = $($Matches[1]), esperado 4" }
    if ($nFix -ne 2 -or $nDrop -ne 0) { throw "reparo = $nFix/$nDrop, esperado 2/0" }

    # 5) envia "oi" — tem que RESPONDER sem HTTP 400
    $mark3 = [IO.File]::ReadAllText($log).Length
    $inCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')
    $input = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $inCond)
    if (-not $input) { throw 'InputBox nao achado' }
    $input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('responda apenas: ok')
    $r = $input.Current.BoundingRectangle
    $null = [K.I]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
    [K.I]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [K.I]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    Tap 0x0D   # Enter
    $okSend = $false; $okDone = $false; $sawErr = $false
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and -not $okDone) {
        Start-Sleep -Milliseconds 500
        $t = Read-New $mark3
        if (-not $okSend -and $t -match 'envio: (\d+) chars') { $okSend = $true; "enviado ($($Matches[1]) chars)" }
        if ($t -match 'engine: HTTP 4') { $sawErr = $true; "ERRO HTTP no turno: $($Matches[0])"; break }
        if ($t -match 'respondido: (\d+) chars') { $okDone = $true; "respondido: $($Matches[1]) chars" }
    }
    if (-not $okSend) { throw 'envio nao apareceu no log' }
    if ($sawErr) { throw 'API rejeitou o corpo (400) — fix NAO funciona' }
    if (-not $okDone) { throw 'sem respondido: em 120s' }
    'VEREDITO: OK (corrompido em disco -> retomado+reparado -> resposta sem 400)'
} finally {
    # limpeza: conversa nova + esconde + remove arquivo de teste
    try { Combo 0x11 0x4E; Start-Sleep -Milliseconds 400; Tap 0x1B } catch {}
    try { Remove-Item $testFile -Force -ErrorAction Stop; "limpeza: arquivo de teste removido" } catch { "limpeza: FALHOU -> $testFile" }
}
