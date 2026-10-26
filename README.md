# ZQuick

Assistente rápido residente no Windows, estilo Copilot Quick View.
Uma janela compacta sempre à mão (**Alt+Q**) que responde em streaming,
busca na web, lê prints e arquivos (PDF, DOCX, texto/código), guarda o
histórico de conversas e **age no Windows** — sessão PowerShell
persistente, edição cirúrgica com diff, planos aprovados em lote —
sempre com autorização explícita para o que altera algo.

Escrito em **PowerShell + WPF** num único arquivo (`zquick.ps1`, com engine
C# embutido via `Add-Type`), compatível com Windows PowerShell 5.1 e pwsh 7+.
Zero dependências: o exe é gerado com PS2EXE e roda em qualquer Windows.

Funciona com qualquer provedor de LLM compatível com a **API Anthropic**
(`/v1/messages`) — Z.ai, Kimi, DeepSeek — ou com um **LLM local**
(Ollama, LM Studio, llama.cpp) rodando na própria máquina.

## Instalar

1. Baixe o `ZQuick-x.y.z.msi` da página de **releases** e dê dois cliques.
   Instala por usuário (não pede administrador), com assistente em
   português: boas-vindas → **termos de uso** → pasta → **chave da API
   (opcional)** — cole a chave do provedor aí e o ZQuick já abre
   funcionando (ele configura o perfil e varre os modelos sozinho). No
   fim, marque **"Iniciar o ZQuick agora"**.
2. Deixou a chave em branco? O **assistente de configuração** abre sozinho
   na primeira execução:
   - **Conexão**: escolha o provedor (Z.ai / Kimi / DeepSeek ou
     🖥 Ollama / 🖥 LM Studio / 🖥 llama.cpp para LLM **local** — chave
     opcional), cole a chave e clique em *Testar conexão* (ele lista os
     modelos disponíveis);
   - **Velocidade**: mede o tempo de resposta de cada modelo e recomenda
     ⚡ rápido / 🧠 forte / 👁 visão;
   - **Preferências**: iniciar com o Windows, atalho de abrir;
   - **Concluir**. Pronto — **Alt+Q**.
3. Sem MSI: copie a pasta `kit/` e rode `INSTALAR.cmd`.

Guia rápido: `kit/LEIA-ME.txt` · Manual completo (agente, MCP, skills,
temas, config avançada): `kit/MANUAL.txt` · Notas de engenharia e
histórico de versões: `NOTAS-DESENVOLVIMENTO.md`.

## Recursos (resumo)

**Consulta** — streaming com fontes clicáveis `[1] [2]` · busca web
(`zai-server` server-side, preferida; `bing` cliente; `zai`) · modo
**auto** flash⇄grande com escalada · prompt cache · visão (prints) ·
anexos PDF/DOCX/texto via Ctrl+V ou arraste · histórico retomável com
as imagens · medidor de contexto + compactação oferecida · `@menção`
abre o seletor de arquivos do Windows.

**Agente Windows** — `file_list/read/grep` (leitura livre) ·
`file_edit` com **diff** vermelho/verde e backup · `file_write/move/
delete` (Lixeira) · `run_ps` em **sessão persistente** por conversa ·
`note_add` · `memory_save` (fatos duráveis) · confirmações ✅/✔
Sempre/✕ (45s) · **modo plano** (aprova 3+ ações de uma vez) ·
`ask_user` multi-pergunta com preview · tools de leitura em
**paralelo** · cliente **MCP** stdio (`mcpServers` no json) ·
**subagente de leitura** (`research`) · **skills** `.md` em `skills\` ·
**hooks** (`PreToolUse` nega/aprova por política, `PostToolUse`/`TurnEnd`
observadores) · **slash commands** do usuário (`commands\nome.md` →
`/nome args`) · **fallback de modelo** no meio do turno (model → fast →
big → `modelFallback`) · `todo_write` + painel 📋 · `git_status/diff/
log/commit`.

**Janela** — ⚙ de configurações (4 abas) com **15 cores do tema**
repintando ao vivo · escala global de fonte · moldura própria
— ▢ ✕ com ocultar-para-bandeja · tamanho/posição memorizados ·
📌 sempre no topo · Ctrl+roda = opacidade (transparência real) ·
⏹ Parar · fila de mensagens ✉ durante a resposta · retry com backoff.

## Rodar / Build / Testes

```powershell
pwsh -STA -File zquick.ps1                 # direto (aceita 5.1)
pwsh -STA -WindowStyle Hidden -File zquick.ps1 -Hidden   # residente
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1   # exe (PS2EXE)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-msi.ps1   # instalador MSI (WiX)
pwsh -STA -File check-engine.ps1           # engine nos 2 runtimes
```

Testes: `test-*.ps1` (engine headless + E2E de UI via UIA, app rodando;
oráculo = `%TEMP%\zquick.log`). Lista completa em
`NOTAS-DESENVOLVIMENTO.md`.

## Config (zquick.json)

| Chave | Default | O que faz |
|---|---|---|
| `searchEngine` | `bing` | `zai-server` (server-side, recomendado) · `bing` · `zai` |
| `promptCache` | `true` | cache_control no system+tools |
| `hotkey` / `maxTokens` / `hideOnBlur` | `alt+q` / 4096 / false | atalho, teto da resposta, fechar ao perder foco |
| `windowOpacity` / `theme` | 1.0 / — | opacidade (Ctrl+roda também ajusta) e paleta (15 chaves hex) |
| `alwaysOnTop` | `false` | 📌 janela sobre as outras |
| `window` | 860×600, centro | `width,height,x,y` memorizados + `center` |
| `answerFont` / `answerFontSize` | — / 13 | fonte do texto; tamanho 13 = 100% — **escala a interface toda** (10–22) |
| `allow` | — | `runPs` (comandos exatos) e `paths` (pastas) do "✔ Sempre" |
| `mcpServers` | — | `{ nome: { command, args[] } }` — servidores MCP stdio (tools viram `mcp_*`) |
| `hooks` | — | `{PreToolUse:[{tool,run}],PostToolUse:[…],TurnEnd:[{run}]}` — `tool:"*"` casa tudo; hook exit 2 = nega (stdout vira motivo pro modelo), exit 0 = aprova por política (pula a confirmação); recebe JSON no stdin |
| `modelFallback` | — | `["modelo-x", …]` — extras na cadeia de fallback após fast/big |
| `profiles.{nome}` | — | `label, baseUrl, apiKey, fastModel, bigModel, visionModel, models[]` — o assistente cria o perfil `local` para LLM local |

A chave da API fica no perfil do `zquick.json` ou em
`~/.claude/settings.json` (`env.ANTHROPIC_AUTH_TOKEN`).

| Arquivo | O que é |
|---|---|
| `zquick.ps1` | o app inteiro (fonte) |
| `zquick.json` | config (não vai para o git) |
| `build-exe.ps1` / `build-msi.ps1` | gera `zquick.exe` (PS2EXE) / instalador MSI (WiX) |
| `check-engine.ps1` | valida o engine C# no pwsh 7 e no 5.1 |
| `kit/` | kit de distribuição: INSTALAR/DESINSTALAR, LEIA-ME, MANUAL, template de config |
| `commands/` | slash commands do usuário: `nome.md` vira `/nome args` (`$ARGUMENTS` = resto da linha) |
| `skills/` | skills `.md` lidas pelo modelo via `skill_read` |
| `test-*.ps1` | testes (engine headless + E2E de UI) |
| `NOTAS-DESENVOLVIMENTO.md` | arquitetura, versões e lições de engenharia |

Log de diagnóstico: `%TEMP%\zquick.log`.
