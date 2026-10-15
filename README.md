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

**Janela**
- **⚙ Configurações** dentro do app (4 abas: Perfil & chaves / Janela /
  Aparência / Geral): chave de API por perfil (PasswordBox), modelos,
  largura/altura/centralização, régua de opacidade 40–100%, fonte e
  tamanho do texto (13 = 100%), as 14 cores do tema (swatch ao vivo +
  restaurar padrão), buscador, maxTokens, promptCache, hideOnBlur e
  systemPrompt — aplica na hora o que dá (janela, opacidade, fonte,
  textos) e recria o engine quando a chave/modelo muda
- **Escala global de fonte**: o tamanho da aba Aparência move a
  interface TODA, não só as respostas — textarea, menus, diálogos,
  histórico e chips crescem juntos (13 = padrão; 10–22 = 77–169%).
  XAML é pré-escalado no parse (`Theme-Xaml`), elementos criados via
  código usam `FSz()`, e o Aplicar re-escala a janela principal **ao
  vivo** (walk visual + documento; diálogo ⚙ e histórico pegam na
  próxima abertura)
- **Moldura customizada** (`WindowStyle=None` + `WindowChrome`):
  botões próprios **— ▢ ✕** — — e ✕ ocultam para a bandeja (saída real
  no menu do tray), ▢ maximiza/restaura, duplo clique no topo maximiza;
  arraste pelo cabeçalho, bordas de resize/snap/sombra do Windows
  preservadas
- **Janela memorizada**: último tamanho e posição voltam no próximo
  abrir (save com debounce; `window.center` = abrir sempre no centro)
- **📌 Sempre no topo** — botão na barra alterna `Topmost` (persistido
  em `alwaysOnTop`, com estado visual accent e checkbox no ⚙ → Janela);
  **Ctrl+roda do mouse** sobre a janela ajusta a opacidade 40–100% em
  passos de 5% (grava com debounce; a régua do ⚙ continua valendo) —
  combinação de overlay: pinado e translúcido sobre o trabalho. O
  Ctrl+roda funciona sobre **qualquer janela do app** (⚙ e histórico
  inclusos, que também abrem já na opacidade atual e acompanham o
  preview da régua). A transparência é **real** (vê-se a área de
  trabalho através): as 3 janelas usam `AllowsTransparency="True"` —
  `Window.Opacity` sozinho, com `WindowChrome` no Win11, só escurecia
  contra preto; o histórico ganhou moldura própria (cabeçalho 🕘 + ✕)
  porque `AllowsTransparency` exige `WindowStyle="None"`
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
| `windowOpacity` / `theme` | 1.0 / — | opacidade (Ctrl+roda também ajusta) e paleta (15 chaves hex) |
| `alwaysOnTop` | `false` | 📌 janela sobre as outras |
| `window` | 860×600, centro | `width,height,x,y` memorizados + `center` |
| `answerFont` / `answerFontSize` | — / 13 | fonte do texto; tamanho 13 = 100% — **escala a interface toda** (10–22) |
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
  (`test-sub-engine` com API real, `test-skills-engine`, `test-wave5-ui`),
  moldura+⚙ (`test-wave6-ui`), escala de fonte (`test-font-ui`),
  pin/opacidade incluindo Ctrl+roda sobre o ⚙ aberto e **prova de
  pixel** da transparência real (`test-top-ui`), histórico com moldura
  nova (`test-histbtn-ui`)

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
A janela usa `WindowChrome` (caption 40px arrastável, botões próprios
— ▢ ✕ como estilo `ChromeBtn`) e o diálogo ⚙ compartilha a mesma
moldura; handlers do diálogo são scriptblocks simples com estado em
`$script:set*` (`$script:` dentro de `GetNewClosure` resolve no módulo
da closure — não usar os dois juntos).

## Paridade com o Claude Code

