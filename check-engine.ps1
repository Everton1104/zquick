# check-engine.ps1 — compila o C# do engine (extraido do zquick.ps1) no pwsh atual E no 5.1.
# Uso: pwsh -File check-engine.ps1
$ErrorActionPreference = 'Stop'
$src = Get-Content 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1' -Raw
$m = [regex]::Match($src, "(?s)\`$engineCs = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'engine Cs nao extraido do fonte' }
$cs = $m.Groups[1].Value

# 1) pwsh atual (.NET Core/10)
try { Add-Type -TypeDefinition $cs } catch { $_ | Out-String | Write-Host -ForegroundColor Red; exit 1 }
'engine C# OK (pwsh7)'

# 2) Windows PowerShell 5.1 (.NET Framework, com ReferencedAssemblies — como o app faz)
$csFile = Join-Path $env:TEMP 'zquick-engine-cs-check.cs'
[IO.File]::WriteAllText($csFile, $cs, (New-Object System.Text.UTF8Encoding $true))
$runner = Join-Path $env:TEMP 'zquick-engine-cs-check51.ps1'
@'
$cs = [IO.File]::ReadAllText($env:TEMP + '\zquick-engine-cs-check.cs')
$ref = @('System.dll','System.Core.dll','System.Net.Http.dll','Microsoft.CSharp.dll')
try { Add-Type -TypeDefinition $cs -ReferencedAssemblies $ref } catch { $_ | Out-String | Write-Host -ForegroundColor Red; exit 1 }
'engine C# OK (5.1/.NET Framework)'
'@ | Set-Content $runner -Encoding UTF8
powershell -NoProfile -ExecutionPolicy Bypass -File $runner
if ($LASTEXITCODE -ne 0) { throw 'falhou no 5.1' }
