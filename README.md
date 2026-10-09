# ZQuick

Assistente rápido residente no Windows, estilo Copilot Quick View.
Uma janela compacta sempre à mão (**Alt+Q**) que responde em streaming,
busca na web, lê prints e arquivos (PDF, DOCX, texto/código), guarda o
histórico de conversas e **age no Windows** — cria notas, move/renomeia
arquivos, executa PowerShell — com autorização explícita para cada ação.

Escrito em **PowerShell + WPF** num único arquivo (`zquick.ps1`, com engine
C# embutido via `Add-Type`), compatível com Windows PowerShell 5.1 e pwsh 7+.
Zero dependências: o exe é gerado com PS2EXE e roda em qualquer Windows.

Funciona com qualquer provedor de LLM compatível com a **API Anthropic**
(`/v1/messages`) — perfis múltiplos no `zquick.json` (Z.ai, Kimi, ...).

## Arquivos

| Arquivo | O que é |
|---|---|
| `zquick.ps1` | o app inteiro (fonte) |
| `zquick.json` | config: perfil/modelo, atalho, tema, opacidade, perfis de provedores |
| `build-exe.ps1` | gera `zquick.exe` com PS2EXE (rodar com powershell.exe 5.1) |
| `kit/` | kit de distribuição: INSTALAR/DESINSTALAR, LEIA-ME e template de config |
| `test-*.ps1` | testes (engine headless + E2E de UI via keybd_event/UIA — rodar com `pwsh -STA`) |

## Rodar

```powershell
# direto (recomendado pwsh 7+; aceita 5.1)
pwsh -STA -File zquick.ps1

# residente oculto (como a tarefa de logon faz)
pwsh -STA -WindowStyle Hidden -File zquick.ps1 -Hidden
```

A chave da API fica em `~/.claude/settings.json` (`env.ANTHROPIC_AUTH_TOKEN`)
ou direto no `zquick.json` do perfil.

## Build do exe

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1
```

Requisitos do build: pasta `tools/ps2exe` (nupkg da PSGallery) — não vai
para o git; sem ela, o `.ps1` continua sendo o app completo.

## Testes

- `test-xaml.ps1` — valida os XAMLs (parse + FindName)
- `test-send-ui.ps1` / `test-vision-ui.ps1` / `test-search-ui.ps1` — E2E de UI
- `test-agent-e2e.ps1` — agente local: nota, renomear com confirmação, anexos txt/PDF
- `test-esc-ui.ps1`, `test-reopen-ui.ps1`, `test-hist-img.ps1`, `test-histbtn-ui.ps1` — teclas, reabertura, histórico

Todos os de UI precisam do app residente rodando e injetam teclado/mouse;
veredito pelo log (`%TEMP%\zquick.log`).

## Arquitetura em 1 parágrafo

UI WPF na thread STA; engine C# (`HttpClient`/SSE) em thread própria
comunicando-se por `ConcurrentQueue` drenada por `DispatcherTimer` de 80ms.
Loop agêntico até 6 rodadas com tools (`web_search`, `fetch_page`,
`file_list/read/write/move/delete`, `note_add`, `run_ps`); ações que alteram
algo passam por uma barra de confirmação (✅/✕, expira em 45s); exclusão vai
para a Lixeira via `SHFileOperation`. Conversas salvas por completo
(inclusive imagens em base64) em `history/conv-*.json`. Compactação automática
oferecida quando a conversa cresce (resumo via modelo flash).

Log de diagnóstico: `%TEMP%\zquick.log`.
