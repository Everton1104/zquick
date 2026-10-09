# Desinstalador do ZQuick (executado pelo DESINSTALAR.cmd com Windows PowerShell).
$ErrorActionPreference = 'Continue'
Write-Host ''
Write-Host 'Desinstalando ZQuick...' -ForegroundColor Yellow
Write-Host ''

# 1. encerra o app: exe instalado, exe manual ou dev (pwsh rodando o .ps1)
Get-Process zquick -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name like 'pwsh%'" |
    Where-Object { $_.CommandLine -like '*zquick.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 2. remove da inicializacao (atalho do kit OU tarefa agendada de instalacoes dev)
$lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\ZQuick.lnk'
if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Host 'Atalho da Inicializacao removido.' }
Unregister-ScheduledTask -TaskName 'ZQuick' -Confirm:$false -ErrorAction SilentlyContinue

# 3. pasta do app (pergunta sobre conversas/config antes de apagar)
$dst = Join-Path $env:LOCALAPPDATA 'Programs\ZQuick'
if (Test-Path $dst) {
    $rsp = Read-Host 'Manter suas conversas e configuracao (S/N)? S = salva zquick.json e history na Area de Trabalho'
    if ($rsp -match '^[sS]') {
        $bak = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZQuick-backup'
        New-Item -ItemType Directory -Force $bak | Out-Null
        Copy-Item (Join-Path $dst 'zquick.json') $bak -Force -ErrorAction SilentlyContinue
        if (Test-Path (Join-Path $dst 'history')) { Copy-Item (Join-Path $dst 'history') $bak -Recurse -Force }
        Write-Host "Backup salvo em: $bak" -ForegroundColor Green
    }
    Remove-Item $dst -Recurse -Force
    Write-Host "Pasta removida: $dst" -ForegroundColor Green
} else {
    Write-Host 'Pasta do app nao encontrada (instalacao dev? remova manualmente o diretorio e a tarefa ZQuick).'
}

Write-Host ''
Write-Host 'ZQuick desinstalado.' -ForegroundColor Green
Write-Host 'Observacao: notas criadas pelo agente ficam em Documentos\ZQuick-Notas.'
Write-Host ''
