# test-scroll-ui.ps1 — E2E do v3.22: seta do ComboBox a direita + scrollbar tematizada.
#   1. /uitest arrowpos  -> seta colada na borda direita (margem <= 12px, na metade direita).
#   2. /uitest scrollprobe -> largura/estilo/raio BATEM com o scrollStyle do json (consistencia,
#      sem depender da cor viva do usuario): pill=8px/custom/raio 3, square=8px/custom/raio 0,
#      classic=custom=False.
#   3. ⚙->Aparência: 15 linhas de cor (a nova 'Barra de rolagem' é a ultima), troca cor p/
#      #78FA82 + estilo 'fino reto' -> Aplicar -> json grava (theme.scroll + scrollStyle=square)
#      + status avisa 'vale ao reiniciar'.
#   4. scrollprobe SEM reiniciar -> cor #78FA82 (cor aplica AO VIVO; estilo so ao reiniciar).
#   5. restaura cor/estilo originais via ⚙, fecha sem FATAL.
# Rodar com: pwsh -STA -File test-scroll-ui.ps1   (app dev rodando; scrollStyle qualquer)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$log = Join-Path $env:TEMP 'zquick.log'
$rl = [string][char]0x27F2   # seta anti-horaria do botao de reset por cor
$cls = 'cl' + [char]0xE1 + 'ssico do Windows'   # item do combo (acento via codigo; arquivo ASCII)
$cfgPath = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json'
function Read-LogText {
    $fs = [IO.FileStream]::new($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
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
function Find-ById($win, [string]$id) {
    # retry: durante stream intenso o UI thread nao bombeia UIA e FindFirst da timeout
    for ($t = 0; $t -lt 6; $t++) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
            return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        } catch { Start-Sleep -Milliseconds 700 }
    }
    throw "UIA nao respondeu procurando '$id' (UI thread ocupado?)"
}
function Invoke-ById($win, [string]$id) {
    $el = Find-ById $win $id
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $el
}
function Get-MainWin([int]$procId) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    foreach ($w in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($w.Current.Name -like '*ZQuick*' -and $w.Current.Name -notlike '*hist*') { return $w }
    }
    $null
}
function Find-Wins([int]$procId) {
    # dialogos com Owner sao FILHOS da janela dona na UIA (licao v3.20)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    $all = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))
    $mw = $all | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
    if ($mw) { $all += @($mw.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) }
    return @($all)
}
function Click-Invoke($el) {
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 300
}
function Send-Line($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $p = $tb.GetClickablePoint()
    $null = Set-CursorPos2 ([int]$p.X) ([int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M2]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M2]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
}
Add-Type -Namespace K -Name M2 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
'@
function Get-HexEdits($sw) {
    $ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec)) | Where-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -match '^#[0-9A-Fa-f]{6}$' }
}
function Get-Val($el) { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
function Set-Val($el, [string]$v) { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($v) }
function Select-ComboItem($cbEl, [string]$name) {
    $cbEl.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Start-Sleep -Milliseconds 400
    $lic = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $li = @($cbEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $lic)) | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
    if (-not $li) { throw "item '$name' nao esta na lista do combo" }
    $li.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 300
    try { $cbEl.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch {}
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | log: $ctx" } }

# ---- estado original do json (restaurado no fim; app nao pode salvar por cima depois) ----
$j0 = Get-Content $cfgPath -Raw | ConvertFrom-Json
$ss0 = [string]$j0.scrollStyle; if (-not $ss0) { $ss0 = 'pill' }
$cor0 = '#50505C'
try { if ($j0.theme -and $j0.theme.scroll) { $cor0 = ([string]$j0.theme.scroll).ToUpper() } } catch {}
"estado original: scrollStyle=$ss0 scroll=$cor0"

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

try {
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
            if (-not (Wait-Log $m0 'respondido: ' 90)) { throw 'Parar nao fechou o turno no cleanup' }
            Start-Sleep -Milliseconds 400; continue
        }
        break
    }

    # ---- fase 1: seta do ComboBox a direita ----
    $mark = (Read-LogText).Length
    Send-Line $w '/uitest arrowpos'
    $hit = Wait-Log $mark 'arrowpos: ' 15
    if (-not $hit) { throw "fase 1: arrowpos nao logou. log: $((Read-LogText).Substring($mark))" }
    $line = ($hit -split "`n" | Where-Object { $_ -match 'arrowpos' } | Select-Object -Last 1)
    $line -match 'combo (\d+)px, seta x=(\d+)\.\.(\d+) \(margem direita (\d+)px' | Out-Null
    $cw = [int]$Matches[1]; $ax1 = [int]$Matches[2]; $ax2 = [int]$Matches[3]; $mrg = [int]$Matches[4]
    Assert ($mrg -le 12 -and $ax2 -le $cw) "seta nao esta colada na direita (combo ${cw}px, seta x=$ax1..$ax2, margem $mrg" $line
    Assert ($ax1 -gt ($cw / 2)) 'seta continua na metade esquerda/centro' $line
    "PASS fase 1: seta a direita (combo ${cw}px, seta x=$ax1..$ax2, margem $mrg)"

    # ---- fase 2: scrollbar casa com o scrollStyle do json ----
    $mark = (Read-LogText).Length
    Send-Line $w '/uitest scrollprobe'
    $hit = Wait-Log $mark 'scrollprobe: ' 15
    if (-not $hit) { throw "fase 2: scrollprobe nao logou. log: $((Read-LogText).Substring($mark))" }
    $sp = ($hit -split "`n" | Where-Object { $_ -match 'scrollprobe' } | Select-Object -Last 1)
    $sp -match 'largura da 1a=([\d.,-]+)px .*estilo custom=(True|False); cor=([^;]+); bg da barra=([^;]+); raio=(\S+)' | Out-Null
    $w1 = [double]($Matches[1] -replace ',', '.'); $cust = $Matches[2]; $cor = $Matches[3]; $bg = $Matches[4]; $raio = $Matches[5]
    switch ($ss0) {
        'pill'    { Assert ($w1 -le 9 -and $cust -eq 'True' -and $raio -eq '3') "esperava 8px/custom/raio 3 (pill); veio ${w1}px/$cust/raio $raio" $sp }
        'square'  { Assert ($w1 -le 9 -and $cust -eq 'True' -and $raio -eq '0') "esperava 8px/custom/raio 0 (square); veio ${w1}px/$cust/raio $raio" $sp }
        'classic' { Assert ($cust -eq 'False') 'esperava custom=False (classic)' $sp }
    }
    if ($cust -eq 'True') { Assert ($cor -eq $cor0) "cor da barra ($cor) nao casa com o tema do json ($cor0)" $sp }
    "PASS fase 2: estilo '$ss0' consistente ($sp)"

    # ---- fase 3: ⚙ -> Aparência: 15 linhas, troca cor + estilo, Aplicar grava ----
    $mark = (Read-LogText).Length
    $null = Invoke-ById $w 'SettingsBtn'
    $sw = $null; $dl = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $dl -and -not $sw) {
        Start-Sleep -Milliseconds 400
        $sw = Find-Wins $app.ProcessId | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1
    }
    if (-not $sw) { throw 'fase 3: configuracoes nao abriram' }
    $tc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
    if (-not $tab) { throw 'fase 3: aba Aparencia nao achada' }
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 700

    # 15 linhas de cor (v3.22 adicionou 'Barra de rolagem') — reset buttons provam
    $bc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $rlBtns = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) | Where-Object { $_.Current.Name -eq $rl }
    Assert ($rlBtns.Count -eq 15) "esperava 15 botoes reset, achei $($rlBtns.Count)" ''
    $hexEdits = @(Get-HexEdits $sw)
    Assert ($hexEdits.Count -ge 15) "esperava >=15 hex, achei $($hexEdits.Count)" ''
    $scrollBox = $hexEdits[-1]           # scroll e' a ultima chave de cor
    Assert ((Get-Val $scrollBox).ToUpper() -eq $cor0) "hex da rolagem mostra $(Get-Val $scrollBox), esperava $cor0" ''

    $cb = Find-ById $sw 'SetScrollStyle'
    Select-ComboItem $cb 'fino reto'
    Set-Val $scrollBox '#78FA82'
    $mark = (Read-LogText).Length
    $null = Invoke-ById $sw 'SetApply'
    $hit = Wait-Log $mark 'config: aplicado' 15
    if (-not $hit) { throw "fase 3: Aplicar nao logou. log: $((Read-LogText).Substring($mark))" }
    $stEl = Find-ById $sw 'SetStatus'
    Assert ($stEl.Current.Name -match 'vale ao reiniciar') "status nao avisou do reinicio: '$($stEl.Current.Name)'" ''
    $j1 = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Assert ([string]$j1.scrollStyle -eq 'square') "json scrollStyle=$($j1.scrollStyle), esperava square" ''
    Assert ((([string]$j1.theme.scroll)).ToUpper() -eq '#78FA82') "json theme.scroll=$($j1.theme.scroll), esperava #78FA82" ''
    $null = Invoke-ById $sw 'SetClose'
    Start-Sleep -Milliseconds 500
    Assert (Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' }) 'processo morreu apos fechar ⚙' ''
    "PASS fase 3: 15 linhas, estilo+cor gravados no json, aviso de reinicio"

    # ---- fase 4: cor aplica AO VIVO (sem reiniciar; estilo fica pro proximo boot) ----
    $mark = (Read-LogText).Length
    Send-Line $w '/uitest scrollprobe'
    $hit = Wait-Log $mark 'scrollprobe: ' 15
    if (-not $hit) { throw "fase 4: scrollprobe nao logou. log: $((Read-LogText).Substring($mark))" }
    $sp = ($hit -split "`n" | Where-Object { $_ -match 'scrollprobe' } | Select-Object -Last 1)
    if ($ss0 -ne 'classic') {
        Assert ($sp -match 'cor=#78FA82') "cor AO VIVO nao aplicou (esperava #78FA82): $sp" $sp
    } else {
        # janela parseada como classico nao tem ZScrollBrush; cor viva nao se aplica — ok
        Assert ($sp -match 'estilo custom=False') 'classic deveria seguir sem brush' $sp
    }
    "PASS fase 4: cor viva ($sp)"

    # ---- fase 5: restaura cor/estilo originais e fecha limpo ----
    $mark = (Read-LogText).Length
    $null = Invoke-ById $w 'SettingsBtn'
    $sw = $null; $dl = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $dl -and -not $sw) {
        Start-Sleep -Milliseconds 400
        $sw = Find-Wins $app.ProcessId | Where-Object { $_.Current.Name -like '*configura*' } | Select-Object -First 1
    }
    if (-not $sw) { throw 'fase 5: configuracoes nao reabriram' }
    $tab = @($sw.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)) | Where-Object { $_.Current.Name -like '*Apar*' } | Select-Object -First 1
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 700
    $hexEdits = @(Get-HexEdits $sw)
    $scrollBox = $hexEdits[-1]
    Set-Val $scrollBox $cor0
    $cb = Find-ById $sw 'SetScrollStyle'
    $lbl = $(switch ($ss0) { 'square' { 'fino reto' }; 'classic' { $cls }; default { 'fino arredondado' } })
    Select-ComboItem $cb $lbl
    $mark = (Read-LogText).Length
    $null = Invoke-ById $sw 'SetApply'
    if (-not (Wait-Log $mark 'config: aplicado' 15)) { throw "fase 5: Aplicar restaurador nao logou. log: $((Read-LogText).Substring($mark))" }
    $null = Invoke-ById $sw 'SetClose'
    Start-Sleep -Milliseconds 500
    $j2 = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Assert ([string]$j2.scrollStyle -eq $ss0) "json scrollStyle=$($j2.scrollStyle), esperava $ss0" ''
    $corNow = '#50505C'
    try { if ($j2.theme -and $j2.theme.scroll) { $corNow = ([string]$j2.theme.scroll).ToUpper() } } catch {}
    Assert ($corNow -eq $cor0) "json theme.scroll=$corNow, esperava $cor0" ''
    Assert (-not ((Read-LogText).Substring($mark) -match 'FATAL')) 'FATAL no log' ''
    "PASS fase 5: estado restaurado (scrollStyle=$ss0, scroll=$cor0), sem FATAL"

    'VERDICTO: OK (seta a direita + scrollbar tematizada: cor ao vivo, estilo persistido)'
} finally {
    # se algo explodir com o ⚙ aberto, Esc fecha; esconde a janela
    for ($i = 0; $i -lt 2; $i++) { Tap 0x1B; Start-Sleep -Milliseconds 300 }
    Start-Sleep -Milliseconds 400
    try { Combo 0x12 0x51 } catch {}
}
