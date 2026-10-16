# test-engine-compile.ps1 - valida o C# do engine compilando no PowerShell 5.1
# (mesmo caminho do exe PS2EXE). Extrai o here-string engineCs do zquick.ps1 e
# faz Add-Type com as mesmas referencias. ASCII-only por causa do 5.1/ANSI.
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'zquick.ps1'))
$m = [regex]::Match($src, "(?s)\$engineCs = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'engineCs nao extraido' }
$cs = $m.Groups[1].Value
"engineCs extraido: $($cs.Length) chars"
Add-Type -TypeDefinition $cs -ReferencedAssemblies @('System.dll','System.Core.dll','Microsoft.CSharp.dll','System.Net.Http.dll')
'tipo ZQuick.Engine: ' + [ZQuick.Engine].FullName
'VERDICTO: OK (compila no 5.1)'
