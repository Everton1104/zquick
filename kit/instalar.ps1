# Instalador do ZQuick (executado pelo INSTALAR.cmd com Windows PowerShell).
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dst = Join-Path $env:LOCALAPPDATA 'Programs\ZQuick'
New-Item -ItemType Directory -Force $dst | Out-Null

Copy-Item (Join-Path $src 'zquick.exe') $dst -Force
Copy-Item (Join-Path $src 'zquick.ico') $dst -Force
Copy-Item (Join-Path $src 'LEIA-ME.txt') $dst -Force
Copy-Item (Join-Path $src 'MANUAL.txt') $dst -Force
# config: instala o modelo so na 1a vez (reinstalar nao apaga sua chave)
if (-not (Test-Path (Join-Path $dst 'zquick.json'))) {
    Copy-Item (Join-Path $src 'zquick.json') $dst -Force
}

# skills (Onda 5): playbooks .md — copia os exemplos sem sobrescrever os do usuario
$srcSkills = Join-Path $src 'skills'
if (Test-Path $srcSkills) {
    $dstSkills = Join-Path $dst 'skills'
    New-Item -ItemType Directory -Force $dstSkills | Out-Null
    Get-ChildItem $srcSkills -Filter *.md -File | ForEach-Object {
        $t = Join-Path $dstSkills $_.Name
        if (-not (Test-Path $t)) { Copy-Item $_.FullName $t -Force }
    }
}

# commands (Onda 8): slash commands .md — copia os exemplos sem sobrescrever
$srcCmds = Join-Path $src 'commands'
if (Test-Path $srcCmds) {
    $dstCmds = Join-Path $dst 'commands'
    New-Item -ItemType Directory -Force $dstCmds | Out-Null
    Get-ChildItem $srcCmds -Filter *.md -File | ForEach-Object {
        $t = Join-Path $dstCmds $_.Name
        if (-not (Test-Path $t)) { Copy-Item $_.FullName $t -Force }
    }
}

# atalho na Inicializacao NAO e' mais criado aqui: o assistente de configuracao
# (abre sozinho na 1a execucao) pergunta se voce quer iniciar com o Windows e
# grava a chave Run — quem ja' tinha o atalho antigo continua funcionando.

Write-Host ''
Write-Host 'ZQuick instalado em:' $dst -ForegroundColor Green
Write-Host ''

Write-Host 'Iniciando ZQuick...' -ForegroundColor Green
Start-Process (Join-Path $dst 'zquick.exe')
Write-Host ''
Write-Host 'O ASSISTENTE DE CONFIGURACAO abre sozinho na primeira execucao:'
Write-Host '  - escolha o provedor (Z.ai/Kimi/DeepSeek... ou LLM LOCAL:'
Write-Host '    Ollama / LM Studio / llama.cpp com o servidor rodando)'
Write-Host '  - cole a chave (opcional p/ servidor local) e teste a conexao'
Write-Host '  - ele lista os modelos, mede a velocidade e recomenda rapido/forte'
Write-Host '  - pergunta se inicia com o Windows e confere o atalho Alt+Q'
Write-Host ''
Write-Host 'Atalho: Alt+Q.'
