# probe-bgcheck.ps1 — amostra pixels da janela do ZQuick AO VIVO (sem mexer em
# nada): Alt+Q abre, UIA dá o retângulo, CopyFromScreen amostra pontos do fundo.
# padrao bg=#202024 (com 85% de opacidade fica ~#1B1B1F sobre desktop escuro);
# matrix bg=#000000 (fica ~#000-#26 dependendo do desktop).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -Namespace K -Name I -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][K.I]::SetProcessDPIAware()
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
    for ($t = 0; $t -lt 6; $t++) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
            return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        } catch { Start-Sleep -Milliseconds 700 }
    }
    throw "UIA timeout '$id'"
}
$app = Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" | Where-Object { $_.CommandLine -like '*zquick.ps1*' } | Select-Object -First 1
if (-not $app) { throw 'zquick nao esta rodando' }
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$app.ProcessId)
$w = $null
for ($try = 0; $try -lt 6 -and -not $w; $try++) {
    Combo 0x12 0x51; Start-Sleep -Milliseconds 900
    foreach ($cand in @($root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))) {
        if ($cand.Current.Name -like '*ZQuick*' -and $cand.Current.Name -notlike '*hist*' -and (Find-ById $cand 'InputBox')) { $w = $cand }
    }
}
if (-not $w) { throw 'janela nao acessivel' }
$r = $w.Current.BoundingRectangle
"janela: L={0} T={1} W={2} H={3}" -f [int]$r.Left, [int]$r.Top, [int]$r.Width, [int]$r.Height
Start-Sleep -Milliseconds 400   # deixa o fade/render assentar
$L = [int]$r.Left; $T = [int]$r.Top; $W = [int]$r.Width; $H = [int]$r.Height
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($L, $T, 0, 0, $bmp.Size)
$g.Dispose()
function HexPx([System.Drawing.Bitmap]$b, [int]$x, [int]$y) { $c = $b.GetPixel($x, $y); '#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B }
$pts = [ordered]@{
    'caption esq (fundo)'   = @{ x = 15; y = 20 }
    'caption meio (fundo)'  = @{ x = [int]($W / 2); y = 12 }
    'logo cima (fundo)'     = @{ x = [int]($W / 2); y = 30 }
    'centro (area resp)'    = @{ x = [int]($W / 2); y = [int]($H * 0.45) }
    'rodape (fundo)'        = @{ x = [int]($W / 2); y = $H - 15 }
    'borda inferior'        = @{ x = 20; y = $H - 3 }
}
foreach ($k in $pts.Keys) {
    $p = $pts[$k]
    if ($p.x -ge 0 -and $p.x -lt $W -and $p.y -ge 0 -and $p.y -lt $H) {
        '{0,-24} @{1,4},{2,4}  {3}' -f $k, $p.x, $p.y, (HexPx $bmp $p.x $p.y)
    }
}
$bmp.Dispose()
'probe fim'