Análise de 16 lacunas em `~/zquick-vs-claude.html` (13/10/2026).
As **Ondas 1–4** (commits `634966f`, `9e62c41`, `c62e720`, `7bd4b0e`)
fecharam as 16 — edição com diff, grep, retry, Parar, memória,
sempre-permitir, fila, shell persistente, @menção, ask_user
multi+preview, modo plano, cache de prompt, verificação pós-escrita,
medidor de contexto, **tools de leitura em paralelo** e **cliente
MCP**. A **Onda 5** (`fd14a10`) foi além do comparativo: **subagente
de leitura** com contexto próprio (estilo Explore/Task do Claude
Code) e **skills** em `.md` (estilo skills do Claude Code). A
**Onda 6** (`3474ddf`) cuidou do shell visual: **menu ⚙ de
configurações** (equivalente ao `/config`) e **moldura própria**
com janela memorizada. E o ZQuick faz coisas que o Claude Code não
faz: residente Alt+Q + bandeja, anexos por Ctrl+V, histórico
retomável com imagens.

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
| `3474ddf` | Onda 6 — menu ⚙ de configurações (4 abas) + moldura customizada — ▢ ✕ + janela memorizada |
| `7d72eb5` | v3.8 — escala global de fonte: `answerFontSize` move a interface toda (pré-escala no parse + `FSz` + re-escala ao vivo no Aplicar) |
| `ce02283` | v3.9 — 📌 sempre no topo (persistido) + Ctrl+roda ajusta opacidade ao vivo |
| `3e3780d` | v3.9.1 — Ctrl+roda vale nas 3 janelas (⚙/histórico abrem na opacidade atual e seguem o preview da régua) |
| `b34b7e2` | v3.9.2 — transparência REAL: `AllowsTransparency="True"` nas 3 janelas (sem ele `Window.Opacity`+`WindowChrome` só escurecia contra preto); histórico com moldura própria (🕘 + ✕) |
| `7316214` | v3.9.3 — dica no ⚙ → Perfil: qualquer API no padrão Anthropic serve (`/v1/messages` incluído automaticamente) |
| `7614860` | v3.9.4 — dica reformulada: "não precisa ser Claude" em destaque + exemplos de Base URL (Z.ai, Kimi, DeepSeek, MiniMax) |

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
- **UIA**: diálogo WPF com `Owner` setado aparece como **FILHO da
  janela principal** na árvore UIA (não do RootElement); TabControl
  **só renderiza a aba selecionada** (elementos das outras não
  existem — selecionar via SelectionItemPattern antes de achar);
  PropertyCondition não aceita wildcard (FindAll + filtro `-like`).
- **WindowChrome + XamlReader**: estilo de botão da moldura não pode
  usar `BasedOn="{StaticResource {x:Type Button}}"` (quebra no Load)
  — setters completos no próprio estilo; controles interativos no
  cabeçalho precisam `WindowChrome.IsHitTestVisibleInChrome="True"`.
- **`$script:` + `GetNewClosure` não se misturam** (o `$script:`
  resolve no módulo da closure → null): handlers usam scriptblocks
  simples com estado compartilhado em variáveis `$script:set*`.
- **Escala de UI = multiplicar `FontSize`, não `LayoutTransform`**: o
  dropdown de ComboBox mora num HWND separado (Popup) e não herda
  transform do ancestral — mas herda `FontSize` por propriedade, então
  escalar o valor escala o popup junto. E cada tipo tem **seu próprio
  DP** de FontSize (`Control` / `TextBlock` / `TextElement` /
  `FlowDocument` — `AddOwner` cria outro identificador): um walk de
  re-escala ao vivo tem que ler o local value com o identificador do
  tipo concreto, senão `TextBlock` fica para trás.
- **Altura fixa prende a linha**: `InputBox Height="68"` definia a
  altura do DockPanel do composer — o SendBtn não crescia com a fonte.
  Dimensões fixas do composer precisam acompanhar a escala em código
  (boot + re-escala), não só os `FontSize`.
- **Nome de tipo errado em handler = FATAL, não erro pontual**: o enum
  é `System.Windows.Input.ModifierKeys` ("KeyboardModifiers" não existe
  — `Unable to find type` estourou no dispatcher no 1º Ctrl+roda e
  matou o app; o E2E com `mouse_event` real pegou antes do usuário).
  Roda do mouse é injetável (não é texto — TSF/IME não afeta):
  `mouse_event(MOUSEEVENTF_WHEEL, …, dwData:int, …)` com `dwData`
  negativo para baixo, cursor sobre a janela.
- **`Window.Opacity` + `WindowChrome` no Win11 NÃO é transparência**:
  a janela só escurece contra preto (blend com o fundo próprio, não com
  a tela); `SetLayeredWindowAttributes` externo é ignorado. Quem
  blendia de verdade na matriz de probes: `AllowsTransparency="True"`
  (exige `WindowStyle="None"`) — e convive com `WindowChrome` (resize/
  snap preservados, `GlassFrameThickness` irrelevante). Oráculo que
  pegou isso: capturar `CopyFromScreen` da janela sobre um fundo
  VERMELHO maximizado e contar pixels vermelhos — log/json diziam
  "opacidade 50%" enquanto o pixel dizia opaco. `AllowsTransparency`
  também muda a árvore UIA: diálogo com `WindowChrome` + `Owner` aninha
  como FILHO da janela principal (não do RootElement).

Log de diagnóstico: `%TEMP%\zquick.log`.
