# ZQuick — Notas de Desenvolvimento

Detalhes de engenharia do projeto. Para o uso do app, veja
`kit/LEIA-ME.txt` (guia rápido) e `kit/MANUAL.txt` (manual completo).

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
server-side chega como blocos `server_tool_use`/`tool_result` no
stream (replay cru no histórico; blocos de texto sintetizados pelo
servidor são filtrados). `run_ps` fala com um filho pwsh/powershell
vivo por pipes (comando em base64 UTF-16LE + sentinela
`__ZQEND__<tag>|<cwd>|<exit>`). Plano e ask_user são gates
(`ManualResetEventSlim`) que pausam o turno até a UI decidir.
Conversas salvas por completo (inclusive imagens em base64) em
`history/conv-*.json`; compactação oferecida no limiar. A janela usa
`WindowChrome` (caption 40px arrastável, botões próprios
— ▢ ✕ como estilo `ChromeBtn`) e o diálogo ⚙ compartilha a mesma
moldura; handlers do diálogo são scriptblocks simples com estado em
`$script:set*` (`$script:` dentro de `GetNewClosure` resolve no módulo
da closure — não usar os dois juntos).

## Build

- `build-exe.ps1` — gera `zquick.exe` com PS2EXE (rodar com
  powershell.exe 5.1). Requisitos: pasta `tools/ps2exe` (nupkg da
  PSGallery) — não vai para o git; sem ela, o `.ps1` continua sendo o
  app completo.
- `build-msi.ps1` — gera `dist/ZQuick-x.y.z.msi` com WiX 3.14 (binários
  baixados 1× para `tools/wix314`). Por usuário (não pede admin), UI
  `WixUI_InstallDir` localizada em pt-BR (`dist/obj/ptbr.wxl` gerado
  pelo próprio script — acentos como entidades XML numéricas porque o
  script é ASCII puro) + checkbox "Iniciar o ZQuick agora" no fim
  (`WixShellExec`; o app aberto sem chave mostra o assistente sozinho —
  flag `-Setup` força). Verificação automática pós-build consulta as
  tabelas Property/Control do MSI (texto pt-BR + checkbox ligado).

## Testes

