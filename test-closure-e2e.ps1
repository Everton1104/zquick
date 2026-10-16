# test-closure-e2e.ps1 - v3.11: turno que bate o teto de rodadas (maxRounds=2 na
# config) com tools pendentes TEM que devolver texto final (rodada de fechamento
# sem tools). Cenario real do bug 16/10: tools executavam, turno morria no teto,
# status "pronto" sem resposta nenhuma.
# Prompt usa 2 tools SEQUENCIAIS (file_list -> file_read do mais recente) para
# garantir 2 rodadas de tool_use antes do teto. ASCII-only (5.1/ANSI).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
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

# acha o processo e a janela
$app = Get-Process zquick -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) { throw 'processo zquick nao achado' }
$procId = $app.Id; "pid: $procId"
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
$win = $null
for ($try = 0; $try -lt 4 -and -not $win; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    $win = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) | Where-Object { $_.Current.Name -like '*ZQuick*' -and $_.Current.Name -notlike '*hist*' } | Select-Object -First 1
}
if (-not $win) { throw 'janela nao achada' }
'janela ok'

# envia o prompt (tools sequenciais obrigatorias)
$mark = [IO.File]::ReadAllText($log).Length
$inCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InputBox')
$input = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $inCond)
if (-not $input) { throw 'InputBox nao achado' }
$prompt = 'Use file_list na pasta C:\Users\EVTU-DELL\.local\bin\zquick\history. Depois, com file_read, abra o arquivo de conversa MAIS RECENTE da lista e me diga quantos itens tem o array "msgs" dele. As duas ferramentas sao obrigatorias e sequenciais (a segunda precisa do nome que a primeira devolver).'
$input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($prompt)
$r = $input.Current.BoundingRectangle
$null = [K.I]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
[K.I]::mouse_event(2,0,0,0,[UIntPtr]::Zero); [K.I]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 300
Tap 0x0D
'enviado'

# espera: file_list + file_read executarem, teto bater, fechamento responder
$done = $false; $sawClose = $false; $sawErr = $false; $nChars = -1
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline -and -not $done) {
    Start-Sleep -Milliseconds 800
    $t = Read-New $mark
    if ($t -match 'engine: HTTP') { $sawErr = $true; "ERRO HTTP: $($Matches[0])"; break }
    if ($t -match 'fechando o turno') { $sawClose = $true; 'fechamento disparou (teto atingido)' }
    if ($t -match 'respondido: (\d+) chars em (\d+)s \| (.*)') {
        $nChars = [int]$Matches[1]
        $done = $true
        "respondido: $($Matches[1]) chars em $($Matches[2])s"
        "preview: $($Matches[3])"
    }
}
if ($sawErr) { throw 'turno terminou em erro HTTP' }
if (-not $done) { throw 'sem respondido em 180s' }
if (-not $sawClose) { throw 'teto de rodadas NAO foi atingido (teste inconclusivo — modelo respondeu antes)' }
if ($nChars -lt 10) { throw "resposta final vazia/curta demais ($nChars chars) - fechamento nao entregou texto" }

# limpeza: nova conversa + esconde
Combo 0x11 0x4E; Start-Sleep -Milliseconds 400; Tap 0x1B
"VERDICTO: OK (teto de rodadas -> fechamento sem tools -> resposta final de $($nChars) chars)"
