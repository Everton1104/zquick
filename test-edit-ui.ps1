# test-edit-ui.ps1 — E2E da tool file_edit (Onda 2):
#   fixture com linha unica -> pedir a troca -> confirmar vendo o diff ->
#   arquivo alterado + .zquick.bak com a versao anterior
# Rodar com: pwsh -STA -File test-edit-ui.ps1   (app residente rodando)
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
function Invoke-ById($win, [string]$id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $el) { throw "elemento '$id' nao encontrado via UIA" }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $el
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

$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }

$fix = Join-Path $env:TEMP ('zquick-editest-' + (Get-Date -Format 'HHmmss'))
$target = Join-Path $fix 'config-notas.txt'
try {
    New-Item -ItemType Directory -Force $fix | Out-Null
    Set-Content -Path $target -Value "# configuracao do servico`nporta = 8080`nhost = localhost" -Encoding utf8

    $w = $null
    for ($try = 0; $try -lt 4 -and -not $w; $try++) { Combo 0x12 0x51; Start-Sleep -Milliseconds 900; $w = Get-MainWin $app.ProcessId }
    if (-not $w) { throw 'janela do zquick nao apareceu' }

    $tb = Set-InputText $w "use a ferramenta file_edit no arquivo $target para trocar exatamente o texto 'porta = 8080' por 'porta = 9090'"
    Click-Center $tb
    Tap 0x0D
    $mark = [IO.File]::ReadAllText($log).Length

    if (-not (Wait-Log $mark 'confirma: Editar arquivo' 90)) { throw "confirmacao de edicao nao apareceu. log: $(Read-New $mark)" }
    $null = Invoke-ById $w 'ConfirmYes'
    $done = Wait-Log $mark 'respondido: ' 120
    if (-not $done) { throw "sem resposta. log: $(Read-New $mark)" }
    if ($done -match 'engine: ') { throw "erro do engine: $done" }

    $after = [IO.File]::ReadAllText($target)
    if ($after -notmatch 'porta = 9090') { throw "arquivo nao foi alterado. conteudo: $after" }
    if ($after -match 'porta = 8080') { throw "valor antigo ainda presente. conteudo: $after" }
    $bak = $target + '.zquick.bak'
    if (-not (Test-Path $bak)) { throw 'backup .zquick.bak nao foi criado' }
    $bakTxt = [IO.File]::ReadAllText($bak)
    if ($bakTxt -notmatch 'porta = 8080') { throw "backup nao guardou a versao anterior. conteudo: $bakTxt" }
    "PASS: file_edit E2E — arquivo editado, backup .zquick.bak com versao anterior"
} finally {
    Start-Sleep -Milliseconds 400; Tap 0x1B; Start-Sleep -Milliseconds 500; Combo 0x12 0x51
    Remove-Item $fix -Recurse -Force -ErrorAction SilentlyContinue
}
