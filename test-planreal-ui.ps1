# test-planreal-ui.ps1 — E2E T6 (Onda 3): modo plano REAL com o modelo.
#   Pede criacao de 2 arquivos na Desktop usando a tool plan -> PlanBar aparece
#   com plano do modelo -> UIA PlanYes -> execucao SEM nenhuma ConfirmBar
#   ('confirma:' ausente no log do turno) -> arquivos existem -> limpeza.
#   Ao fim confere que 'allow' do zquick.json seguiu vazio (plano nao grava regra).
# Rodar com: pwsh -STA -File test-planreal-ui.ps1   (app residente rodando)
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
function Send-Line($win, [string]$text) {
    $tb = Find-ById $win 'InputBox'
    if (-not $tb) { throw 'InputBox nao encontrado' }
    $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    $p = $tb.GetClickablePoint()
    $null = [K.M]::SetCursorPos([int]$p.X, [int]$p.Y)
    Start-Sleep -Milliseconds 80
    [K.M]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [K.M]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Tap 0x0D
}
function Assert([bool]$cond, [string]$msg, [string]$ctx) { if (-not $cond) { throw "FALHOU: $msg | log: $ctx" } }

$desk = [Environment]::GetFolderPath('Desktop')
$fa = Join-Path $desk 'zq-plano-a.txt'
$fb = Join-Path $desk 'zq-plano-b.txt'
# estado 'allow' antes (plano NAO pode gravar regra de 'sempre permitir')
$cfgPath = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.json'
$allowBefore = (Get-Content $cfgPath -Raw | ConvertFrom-Json).allow | ConvertTo-Json -Compress -Depth 4

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

try {
    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    $mark = [IO.File]::ReadAllText($log).Length
    Send-Line $w "use a ferramenta plan para me mostrar um plano e, depois que eu aprovar, crie DOIS arquivos na minha Desktop: zq-plano-a.txt (conteúdo: plano a ok) e zq-plano-b.txt (conteúdo: plano b ok)."
    $plan = Wait-Log $mark 'plano: .+\(\d+ passos\)' 90
    if (-not $plan) { throw "modelo nao propôs plano. log: $(Read-New $mark)" }
    "plano proposto: $($plan -split "`n" | Where-Object { $_ -match 'plano:' } | Select-Object -First 1)"

    $py = Find-ById $w 'PlanYes'
    if (-not $py) { throw 'botao PlanYes nao encontrado (PlanBar nao visivel?)' }
    $py.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 400

    $turn = Wait-Log $mark 'respondido: ' 180
    if (-not $turn) { throw "turno nao terminou. log: $(Read-New $mark)" }
    Assert ($turn -match 'plano: aprovado') 'plano nao foi aprovado no log' $turn
    # a isencao em lote vale DEPOIS da aprovacao; acoes de exploracao antes do
    # plano (run_ps p/ achar a Desktop etc.) podem confirmar normalmente
    $after = $turn.Substring($turn.IndexOf('plano: aprovado'))
    Assert ($after -notmatch 'confirma:') 'apareceu ConfirmBar DEPOIS do plano aprovado (devia rodar em lote)' $turn
    Assert ($turn -notmatch 'engine: ') 'erro do engine' $turn
    Assert (Test-Path $fa) "arquivo A nao criado ($fa)" $turn
    Assert (Test-Path $fb) "arquivo B nao criado ($fb)" $turn
    $ca = Get-Content $fa -Raw; $cb = Get-Content $fb -Raw
    Assert ($ca -match 'plano a') "conteudo A errado: $ca" $turn
    Assert ($cb -match 'plano b') "conteudo B errado: $cb" $turn

    $allowAfter = (Get-Content $cfgPath -Raw | ConvertFrom-Json).allow | ConvertTo-Json -Compress -Depth 4
    Assert ($allowAfter -eq $allowBefore) "allow mudou no zquick.json (antes=$allowBefore depois=$allowAfter)" $turn

    "PASS: plan real E2E — aprovado 1x, 2 arquivos criados sem confirmação individual"
} finally {
    foreach ($f in @($fa, $fb, "$fa.zquick.bak", "$fb.zquick.bak")) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Milliseconds 400; Combo 0x11 0x4E; Start-Sleep -Milliseconds 500; Tap 0x1B; Start-Sleep -Milliseconds 500; Combo 0x12 0x51
}
