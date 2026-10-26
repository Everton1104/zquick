# Valida a sintaxe PowerShell do zquick.ps1 na GRAMATICA do 5.1.
# O repo guarda o arquivo como UTF-8 SEM BOM (o PS2EXE/exe le com UTF-8
# do .NET, e o pwsh 7 tambem) — Parser::ParseFile do 5.1 sem BOM decodifica
# como ANSI e explode mojibake. Decodifica certo e usa ParseInput.
$t = $null; $e = $null
$p = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'zquick.ps1'
$src = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
$null = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$t, [ref]$e)
if ($e) { $e | ForEach-Object { "ERR5.1 linha $($_.Extent.StartLineNumber): $($_.Message)" } } else { 'parse 5.1 OK' }
