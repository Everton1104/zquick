# ROADMAP — ZQuick como substituto do Claude Code

Objetivo: **ZQuick desenvolve ZQuick** — o app tem que cobrir o ciclo de trabalho
que hoje exige o Claude Code instalado (`~\.local\bin\claude.exe`, 2.1.310).
Como o Claude Code local já roda o MESMO modelo (GLM via Z.ai, settings.json),
a diferença toda está no **harness** — as capacidades em volta do modelo.

Comparativo: 13/10 (`~/zquick-vs-claude.html`) → 16 lacunas fechadas pelas
Ondas 1-6. Levantamento de 26/10 contra o CC 2.1.310 local:

## Status por capacidade

| Capacidade (CC) | ZQuick | Onda |
|---|---|---|
| Tools de leitura (read/list/glob) | ✅ file_read/file_list/glob | 1-4 |
| Busca web / fetch | ✅ web_search/fetch_page | 1, 4 |
| Edição com diff aprovado | ✅ file_edit | 3 |
| Shell persistente | ✅ run_ps (sessão por conversa) | 3-4 |
| Anexos (PDF/DOCX/img) | ✅ | 2 |
| Memória entre conversas | ✅ memory_save | 3 |
| Multi-pergunta ask_user | ✅ | 3-4 |
| Skills | ✅ skill_read (sob demanda) | 6 |
| Subagente | ⚠️ research (só leitura) | 9 |
| Paralelismo de leitura | ✅ tools em paralelo, ordem preservada | 4 |
| MCP | ✅ cliente stdio | 5 |
| **Todo list** | ✅ todo_write + painel 📋 | **7** |
| **Git** | ✅ git_status/diff/log/commit | **7** |
| **Grep rico** (contexto/modos) | ✅ file_grep modes+context+max | **7** |
| Hooks (pós-tool etc.) | ❌ | 8 |
| Slash commands | ❌ (só /uitest interno) | 8 |
| Model fallback chain | ❌ | 8 |
| Subagente com ESCRITA | ❌ | 9 |
| Sessões em background | ❌ | 9 |
| Modo plano | ✅ plano textual + lote isento | v3.21 |
| Compactação de contexto | ✅ auto-compact | v3.13 |

## Onda 7 — "dev diário" (v3.25, concluída)

- **git_status / git_diff / git_log** — leitura em paralelo (repo explícito >
  último cwd do shell > cwd do processo; valida `.git`).
- **git_commit** — passa pelo GateConfirm (add -A / paths / só staged).
- **file_grep turbinado** — `mode:"files"` (só caminhos), `mode:"count"`
  (por arquivo, desc), `context:0-3` (linhas vizinhas, grupos com separador
  `--`, match marcado com `: ` e contexto com `- `), `max:1-200`.
- **todo_write** — checklist do turno: painel 📋 vivo (○ pendente, ● em curso
  em accent/negrito, ✔ concluído riscado), limpa em conversa nova, esconde
  via ✕ sem matar a tool.

## Onda 8 — automação do harness (próxima)

- **Hooks**: roda um comando PS em eventos (antes/depois de tool, fim de
  turno) — configurável no zquick.json, substitui o "Sempre permitir" por
  políticas.
- **Slash commands**: `/comando` definido pelo usuário (prompt template +
  argumentos), além dos internos.
- **Model fallback**: cadeia `fastModel → model → bigModel` com retry
  automático em erro/429, em vez de morrer o turno.

## Onda 9 — multiagente

- **Subagente com escrita**: research ganha file_edit/run_ps (com o mesmo
  GateConfirm do turno principal).
- **Sessões em background**: dispara um sub e continua respondendo; notifica
  ao terminar (estilo Task do CC).

## Backlog menor (adiado)

- Heurística Test-TextPlan mais esperta (v3.23.1).
- Pop da fila antes do envio (mensagem nova na frente da fila pendente).
