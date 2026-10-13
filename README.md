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
(`/v1/messages`) — perfis múltiplos no `zquick.json` (Z.ai, Kimi, ...).

## Recursos

**Consulta**
- Streaming com fontes clicáveis `[1] [2]`; modo **auto** flash⇄modelo
  grande (o próprio modelo decide escalar com `escalate`; pergunta de
  atualidade ou geração longa sobe direto)
- **Busca web** (`searchEngine`): `zai-server` = web_search **no servidor**
  (tool `web_search_20250305` no próprio `/v1/messages` — melhor qualidade,
  recency filter automático; **preferido**) · `bing` = cadeia cliente
  (Bing RSS → Bing HTML → web-search Z.ai) · `zai` = API de tools nativa
- **Prompt cache**: `cache_control` no system + tools (sonda Z.ai:
  1550 → 14 input tokens de entrada nas trocas seguintes)
- Visão (prints) via `visionModel` do perfil — no Z.ai quem lê imagem é
  o flash; o glm-5.3 grande não enxerga
- Anexos PDF (document block) / DOCX / texto; histórico retomável com
  as imagens de volta; compactação oferecida com aviso + **medidor de
  contexto** no rodapé
- **@menção**: `@` no começo de palavra abre o seletor de arquivos; o
  caminho entra no texto e o modelo lê com file_read/file_grep

**Agente Windows (tools)**
- Leitura livre: `file_list`, `file_read`, `file_grep` (busca de
  conteúdo recursiva, caps 50 matches/400 arquivos/8s)
- Muda algo = confirma na janela: `file_edit` (troca exata de trecho com
  **diff vermelho/verde**, backup `.zquick.bak`, verificação na
  re-leitura), `file_write`, `file_move`, `file_delete` (Lixeira)
- `run_ps` numa **sessão de shell persistente por conversa**: pasta
  atual, variáveis e funções criadas numa chamada existem na seguinte
- `note_add` (Documentos\ZQuick-Notas) e `memory_save` (fatos duráveis
  em `zquick-memory.md`, injetados no system de TODAS as conversas)
- Confirmação com ✅ Executar / **✔ Sempre** (allowlist persistida no
  json) / ✕ Negar, expira em 45s
- **Modo plano**: 3+ ações viram um plano (título + passos) aprovado
  UMA vez — executa tudo sem confirmações individuais
- **ask_user**: até 4 perguntas de uma vez, múltipla escolha ou texto
  livre, com preview mono lado a lado (código/mockup/config)
- **Tools de leitura em paralelo**: `web_search`, `fetch_page`,
  `file_list`, `file_read`, `file_grep` pedidas no mesmo round disparam
  juntas; os tool_results voltam na **ordem original** (ids casados) e
  escritas seguem seriais
- **MCP**: cliente mínimo stdio — servidores em `mcpServers` do
  `zquick.json`; tools externas ganham prefixo `mcp_<srv>_<tool>` e
  schema saneado (sem `pattern`); até 6 servidores × 40 tools, sobem no
  primeiro envio, processos encerrados ao sair/trocar perfil
- **Subagente de leitura** (`research`): agente com contexto próprio
  que não vê a conversa — investiga sozinho (até 6 rodadas, só
  leitura, tools em paralelo) e devolve um relatório como tool_result;
  a conversa principal fica limpa (só a conclusão entra nela); deltas/
  fontes/TTFT do sub suprimidos do card principal
- **Skills**: playbooks `.md` em `skills\` ao lado do app — nome e
  descrição (frontmatter `name:`/`description:`) listados no system
  (cap 20); `skill_read` carrega as instruções completas sob demanda;
  só entra nas tools quando existir pelo menos uma
- Botão **⏹ Parar** (parcial preservada), **fila de mensagens** durante
  a resposta, retry com backoff 1/3/8s (429/5xx/rede), watchdog de
  stream (120s sem dados corta o turno)

## Arquivos

| Arquivo | O que é |
|---|---|
| `zquick.ps1` | o app inteiro (fonte) |
| `zquick.json` | config: perfil/modelo, atalho, busca, cache, tema, opacidade, perfis, allowlist |
| `build-exe.ps1` | gera `zquick.exe` com PS2EXE (rodar com powershell.exe 5.1) |
| `check-engine.ps1` | valida o engine C# no pwsh 7 e no 5.1 (rodar com pwsh) |
| `kit/` | kit de distribuição: INSTALAR/DESINSTALAR, LEIA-ME e template de config |
| `test-*.ps1` | testes (engine headless + E2E de UI via keybd_event/UIA — rodar com `pwsh -STA`) |

## Rodar

```powershell
# direto (recomendado pwsh 7+; aceita 5.1)
pwsh -STA -File zquick.ps1