- Estáticos: `check-engine.ps1` (C# nos 2 runtimes), `test-xaml.ps1`
  (parse + FindName dos XAMLs), `test-surgery.ps1` (costura JSON da
  pré-busca).
- E2E de UI (app residente rodando; oráculo = `%TEMP%\zquick.log`):
  envio/visão/busca (`test-send/vision/search-ui`), agente e
  confirmações (`test-agent-e2e`, `test-always`, `test-edit`),
  teclas/histórico (`test-esc`, `test-reopen`, `test-hist-img`,
  `test-histbtn`, `test-close`), ondas — Parar/grep (`test-stop`,
  `test-grep`), memória/fila (`test-memory`, `test-queue`), ask/plan
  (`test-ask`, `test-panel`, `test-planreal`), shell persistente
  (`test-shell`), @menção (`test-atdialog`), busca server/cache
  (`test-zaiserver`, `test-zai-cache`), paralelo+MCP
  (`test-parallel-engine`, `test-mcp-engine` + fixture
  `test-mcp-server.ps1`, `test-par4-ui`), subagente/skills
  (`test-sub-engine` com API real, `test-skills-engine`,
  `test-wave5-ui`), moldura+⚙ (`test-wave6-ui`), escala de fonte
  (`test-font-ui`), pin/opacidade incluindo Ctrl+roda sobre o ⚙ aberto
  e prova de pixel da transparência real (`test-top-ui`), histórico com
  moldura nova (`test-histbtn-ui`), listar modelos da API
  (`test-models-ui`), temas salvar/aplicar/apagar (`test-v316…`),
  repintura ao vivo do ✔ Aplicar (`test-repaint-ui`), assistente
  (`test-v319-wizard-e2e`), auto-update com falso release
  (`test-v320-update-e2e`).

## Paridade com o Claude Code

Análise de 16 lacunas em `~/zquick-vs-claude.html` (13/10/2026).
As **Ondas 1–4** (commits `634966f`, `9e62c41`, `c62e720`, `7bd4b0e`)
fecharam as 16 — edição com diff, grep, retry, Parar, memória,
sempre-permitir, fila, shell persistente, @menção, ask_user
multi+preview, modo plano, cache de prompt, verificação pós-escrita,
medidor de contexto, tools de leitura em paralelo e cliente MCP. A
**Onda 5** (`fd14a10`) foi além do comparativo: subagente de leitura
com contexto próprio e skills em `.md`. A **Onda 6** (`3474ddf`)
cuidou do shell visual: menu ⚙ de configurações e moldura própria com
janela memorizada. A **Onda 7** (`57860a8`, v3.25) fechou o "dev
diário" (git_status/diff/log/commit, grep com contexto/modos,
todo_write + painel 📋) e a **Onda 8** (v3.26) o harness: hooks,
slash commands e fallback de modelo. E o ZQuick faz coisas que o
Claude Code não faz:
residente Alt+Q + bandeja, anexos por Ctrl+V, histórico retomável com
imagens.

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
| `3e3780d` | v3.9.1 — Ctrl+roda vale nas 3 janelas |
| `b34b7e2` | v3.9.2 — transparência REAL: `AllowsTransparency="True"` nas 3 janelas; histórico com moldura própria |
| `7316214` | v3.9.3 — dica no ⚙ → Perfil: qualquer API no padrão Anthropic serve |
| `7614860` | v3.9.4 — dica "não precisa ser Claude" + exemplos de Base URL |
| `f18baf1` | v3.10 — 🔎 listar da API no ⚙ → Perfil (`GET /v1/models`) |
| `928c728` | v3.10.1 — ⭐ recomendado na lista (estrela só na exibição, `Clean-ModelId` limpa pra API) |
| (…) | v3.10–v3.23: ver `git log` — compactação E2E, favoritar/renomear histórico, ⧉ copiar resposta, assistente de configuração 4 etapas + MSI + auto-update GitHub, escala/temas/scrollbar temática, repintura ao vivo do ✔ Aplicar (v3.23) |
| — | v3.24 — assistente com presets de provedor (Z.ai/Kimi/DeepSeek) e **LLM local** (Ollama/LM Studio/llama.cpp, chave opcional, perfil `local`); MSI com UI pt-BR + "Iniciar o ZQuick agora"; LEIA-ME enxuto + MANUAL.txt |
| — | v3.24.1 — gate do plano textual só quando o turno usou tools (`turnTools`, mata o falso positivo de resposta didática em passos); fila ✉ só sai depois do envio aceito (`busy`), recusa/exceção não perde a mensagem; estilo da scrollbar em **um** fragmento (`$scrFrag` + marcador `<!--SCRFRAG-->` injetado pelo Theme-Xaml, era copiado 4×) |
| `57860a8` | v3.25 (Onda 7) — `git_status/diff/log` (repo > `_shCwd` > cwd, valida `.git`) + `git_commit` no GateConfirm; `file_grep` com `mode:"files"/"count"`, `context:0-3` (grupos separados por `--`) e `max:1-200`; `todo_write` + painel 📋 (○ ●accent ✔riscado, `/uitest todo2` cobre o drain; lição: `.clear` em array do ConvertFrom-Json resolve para IList.Clear — PSMethod truthy — checar `-is [PSCustomObject]` antes) |
| — | v3.26 (Onda 8) — **hooks** (`PreToolUse` exit 2 = nega com motivo no tool_result / exit 0 = aprova por política e pula o GateConfirm (`_hookAllow`), `PostToolUse`/`TurnEnd` async fire-and-forget, payload JSON no stdin via Task, 20s timeout fail-open); **slash commands** (`commands\nome.md` → `/nome args`, `$ARGUMENTS`, aninhamento ≤3, desconhecido avisa e **return** — o `break` sozinho caía no envio); **fallback de modelo** (cadeia model → fast → big → `modelFallback` do json, dedupe; após esgotar as 4 tentativas troca `fbIdx`/`_modelSave` e reconstrói o body, `CurModel` restaurado no finally) |

## Notas de engenharia (lições)

- **UTF-8 com BOM obrigatório** — sem ele o 5.1 lê o script como ANSI e
  o parse quebra em qualquer acento. (Scripts auxiliares ASCII puro:
  acentos via entidades/códigos.)
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
- E2E: `%TEMP%\zquick.log` é escrito com `Add-Content` e fica travado
  por instantes — toda leitura em teste precisa de retry; e o log não
  tem data (só HH:mm:ss) — usar offset de bytes como marca.
- **Asserts de log são acento-sensíveis** (`-match` ignora caixa, não
  acento) — padrão agnóstico (`relat.rio`); emoji astral em regex .NET
  conta 2 UTF-16 units.
