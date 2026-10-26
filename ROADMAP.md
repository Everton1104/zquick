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
| Hooks (pós-tool etc.) | ✅ PreToolUse/PostToolUse/TurnEnd | **8** |
| Slash commands | ✅ `commands\nome.md` → `/nome` | **8** |
| Model fallback chain | ✅ model → fast → big → modelFallback | **8** |
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

## Onda 8 — automação do harness (v3.26, concluída)

- **Hooks** (zquick.json `"hooks"`): `PreToolUse` pode **negar** (exit 2 —
  stdout vira o motivo no tool_result) ou **aprovar por política** (exit 0 —
  pula o GateConfirm daquela call, loga `pass: hook aprovou`); `PostToolUse`
  e `TurnEnd` disparam async (fire-and-forget) com payload JSON no stdin
  (`{tool_name, tool_input, tool_result}` / histórico do turno). 20s timeout,
  fail-open. Ex.: `{"PreToolUse":[{"tool":"file_write","run":"powershell
  -NoProfile -File meu-hook.ps1"}]}`.
- **Slash commands**: `commands\nome.md` ao lado do app vira `/nome args`
  no input (`$ARGUMENTS` = resto da linha; até 3 níveis de aninhamento;
  desconhecido avisa no status e NÃO envia). Exemplo embutido: `/commit`.
- **Model fallback**: no meio do turno, se o modelo estourar as 4 tentativas
  de retry (429/5xx/rede), troca para o próximo da cadeia (model → fast →
  big → `"modelFallback":[...]` do zquick.json, dedupe) e continua; o modelo
  do ⚙ volta na próxima pergunta.

## Onda 9 — multiagente

- **Subagente com escrita**: research ganha file_edit/run_ps (com o mesmo
  GateConfirm do turno principal).
- **Sessões em background**: dispara um sub e continua respondendo; notifica
  ao terminar (estilo Task do CC).

## Backlog menor (adiado)

- Heurística Test-TextPlan mais esperta (v3.23.1).
- Pop da fila antes do envio (mensagem nova na frente da fila pendente).