# residente oculto (como a tarefa de logon "ZQuick" faz)
pwsh -STA -WindowStyle Hidden -File zquick.ps1 -Hidden
```

A chave da API fica em `~/.claude/settings.json` (`env.ANTHROPIC_AUTH_TOKEN`)
ou direto no `zquick.json` do perfil.

## Config (zquick.json)

| Chave | Default | O que faz |
|---|---|---|
| `searchEngine` | `bing` | `zai-server` (server-side, recomendado) · `bing` · `zai` |
| `promptCache` | `true` | cache_control no system+tools |
| `hotkey` / `maxTokens` / `hideOnBlur` | `alt+q` / 4096 / false | atalho, teto da resposta, fechar ao perder foco |
| `windowOpacity` / `theme` | 1.0 / — | opacidade e paleta (15 chaves hex) |
| `allow` | — | `runPs` (comandos exatos) e `paths` (pastas) do "✔ Sempre" |
| `mcpServers` | — | `{ nome: { command, args[] } }` — servidores MCP stdio (tools viram `mcp_*`) |
| `profiles.{nome}` | — | `label, baseUrl, apiKey, fastModel, bigModel, visionModel, models[]` |

## Build do exe

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1
```

Requisitos do build: pasta `tools/ps2exe` (nupkg da PSGallery) — não vai
para o git; sem ela, o `.ps1` continua sendo o app completo.

## Testes