- **UIA**: diálogo WPF com `Owner` setado aparece como FILHO da janela
  principal na árvore UIA; TabControl só renderiza a aba selecionada
  (selecionar via SelectionItemPattern antes de achar);
  PropertyCondition não aceita wildcard (FindAll + filtro `-like`);
  `ProcessIdProperty` exige Int32 (CIM devolve UInt32).
- **WindowChrome + XamlReader**: estilo de botão da moldura não pode
  usar `BasedOn="{StaticResource {x:Type Button}}"` (quebra no Load);
  controles interativos no cabeçalho precisam
  `WindowChrome.IsHitTestVisibleInChrome="True"`.
- **`$script:` + `GetNewClosure` não se misturam** (o `$script:`
  resolve no módulo da closure → null): handlers usam scriptblocks
  simples com estado compartilhado em variáveis `$script:set*`.
- **Escala de UI = multiplicar `FontSize`, não `LayoutTransform`**: o
  dropdown de ComboBox mora num HWND separado (Popup) e não herda
  transform — mas herda `FontSize`. Cada tipo tem seu próprio DP de
  FontSize (`Control`/`TextBlock`/`TextElement`/`FlowDocument` —
  `AddOwner` cria outro identificador): o walk de re-escala ao vivo tem
  que ler o local value com o identificador do tipo concreto.
- **Walk de tema ao vivo**: um tipo errado num array literal de DPs
  mata o array INTEIRO silenciosamente (`TextBoxBase` mora em
  `System.Windows.Controls.Primitives`); FlowDocument NÃO é árvore
  visual (varredura separada por Blocks/Inlines); estilo é imutável —
  re-parse (`Update-ComboItemStyle`); mapa uma-nova-por-hex-antigo
  colide quando duas chaves compartilham o mesmo hex (matrix:
  accent=trayA) — trayA/trayB ficam fora do mapa e o ícone da bandeja
  é redesenhado por comparação direta.
- **Altura fixa prende a linha**: dimensões fixas do composer precisam
  acompanhar a escala em código, não só os `FontSize`.
- **Nome de tipo errado em handler = FATAL, não erro pontual**: o enum
  é `System.Windows.Input.ModifierKeys` — `Unable to find type` estourou
  no dispatcher e matou o app. Roda do mouse é injetável (não é texto):
  `mouse_event(MOUSEEVENTF_WHEEL, …, dwData:int, …)` com `dwData`
  negativo para baixo, cursor sobre a janela.
- **`Window.Opacity` + `WindowChrome` no Win11 NÃO é transparência**: a
  janela só escurece contra preto; quem blendia de verdade era
  `AllowsTransparency="True"` (exige `WindowStyle="None"`) — convive
  com `WindowChrome` (resize/snap preservados). Oráculo: capturar
  `CopyFromScreen` da janela sobre um fundo VERMELHO maximizado e
  contar pixels vermelhos.
- **MSI/WiX**: `WixShellExec` (checkbox de iniciar o app) mora em
  **WixUtilExtension**, não na WixUIExtension — `light` precisa das
  duas (`-ext WixUIExtension -ext WixUtilExtension`); o SQL do
  WindowsInstaller (`OpenView`) não aceita `LIKE` em coluna de texto —
  filtre por `Dialog_ = '…'` e case o texto no PowerShell; backtick de
  crase do SQL é ESCAPE no PowerShell — string de consulta com aspas
  simples.
- **Server HTTP fake de teste: `Content-Length` conta BYTES, não chars**
  (UTF-8: acento/emoji = 2+ bytes) — comparar `$req.Length` nunca fecha
  a leitura com corpo não-ASCII e o servidor fica travado no `Read`
  (o cliente pendura até o timeout). Contar `$total += $n` em bytes e
  só decodificar no final; headers são ASCII, então o índice do fim do
  header em chars == bytes.
- **`\b` é um escape JSON VÁLIDO (backspace)** — caminho Windows
  embutido em JSON (`...\busca.txt`) corrompe em silêncio: dobrar TODA
  a barra invertida do path (`-replace '\\','\\'`), não só os
  separadores óbvios.
- **Payload de hook em JSON**: idem — o `run` com caminho e o
  `HooksJson` montado no PS 5.1 precisam do path com barras dobradas,
  senão o `MJ.Parse` falha e os hooks ligam "desligados" (o sintoma é o
  GateConfirm abrir normal, sem erro).
