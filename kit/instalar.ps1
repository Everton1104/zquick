# Instalador do ZQuick (executado pelo INSTALAR.cmd com Windows PowerShell).
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dst = Join-Path $env:LOCALAPPDATA 'Programs\ZQuick'
New-Item -ItemType Directory -Force $dst | Out-Null

Copy-Item (Join-Path $src 'zquick.exe') $dst -Force
Copy-Item (Join-Path $src 'zquick.ico') $dst -Force
# config: instala o modelo so na 1a vez (reinstalar nao apaga sua chave)
if (-not (Test-Path (Join-Path $dst 'zquick.json'))) {
    Copy-Item (Join-Path $src 'zquick.json') $dst -Force
}

# atalho na Inicializacao ( abre oculto no tray )
$lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\ZQuick.lnk'
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $dst 'zquick.exe'
$lnk.Arguments = '-Hidden'
$lnk.WorkingDirectory = $dst
$lnk.IconLocation = (Join-Path $dst 'zquick.exe') + ',0'
$lnk.Save()

Write-Host ''
Write-Host 'ZQuick instalado em:' $dst -ForegroundColor Green
Write-Host 'Inicia com o Windows (atalho na Inicializacao).' -ForegroundColor Green
Write-Host ''

# abre o config p/ colar a chave ANTES do primeiro uso
$cfg = Join-Path $dst 'zquick.json'
Write-Host 'Abrindo o zquick.json no Bloco de Notas...' -ForegroundColor Yellow
Write-Host 'Substitua COLE-AQUI-SUA-CHAVE-ZAI pela sua chave e salve.' -ForegroundColor Yellow
Start-Process notepad.exe $cfg
Start-Sleep 1

Write-Host 'Iniciando ZQuick (janela visivel)...' -ForegroundColor Green
Start-Process (Join-Path $dst 'zquick.exe')
Write-Host ''
Write-Host 'Atalho: Alt+Q.'