- Estáticos: `check-engine.ps1` (C# nos 2 runtimes), `test-xaml.ps1`
  (parse + FindName dos XAMLs), `test-surgery.ps1` (costura JSON da pré-busca)
- E2E de UI (app residente rodando; oráculo = `%TEMP%\zquick.log`):
  envio/visão/busca (`test-send/vision/search-ui`), agente e confirmações
  (`test-agent-e2e`, `test-always`, `test-edit`), teclas/histórico
  (`test-esc`, `test-reopen`, `test-hist-img`, `test-histbtn`, `test-close`),
  ondas — Parar/grep (`test-stop`, `test-grep`), memória/fila
  (`test-memory`, `test-queue`), ask/plan (`test-ask`, `test-panel`,
  `test-planreal`), shell persistente (`test-shell`), @menção
  (`test-atdialog`), busca server/cache (`test-zaiserver`, `test-zai-cache`),
  paralelo+MCP (`test-parallel-engine`, `test-mcp-engine` +
  fixture `test-mcp-server.ps1`, `test-par4-ui`), subagente/skills
  (`test-sub-engine` com API real, `test-skills-engine`, `test-wave5-ui`)

## Arquitetura em 1 parágrafo

UI WPF na thread STA; engine C# (`HttpClient`/SSE) em thread própria
comunicando-se por `ConcurrentQueue` drenada por `DispatcherTimer` de
80ms. Loop agêntico até 12 rodadas; `ExecTools` dispara as tools de
leitura em paralelo (fase A lança, fase B recolhe na ordem original —
escritas/gates seriais). A tool `research` roda um loop próprio
(`SubResearch`: até 6 rodadas + fechamento sem tools, histórico
separado, `_subDepth` suprime delta/fontes/TTFT do sub no card
principal). Skills são parseadas no PS (frontmatter) e entregues ao
engine via `SetSkills`. Servidores MCP vivem como processos filhos
stdio (JSON-RPC linha a linha, id casado na resposta; `initialize` →
`tools/list` → `tools/call`, resultados truncados em 8 KB). Busca
server-side chega como blocos
`server_tool_use`/`tool_result` no stream (replay cru no histórico;
blocos de texto sintetizados pelo servidor são filtrados). `run_ps`
fala com um filho pwsh/powershell vivo por pipes (comando em base64
UTF-16LE + sentinela `__ZQEND__<tag>|<cwd>|<exit>`). Plano e ask_user
são gates (ManualResetEventSlim) que pausam o turno até a UI decidir.
Conversas salvas por completo (inclusive imagens em base64) em
`history/conv-*.json`; compactação oferecida no limiar (28 msgs/150 KB).

## Paridade com o Claude Code

Análise de 16 lacunas em `~/zquick-vs-claude.html` (13/10/2026).
As **Ondas 1–4** (commits `634966f`, `9e62c41`, `c62e720`, `7bd4b0e`)
fecharam as 16 — edição com diff, grep, retry, Parar, memória,
sempre-permitir, fila, shell persistente, @menção, ask_user
multi+preview, modo plano, cache de prompt, verificação pós-escrita,
medidor de contexto, **tools de leitura em paralelo** e **cliente
MCP**. A **Onda 5** (`fd14a10`) foi além do comparativo: **subagente
de leitura** com contexto próprio (estilo Explore/Task do Claude
Code) e **skills** em `.md` (estilo skills do Claude Code). O que
resta é plugins de propósito específico. E o ZQuick faz coisas que o
Claude Code não faz: residente Alt+Q + bandeja, anexos por Ctrl+V,
histórico retomável com imagens.

## Versões

| Commit | O que trouxe |
|---|---|
| `a87832e` | v3 — busca+visão+histórico+tema, anexos, agente Windows |
| `1cd86c5` | fix X/Alt+F4 oculta em vez de fechar (tray) |
| `1d273ec` | ask_user — perguntas de múltipla escolha |
| `634966f` | Onda 1 — Parar, retry/backoff, file_grep, ctx meter, rounds 12 |
| `9e62c41` | Onda 2 — file_edit com diff, memória, "Sempre permitir", fila, watchdog SSE |
| `c62e720` | Onda 3 — busca server-side Z.ai, prompt cache, shell persistente, @menção, ask_user multi+preview, modo plano |
| `7bd4b0e` | Onda 4 — tools de leitura em paralelo (ordem preservada), cliente MCP stdio (`mcpServers`) |
| `fd14a10` | Onda 5 — subagente de leitura (`research`, contexto próprio) + skills `.md` (`skill_read`) |

## Notas de engenharia (lições)

- **UTF-8 com BOM obrigatório** — sem ele o 5.1 lê o script como ANSI e
  o parse quebra em qualquer acento.
- Engine C# é **C#5/.NET Framework** (compatível com o 5.1): parser JSON
  minimalista embutido (`MJ`), sem `out var`, streams no lugar de
  `ReadAsStringAsync(ct)`.
- **Tool schemas SEM a chave `pattern`** — a Z.ai rejeita com erro 1210.
- No pwsh, `Add-Type` sem `-ReferencedAssemblies`; no 5.1, com
  `System.Net.Http.dll` — branch por versão.
- `OpenFileDialog` do WPF .NET Core (pwsh 7) **não tem `Owner` setável**
  — envolver em try/catch ou o app cai na primeira @menção.
- E2E de UI nesta máquina: **texto injetado não vira texto em WPF**
  (TSF/IME descarta keybd_event/SendInput UNICODE; keydown puro como
  Enter/Esc/Alt+Q chega) — caminhos de digitação são testados via
  ValuePattern ou hooks `/uitest`.
- `SendInput` x64: a union do INPUT precisa do MOUSEINPUT para
  `SizeOf(INPUT)` = 40 — sem ele injeta nada e retorna 0.
- E2E: `%TEMP%\zquick.log` é escrito com `Add-Content` e fica **travado
  por instantes** — toda leitura em teste precisa de retry (10×150ms);
  e o log **não tem data** (só HH:mm:ss), então filtro por hora
  casa sujeira de dias anteriores — usar offset de bytes como marca.
- **Asserts de log são acento-sensíveis** (`-match` ignora caixa, não
  acento: "relatorio" ≠ "relatório") — padrão agnóstico `relat.rio`；
  e emoji astral em regex .NET conta **2 UTF-16 units** — `.{0,2}` não
  cobre "🤖 " (3 units).

Log de diagnóstico: `%TEMP%\zquick.log`.
