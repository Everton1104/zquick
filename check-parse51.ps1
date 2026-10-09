$t = $null; $e = $null
$p = 'C:\Users\EVTU-DELL\.local\bin\zquick\zquick.ps1'
$null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e)
if ($e) { $e | ForEach-Object { "ERR5.1 linha $($_.Extent.StartLineNumber): $($_.Message)" } } else { 'parse 5.1 OK' }
