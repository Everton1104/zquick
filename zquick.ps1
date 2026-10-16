#Requires -Version 5.1
# ZQuick — caixa de pesquisa rápida (LLM) residente, estilo Copilot Quick View.
#   Compativel com Windows PowerShell 5.1 (para virar exe via PS2EXE) e pwsh 7+.
#   Uso:  powershell -STA -File zquick.ps1 [-Hidden]     (ou zquick.exe gerado)
#   Atalho global (default Win+C) mostra/oculta. Enter envia, Shift+Enter quebra linha,
#   Ctrl+V cola texto OU imagem (print), Esc oculta.
#   Perfis em zquick.json -> qualquer LLM com endpoint compativel com a API Anthropic.
param([switch]$Hidden)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
$script:LogFile = Join-Path $env:TEMP 'zquick.log'
function Log($s) {
    # 2 tentativas: leitores do log (testes E2E com ReadAllText) disputam o arquivo
    # com o Add-Content — 1 linha perdida aqui esconde justamente o que o teste asserta
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $s
    try { Add-Content -Path $script:LogFile -Value $line }
    catch { Start-Sleep -Milliseconds 40; try { Add-Content -Path $script:LogFile -Value $line } catch {} }
}

# ---------- mutex single-instance ----------
$createdNew = $false
$mtx = [System.Threading.Mutex]::new($true, 'ZQuick-Main', [ref]$createdNew)
if (-not $createdNew) { Log 'ja existe outra instancia — saindo'; exit 0 }

try {
# ---------- assemblies ----------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, UIAutomationTypes

# ---------- config (schema v2: perfis multi-provider) ----------
# No exe (PS2EXE) $PSScriptRoot é vazio -> deriva da pasta do proprio exe.
$appDir = if ($PSScriptRoot) { $PSScriptRoot }
          else { Split-Path -Parent ([System.Reflection.Assembly]::GetEntryAssembly().Location) }
$cfgPath = Join-Path $appDir 'zquick.json'
$cfg = @{
    profile       = 'zai'
    model         = 'auto'
    hotkey        = 'win+c'
    maxTokens     = 4096
    searchEngine  = 'bing'      # bing (pre-busca cliente) | zai-server (web_search_prime no servidor) | zai
    promptCache   = $true       # cache_control no system+tools (Z.ai aceita; provado por sonda)
    hideOnBlur    = $false
    systemPrompt  = $null
    windowOpacity = 1.0
    alwaysOnTop   = $false    # v3.9: 📌 janela sobre as outras
    passthrough   = $false    # pula GateConfirm (confirmacoes de ferramenta) - NA MÃO, nunca via LLM
    maxRounds     = 16         # v3.11: teto de rodadas de API por turno (2-40; ao estourar, rodada de fechamento sem tools)
    autoCompact   = $false     # v3.13: compacta a conversa automaticamente (sem perguntar) ao passar do limiar
    # Onda 6: janela memorizada (tamanho/posição) + fonte da área de resposta
    window        = @{ width = 860; height = 600; x = $null; y = $null; center = $true }
    answerFont    = $null      # null = Cascadia Mono (padrão)
    answerFontSize = 13
    theme         = $null
    themes        = $null      # v3.16: { "nome": { 14 cores } } — temas salvos no ⚙
    allow         = @{ runPs = @(); paths = @() }   # "sempre permitir": comandos exatos + pastas liberadas
    mcpServers    = $null      # Onda 4: { "nome": { "command": "...", "args": [...], "env": {...} } } — servidores MCP stdio
    profiles      = @{
        zai = @{
            label    = 'Z.ai GLM'
            baseUrl  = $null          # null = herda de ~/.claude/settings.json
            apiKey   = $null          # null = herda de ~/.claude/settings.json
            fastModel = 'glm-5.3-flash'
            bigModel = 'glm-5.3'
            models   = @('auto', 'glm-5.3-flash', 'glm-5.3-flashx', 'glm-5.3')
        }
    }
}
function Reload-Config {
    if (-not (Test-Path $cfgPath)) { return }
    try {
        $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
        foreach ($k in @('profile','model','hotkey','maxTokens','maxRounds','autoCompact','searchEngine','promptCache','hideOnBlur','systemPrompt','windowOpacity','alwaysOnTop','passthrough','answerFont','answerFontSize','mcpServers')) {
            if ($null -ne $j.$k) { $cfg[$k] = $j.$k }
        }
        if ($j.window) {
            $w2 = @{ width = $cfg.window.width; height = $cfg.window.height; x = $cfg.window.x; y = $cfg.window.y; center = $cfg.window.center }
            foreach ($k in @('width','height','x','y','center')) { if ($null -ne $j.window.$k) { $w2[$k] = $j.window.$k } }
            $cfg.window = $w2
        }
        if ($j.theme) { $cfg.theme = $j.theme }
        if ($j.themes) { $cfg.themes = $j.themes }   # v3.16: temas nomeados no ⚙
        if ($j.profiles) { $cfg.profiles = $j.profiles }
        if ($j.allow) {
            $a = @{ runPs = @(); paths = @() }
            if ($j.allow.runPs)   { $a.runPs   = @($j.allow.runPs   | ForEach-Object { [string]$_ }) }
            if ($j.allow.paths)   { $a.paths   = @($j.allow.paths   | ForEach-Object { [string]$_ }) }
            $cfg.allow = $a
        }
    } catch { Log "config invalido, usando defaults: $_" }
}
Reload-Config
# ---------- escala global de fonte: answerFontSize 13 = 100% (multiplica a interface TODA) ----------
$script:fscale = 1.0
try {
    $fs0 = [double]$cfg.answerFontSize
    if ($fs0 -ge 10 -and $fs0 -le 22) { $script:fscale = $fs0 / 13.0 }
} catch {}
function FSz([double]$base) { [Math]::Round($base * $script:fscale, 1) }   # tamanho de fonte escalado
# ---------- tema (cores) — defaults = visual ZQuick escuro; secao "theme" do json sobrescreve ----------
$T = @{
    bg     = '#202024'; card = '#26262B'; panel = '#2A2A30'; input = '#16161A'; border = '#3A3A44'
    fg     = '#E8E8EC'; dim  = '#6E6E7A'; status = '#9A9AA5'
    q      = '#C9C2FF'   # pergunta do usuario
    accent = '#8B9CF6'   # links
    accent2 = '#8B7CF6'  # cursor/streaming
    code   = '#A9DCFC'; trayA = '#8B7CF6'; trayB = '#6358C8'
}
$themeDefaults = $T.Clone()   # Onda 6: base p/ "restaurar cores padrão" no diálogo ⚙
# v3.16.1: temas embutidos — vêm no app, aparecem primeiro na lista do ⚙ e não apagam
$builtinThemes = [ordered]@{
    'padrão' = $themeDefaults
    'matrix' = [ordered]@{
        bg = '#000000'; card = '#0A140A'; panel = '#0E1A0E'; input = '#040804'; border = '#1F4A1F'
        fg = '#2EFF2E'; dim = '#1E8A1E'; status = '#7CD97C'
        q = '#B4FFB4'; accent = '#00FF41'; accent2 = '#39FF14'
        code = '#98FB98'; trayA = '#00FF41'; trayB = '#008000'
    }
}
if ($cfg.theme) {
    foreach ($k in @($cfg.theme.PSObject.Properties.Name)) { if ($T.ContainsKey($k)) { $T[$k] = [string]$cfg.theme.$k } }
}
# aplica cores do tema sobre os literais dos XAML (janela + dialogos) antes do parse;
# v3.8: tambem multiplica todo FontSize="N" pela escala global (13 = 100%)
function Theme-Xaml([string]$x) {
    foreach ($pair in @(
        @('#202024', $T.bg), @('#2A2A30', $T.panel), @('#16161A', $T.input), @('#3A3A44', $T.border),
        @('#E8E8EC', $T.fg), @('#9A9AA5', $T.status), @('#6E6E7A', $T.dim)
    )) { $x = $x.Replace($pair[0], $pair[1]) }
    if ([Math]::Abs($script:fscale - 1.0) -gt 0.001) {
        $me = [System.Text.RegularExpressions.MatchEvaluator]{ param($m)
            'FontSize="' + [Math]::Round([double]$m.Groups[1].Value * $script:fscale, 1) + '"'
        }
        $x = [regex]::Replace($x, 'FontSize="(\d+(?:\.\d+)?)"', $me)
    }
    $x
}
function HexTo-DrawColor([string]$h) {
    $h = ([string]$h).TrimStart('#')
    [System.Drawing.Color]::FromArgb([Convert]::ToInt32($h.Substring(0,2),16), [Convert]::ToInt32($h.Substring(2,2),16), [Convert]::ToInt32($h.Substring(4,2),16))
}
function Save-Config {
    try {
        $out = [ordered]@{
            profile = $cfg.profile; model = $cfg.model; hotkey = $cfg.hotkey; maxTokens = $cfg.maxTokens
            maxRounds = $cfg.maxRounds
            autoCompact = [bool]$cfg.autoCompact
            searchEngine = $cfg.searchEngine; promptCache = $cfg.promptCache; hideOnBlur = $cfg.hideOnBlur
            systemPrompt = $cfg.systemPrompt; windowOpacity = $cfg.windowOpacity; alwaysOnTop = $cfg.alwaysOnTop
            passthrough = $cfg.passthrough
            window = $cfg.window; answerFont = $cfg.answerFont; answerFontSize = $cfg.answerFontSize
            theme = $cfg.theme; themes = $cfg.themes; profiles = $cfg.profiles; allow = $cfg.allow; mcpServers = $cfg.mcpServers
        }
        [pscustomobject]$out | ConvertTo-Json -Depth 6 | Set-Content -Path $cfgPath -Encoding utf8
    } catch { Log "save-config: $_" }
}

# ---------- auth: resolve perfil -> (baseUrl, apiKey) ----------
$sj = $null
try { $sj = Get-Content (Join-Path $env:USERPROFILE '.claude\settings.json') -Raw | ConvertFrom-Json } catch {}
function Resolve-ProfileAuth($p) {
    $base = $p.baseUrl; $key = $p.apiKey
    if (-not $key -and $sj) { $key = $sj.env.ANTHROPIC_AUTH_TOKEN }
    if (-not $base) {
        if ($sj -and $sj.env.ANTHROPIC_BASE_URL) { $base = $sj.env.ANTHROPIC_BASE_URL }
        else { $base = 'https://api.z.ai/api/anthropic' }
    }
    if (-not $key) { throw "sem API key: defina 'apiKey' no perfil do zquick.json" }
    @{ base = [string]$base; key = [string]$key }
}

# ---------- memoria entre conversas (zquick-memory.md ao lado do app) ----------
$memFile = Join-Path $appDir 'zquick-memory.md'
function Get-MemoryBlock {
    try {
        if (-not (Test-Path -LiteralPath $memFile)) { return '' }
        $t = [IO.File]::ReadAllText($memFile)
        if (-not $t.Trim()) { return '' }
        if ($t.Length -gt 6000) { $t = '…(memória antiga descartada)' + $t.Substring($t.Length - 6000) }
        return "`n`n## Memória — fatos duráveis do usuário (aprendidos em conversas anteriores; use quando relevante)`n$t"
    } catch { return '' }
}

# ---------- skills (Onda 5): playbooks .md em <app>\skills — listados no system, abertos via skill_read ----------
$skillsDir = Join-Path $appDir 'skills'
function Get-SkillList {
    # devolve array de @(nome, caminho, descricao); frontmatter '--- name:/description: ---'
    # com fallback p/ nome do arquivo e 1a linha util (cap 20 skills)
    try {
        if (-not (Test-Path -LiteralPath $skillsDir)) { return ,@() }
        $out = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $skillsDir -Filter *.md -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $t = [IO.File]::ReadAllText($f.FullName)
            $name = $null; $desc = $null
            if ($t -match '(?s)^---\r?\n(.*?)\r?\n---') {
                foreach ($ln in ($Matches[1] -split "\r?\n")) {
                    if ($ln -match '^name:\s*(.+)$') { $name = $Matches[1].Trim() }
                    elseif ($ln -match '^description:\s*(.+)$') { $desc = $Matches[1].Trim() }
                }
            }
            if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
            if (-not $desc) {
                $body = $t -replace '(?s)^---.*?---\s*', ''
                $first = @($body -split "\r?\n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                if ($first) { $desc = [string]$first[0] }
            }
            $out += ,@([string]$name, [string]$f.FullName, [string]$desc)
            if ($out.Count -ge 20) { break }
        }
        return ,$out
    } catch { return ,@() }
}
function Get-SkillsBlock {
    $list = Get-SkillList
    if (-not $list -or $list.Count -eq 0) { return '' }
    $lines = foreach ($s in $list) { "- $($s[0]) — $($s[2])" }
    return "`n`n## Skills (playbooks do usuário — quando a tarefa combinar com um deles, chame skill_read com o nome exato e siga as instruções)`n" + ($lines -join "`n")
}

# ---------- engine C# (rede, SSE, agente, busca) — C#5/.NET Framework 4.x compativel ----------
$engineCs = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ZQuick {

// ---- MiniJson: parser JSON minimalista (sem dependencia de System.Text.Json, ----
// ---- roda igual no .NET Framework 4.x do Windows PowerShell 5.1)             ----
static class MJ {
    static string _s; static int _p;
    public static object Parse(string json) { _s = json ?? ""; _p = 0; try { return Value(); } catch { return null; } }
    static void Ws() { while (_p < _s.Length) { char c = _s[_p]; if (c == ' ' || c == '\t' || c == '\n' || c == '\r') _p++; else break; } }
    static object Value() {
        Ws();
        if (_p >= _s.Length) return null;
        char c = _s[_p];
        if (c == '{') {
            _p++; Dictionary<string, object> d = new Dictionary<string, object>(); Ws();
            if (_p < _s.Length && _s[_p] == '}') { _p++; return d; }
            while (true) {
                Ws(); string k = Str(); Ws(); if (_p < _s.Length && _s[_p] == ':') _p++;
                d[k] = Value(); Ws();
                if (_p < _s.Length && _s[_p] == ',') { _p++; continue; }
                if (_p < _s.Length && _s[_p] == '}') _p++;
                break;
            }
            return d;
        }
        if (c == '[') {
            _p++; List<object> l = new List<object>(); Ws();
            if (_p < _s.Length && _s[_p] == ']') { _p++; return l; }
            while (true) {
                l.Add(Value()); Ws();
                if (_p < _s.Length && _s[_p] == ',') { _p++; continue; }
                if (_p < _s.Length && _s[_p] == ']') _p++;
                break;
            }
            return l;
        }
        if (c == '"') return Str();
        if (c == 't') { _p += 4; return true; }
        if (c == 'f') { _p += 5; return false; }
        if (c == 'n') { _p += 4; return null; }
        int st = _p;
        while (_p < _s.Length && "-+.eE0123456789".IndexOf(_s[_p]) >= 0) _p++;
        double num;
        double.TryParse(_s.Substring(st, _p - st), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out num);
        return num;
    }
    static string Str() {
        if (_p >= _s.Length || _s[_p] != '"') return "";
        _p++; StringBuilder sb = new StringBuilder();
        while (_p < _s.Length) {
            char c = _s[_p];
            if (c == '"') { _p++; break; }
            if (c == '\\' && _p + 1 < _s.Length) {
                _p++; char e = _s[_p];
                if (e == 'u' && _p + 4 < _s.Length) {
                    int code;
                    int.TryParse(_s.Substring(_p + 1, 4), System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out code);
                    sb.Append((char)code); _p += 4;
                }
                else if (e == 'n') sb.Append('\n'); else if (e == 'r') sb.Append('\r'); else if (e == 't') sb.Append('\t');
                else if (e == 'b') sb.Append('\b'); else if (e == 'f') sb.Append('\f'); else sb.Append(e);
                _p++;
            } else { sb.Append(c); _p++; }
        }
        return sb.ToString();
    }
}
// ---- Lixeira via SHFileOperation (P/Invoke puro: vale no .NET Framework e no Core) ----
static class Recycle {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEOPSTRUCT { public IntPtr hwnd; public uint wFunc; public string pFrom; public string pTo; public ushort fFlags; public bool fAnyOperationsAborted; public IntPtr hNameMappings; public string lpszProgressTitle; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
    public static int ToRecycleBin(string path) {
        SHFILEOPSTRUCT op = new SHFILEOPSTRUCT();
        op.wFunc = 3; // FO_DELETE
        op.pFrom = path + "\0\0";
        op.fFlags = (ushort)(0x40 | 0x10 | 0x4 | 0x400); // ALLOWUNDO | NOCONFIRMATION | SILENT | NOERRORUI
        return SHFileOperation(ref op);
    }
}

static class H {
    public static string S(Dictionary<string, object> d, string k) { object v; if (d != null && d.TryGetValue(k, out v) && v is string) return (string)v; return null; }
    public static double N(Dictionary<string, object> d, string k) { object v; if (d != null && d.TryGetValue(k, out v) && v is double) return (double)v; return -1; }
    public static Dictionary<string, object> O(Dictionary<string, object> d, string k) { object v; if (d != null && d.TryGetValue(k, out v)) return v as Dictionary<string, object>; return null; }
}

// ---- Hotkey global via low-level keyboard hook — necessario p/ Win+C porque ----
// ---- o shell do Win11 (com app Copilot) registra o atalho via RegisterHotKey ----
public static class Hook {
    delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, LowLevelProc cb, IntPtr hMod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string m);
    static IntPtr _hhk; static LowLevelProc _cb; static Action _fire;
    static int _vk; static bool _needWin, _needCtrl, _needAlt, _needShift;

    public static bool Install(string spec, Action fire) {
        _vk = 0; _needWin = _needCtrl = _needAlt = _needShift = false;
        string[] parts = spec.Split('+');
        foreach (string p in parts) {
            string t = p.Trim().ToLowerInvariant();
            if (t == "win") _needWin = true;
            else if (t == "ctrl") _needCtrl = true;
            else if (t == "shift") _needShift = true;
            else if (t == "alt") _needAlt = true;
            else if (t.Length > 0) _vk = char.ToUpper(t[0]);
        }
        if (_vk == 0) return false;
        _fire = fire; _cb = HookCb;
        _hhk = SetWindowsHookEx(13 /*WH_KEYBOARD_LL*/, _cb, GetModuleHandle(null), 0);
        return _hhk != IntPtr.Zero;
    }

    static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    static IntPtr HookCb(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && (wParam == (IntPtr)0x0100 || wParam == (IntPtr)0x0104)) { // KEYDOWN / SYSKEYDOWN
            int raw = Marshal.ReadInt32(lParam);
            int vk = raw & 0xFF;
            bool repeat = (raw & (1 << 30)) != 0;
            if (!repeat && vk == _vk) {
                bool win = Down(0x5B) || Down(0x5C);
                bool ok = win == _needWin && Down(0x11) == _needCtrl && Down(0x10) == _needShift && Down(0x12) == _needAlt;
                if (ok) { try { _fire(); } catch {} return (IntPtr)1; }
            }
        }
        return CallNextHookEx(_hhk, nCode, wParam, lParam);
    }
}

public class UiMsg {
    public string Type;   // delta | status | sources | confirm | ask | stopped | done | error | note | allow
    public string Text;
}

public class Engine {
    readonly ConcurrentQueue<UiMsg> _q;
    readonly HttpClient _http;
    readonly string _base; readonly string _key; readonly string _native;
    readonly string _fast; readonly string _big;
    string _model;
    bool _auto; bool _useBig; bool _useVision; string _vision;
    string _specInject;   // resultados da pre-busca (round 0 apenas; nao entra no historico salvo)
    string _pdfFallback;  // msg do usuario SEM os PDFs (retry se o endpoint rejeitar document blocks)
    public string PsExe;  // powershell p/ tool run_ps (default powershell.exe)
    public string MemPath; // zquick-memory.md — memoria entre conversas (PS seta; null = desativado)
    readonly List<string> _allowRunPs = new List<string>();   // "sempre permitir": comando exato
    readonly List<string> _allowPaths = new List<string>();   // "sempre permitir": pasta liberada
    string _confTool, _confSubject;   // subject da confirmacao em curso (p/ gravar a regra no "sempre")
    int _confirmId; readonly ManualResetEventSlim _confEv = new ManualResetEventSlim(false); bool _confOk;
    int _askId; readonly ManualResetEventSlim _askEv = new ManualResetEventSlim(false); string _askAnswer;
    bool _compactAsked;   // pergunta de compactacao da conversa: 1x por conversa
    // plano aprovado (#13 modo plano): ate' o fim do turno as confirms rodam sem UI
    int _planId; readonly ManualResetEventSlim _planEv = new ManualResetEventSlim(false); bool _planAnswer; bool _planOk;
    readonly int _maxTokens; readonly string _search;
    int _maxRounds = 16;   // v3.11: rodadas por turno (SetMaxRounds/config maxRounds)
    volatile bool _passThrough;   // modo passthrough: GateConfirm aprova tudo (nao confundir com allow/auto)
    int _mtNeed = 0;       // v3.11.1: maxTokens que a conversa precisou (thinking comendo o limite — memorizado no turno seguinte)
    bool _autoCompact;     // v3.13: compacta sem perguntar quando a conversa passa do limiar
    List<string> _full = new List<string>();   // v3.13: historico COMPLETO da conversa (disco/render) — _history e' a versao enviada a API
    int _confAuto;   // v3.13: 1 = usuario escolheu "auto-compactar" no confirm de compactacao
    bool _srvSearch;   // busca server-side Z.ai (server tool no /v1/messages — sonda 13/10)
    bool _cacheCtl;    // cache_control no system + ultima tool (provado por sonda: 1550->14 input tokens)
    readonly List<string> _history = new List<string>();
    readonly object _sync = new object();
    volatile int _busy = 0;
    CancellationTokenSource _cts;
    Timer _prewarm;
    // sessao de shell persistente (#3): processo vivo com pipes; cwd/vars/funcoes sobrevivem
    // entre chamadas run_ps da MESMA conversa (Reset/New-Conversation mata a sessao)
    readonly object _shLock = new object();
    System.Diagnostics.Process _sh; StreamWriter _shIn; StreamReader _shOut; StreamReader _shErr;
    readonly List<string> _shErrBuf = new List<string>();

    class AskQ { public string Question, Header; public bool Multi; public List<string[]> Opts = new List<string[]>(); }  // Opts[i]={label,desc,preview}

    const string UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

    static readonly Regex RxAlgo = new Regex("<li class=\"b_algo\".*?<h2><a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a></h2>(.*?)</li>", RegexOptions.Singleline | RegexOptions.Compiled);
    static readonly Regex RxH2   = new Regex("<h2><a[^>]+href=\"(http[^\"]+)\"[^>]*>(.*?)</a>", RegexOptions.Singleline | RegexOptions.Compiled);
    static readonly Regex RxP    = new Regex("<p[^>]*>(.*?)</p>", RegexOptions.Singleline | RegexOptions.Compiled);
    static readonly Regex RxItem = new Regex("<item>.*?<title>(.*?)</title>.*?<link>(.*?)</link>.*?<description>(.*?)</description>", RegexOptions.Singleline | RegexOptions.Compiled);

    public bool Busy { get { lock (_sync) { return _busy == 1; } } }

    // ---------- retry: 429/5xx/falha de rede ANTES do 1o token -> backoff exponencial ----------
    static readonly int[] RetryMs = new int[] { 1000, 3000, 8000 };

    static bool Retryable(Exception ex, CancellationToken ct) {
        if (ex == null) return false;
        if (ex is OperationCanceledException) return !ct.IsCancellationRequested;  // timeout do HttpClient, nao cancel do usuario
        if (ex is HttpRequestException) return true;                               // conexao/DNS/TLS
        if (ex.Message != null && ex.Message.StartsWith("HTTP ")) {
            string code = ex.Message.Substring(5).Trim();
            int sp = code.IndexOf(' ');
            if (sp > 0) code = code.Substring(0, sp);
            int c;
            if (int.TryParse(code, out c)) return c == 429 || (c >= 500 && c <= 504);
        }
        return false;
    }

    public Engine(string baseUrl, string apiKey, string model, string fastModel, string bigModel, int maxTokens, string searchEngine, ConcurrentQueue<UiMsg> q, bool cacheCtl) {
        _base = baseUrl.TrimEnd('/'); _key = apiKey; _fast = fastModel; _big = bigModel;
        _maxTokens = maxTokens; _search = searchEngine; _q = q; _cacheCtl = cacheCtl;
        _srvSearch = (_search == "zai-server");   // provedor pode rejeitar -> fallback 400 desliga
        _native = _base.Replace("/api/anthropic", "/api/paas/v4");
        ApplyModel(model);
        var h = new HttpClientHandler();
        h.AutomaticDecompression = System.Net.DecompressionMethods.GZip | System.Net.DecompressionMethods.Deflate;
        _http = new HttpClient(h) { Timeout = TimeSpan.FromMinutes(3) };
        // keep-alive: ping leve no host a cada 50s p/ manter DNS+TLS quentes —
        // a 1a pergunta depois de um tempo parado nao paga handshake (~1s).
        _prewarm = new Timer(delegate {
            try { HttpGet(new Uri(_base).GetLeftPart(UriPartial.Authority), CancellationToken.None, 8); } catch { }
        }, null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(50));
    }

    void ApplyModel(string m) {
        if (m == "auto") { _auto = true; _model = string.IsNullOrEmpty(_fast) ? _big : _fast; }
        else { _auto = false; _model = m; }
    }

    public void SetModel(string m) { lock (_sync) { ApplyModel(m); } }

    // modelo que aceita imagem (null = _big). glm-5.3 NAO enxerga imagem (responde vazio);
    // na Z.ai quem le print e o flash — o perfil define via "visionModel".
    public void SetVisionModel(string m) { lock (_sync) { _vision = string.IsNullOrEmpty(m) ? null : m; } }

    // v3.11: teto de rodadas por turno configuravel (default 16; 2-40 aceito)
    public void SetMaxRounds(int n) { lock (_sync) { if (n >= 2 && n <= 40) _maxRounds = n; } }
    public void SetPassthrough(bool on) { _passThrough = on; }   // liga/desliga em runtime (botao da toolbar)
    public void SetAutoCompact(bool on) { _autoCompact = on; }   // v3.13: autocompact (config autoCompact ou botao do confirm)

    public void Reset() {
        lock (_sync) { _history.Clear(); _full.Clear(); _compactAsked = false; _planOk = false; _mtNeed = 0; try { _cts.Cancel(); } catch {} }
        KillShell();   // conversa nova = sessao de shell nova
    }
    public void Cancel() { lock (_sync) { try { _cts.Cancel(); } catch {} } }

    // ---------- "sempre permitir" (regras persistidas no zquick.json pela UI) ----------
    public void SetAllowRules(string[] runPs, string[] paths) {
        lock (_sync) {
            _allowRunPs.Clear(); _allowPaths.Clear();
            if (runPs != null) foreach (string s in runPs) if (!string.IsNullOrEmpty(s)) _allowRunPs.Add(s.Trim());
            if (paths != null) foreach (string s in paths) if (!string.IsNullOrEmpty(s)) _allowPaths.Add(s.TrimEnd('\\').ToLowerInvariant());
        }
    }

    bool ShouldAutoApprove(string tool, string subject) {
        if (string.IsNullOrEmpty(tool) || string.IsNullOrEmpty(subject)) return false;
        lock (_sync) {
            if (tool == "run_ps") {
                string s = subject.Trim();
                foreach (string r in _allowRunPs) if (string.Equals(r, s, StringComparison.OrdinalIgnoreCase)) return true;
                return false;
            }
            string p = subject.TrimEnd('\\').ToLowerInvariant();
            foreach (string r in _allowPaths) if (p.StartsWith(r, StringComparison.Ordinal)) return true;   // pasta liberada
            return false;
        }
    }

    // "✔ Sempre": aprova a atual e registra a regra (UiMsg 'allow' -> UI persiste no json)
    public void ConfirmAlways(int id) {
        string tool, subject;
        lock (_sync) {
            if (id != _confirmId) return;
            tool = _confTool; subject = _confSubject;
            _confOk = true; _confEv.Set();
        }
        if (string.IsNullOrEmpty(tool) || string.IsNullOrEmpty(subject)) return;
        lock (_sync) {
            if (tool == "run_ps") { if (!_allowRunPs.Contains(subject)) _allowRunPs.Add(subject); }
            else { string p = subject.TrimEnd('\\').ToLowerInvariant(); if (!_allowPaths.Contains(p)) _allowPaths.Add(p); }
        }
        Emit("allow", "{\"tool\":" + J(tool) + ",\"subject\":" + J(subject) + "}");
    }

    // v3.13: botao "auto-compactar" do confirm de compactacao — aprova E liga autocompact
    public void ConfirmAuto(int id) {
        lock (_sync) { if (id != _confirmId) return; _confAuto = 1; _confOk = true; _confEv.Set(); }
    }

    // ---------- modo plano (#13): usuario aprova UMA vez, acoes seguintes sem confirm ----------
    public void PlanDecide(int id, bool ok) {
        lock (_sync) { if (id != _planId) return; _planAnswer = ok; _planEv.Set(); }
    }

    bool GatePlan(string title, List<string> steps, CancellationToken ct) {
        int id;
        lock (_sync) { _planId++; id = _planId; _planAnswer = false; _planEv.Reset(); }
        var sb = new StringBuilder();
        sb.Append("{\"id\":").Append(id).Append(",\"title\":").Append(J(title)).Append(",\"steps\":[");
        for (int i = 0; i < steps.Count; i++) { if (i > 0) sb.Append(","); sb.Append(J(steps[i])); }
        sb.Append("]}");
        Emit("plan", sb.ToString());
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (true) {
            if (ct.IsCancellationRequested) break;
            if (_planEv.Wait(300)) break;
            if (sw.Elapsed.TotalMinutes > 10) { Emit("status", "plano sem resposta (10 min) — seguindo como rejeitado"); break; }
        }
        bool ok = _planEv.IsSet && _planAnswer && !ct.IsCancellationRequested;
        Emit("plan", "{\"hide\":true}");
        return ok;
    }

    // historico de conversa (snapshots brutos do _history) p/ salvar/retomar
    public List<string> GetHistory() { lock (_sync) { return new List<string>(_history); } }
    // v3.13: conversa COMPLETA (o que vai pro disco e pro render) — a compactacao
    // resume so' a copia que viaja na API; _full nunca encolhe
    public List<string> GetFull() { lock (_sync) { return new List<string>(_full); } }
    // fragmento de historico tem que fechar todas as chaves/colchetes (fora de strings).
    // O MiniJson e' leniente com truncamento, entao a validacao e' por balanceamento.
    static bool FragOk(string s) {
        if (string.IsNullOrEmpty(s) || s[0] != '{') return false;
        int d1 = 0, d2 = 0; bool q = false;
        for (int i = 0; i < s.Length; i++) {
            char ch = s[i];
            if (q) { if (ch == '\\') i++; else if (ch == '"') q = false; continue; }
            if (ch == '"') q = true;
            else if (ch == '{') d1++; else if (ch == '}') d1--;
            else if (ch == '[') d2++; else if (ch == ']') d2--;
        }
        return d1 == 0 && d2 == 0;
    }

    // ao retomar do disco: fragmento truncado (ex.: bug de compactacao de 16/10, que nao fechava
    // "content" com ]}) nao pode entrar no corpo do request — o JSON inteiro morreria com 400 na
    // API. Repara quando o defeito e' exatamente o terminador "}]}"; caso contrario ignora e avisa.
    public void SetHistory(List<string> msgs) {
        int fixedN = 0, bad = 0;
        lock (_sync) {
            if (_busy == 1) return;
            _history.Clear(); _full.Clear(); _compactAsked = false;
            if (msgs != null) foreach (string m in msgs) {
                if (m == null) { bad++; continue; }
                if (FragOk(m)) { _history.Add(m); _full.Add(m); }
                else if (FragOk(m + "]}")) { string f2 = m + "]}"; _history.Add(f2); _full.Add(f2); fixedN++; }
                else bad++;
            }
        }
        if (fixedN + bad > 0) Emit("note", "histórico retomado: " + fixedN + " reparada(s), " + bad + " corrompida(s) ignorada(s)");
    }

    public void Ask(string userText, List<string> imagesPngB64, string systemPrompt) { Ask(userText, imagesPngB64, null, null, systemPrompt); }

    public void Ask(string userText, List<string> imagesPngB64, List<string[]> textFiles, List<string[]> pdfFiles, string systemPrompt) {
        lock (_sync) {
            if (_busy == 1) return;
            _busy = 1; _cts = new CancellationTokenSource();
        }
        Thread t = new Thread(Run);
        t.IsBackground = true;
        // copias locais p/ thread
        string ut = userText; List<string> im = imagesPngB64; List<string[]> tf = textFiles; List<string[]> pf = pdfFiles; string sy = systemPrompt;
        t.Start(new object[] { ut, im, sy, tf, pf });
    }

    // ---------- confirmacao de acoes locais (UI mostra, usuario decide, expira 45s) ----------
    public void Confirm(int id, bool ok) {
        lock (_sync) { if (id != _confirmId) return; _confOk = ok; _confEv.Set(); }
    }

    bool GateConfirm(string tool, string subject, string title, string detail, string diffJson, CancellationToken ct) {
        if (_passThrough) { Emit("status", "pass: aprovado sem confirmar - " + Trunc(subject ?? title, 60)); return true; }   // v3.12: modo passthrough (liga/desliga NO BOTAO, nunca via LLM)
        if (_planOk) { Emit("status", "✅ plano: " + Trunc(subject ?? title, 60)); return true; }   // aprovado em lote
        if (ShouldAutoApprove(tool, subject)) { Emit("status", "✅ sempre permitido: " + Trunc(subject, 60)); return true; }
        int id;
        lock (_sync) { _confirmId++; id = _confirmId; _confOk = false; _confEv.Reset(); _confTool = tool; _confSubject = subject; }
        var sb = new StringBuilder();
        sb.Append("{\"id\":").Append(id)
          .Append(",\"title\":").Append(J(title))
          .Append(",\"detail\":").Append(J(detail));
        if (diffJson != null) sb.Append(",\"diff\":").Append(diffJson);
        if (!string.IsNullOrEmpty(tool)) sb.Append(",\"tool\":").Append(J(tool)).Append(",\"subject\":").Append(J(subject));
        sb.Append("}");
        Emit("confirm", sb.ToString());
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (true) {
            if (ct.IsCancellationRequested) break;
            if (_confEv.Wait(300)) break;
            if (sw.Elapsed.TotalSeconds > 45) { Emit("status", "confirmação expirou — ação negada"); break; }
        }
        bool ok = _confEv.IsSet && _confOk && !ct.IsCancellationRequested;
        Emit("confirm", "{\"hide\":true}");
        return ok;
    }

    // v3.13: confirm de compactacao com 3 saidas — 0 cancelar, 1 compactar agora,
    // 2 compactar E ligar autocompact (persistido pela UI no zquick.json)
    int GateCompact(string detail, CancellationToken ct) {
        if (_autoCompact || _passThrough) return 1;
        int id;
        lock (_sync) { _confirmId++; id = _confirmId; _confOk = false; _confAuto = 0; _confEv.Reset(); }
        Emit("confirm", "{\"id\":" + id + ",\"title\":" + J("Compactar conversa")
            + ",\"detail\":" + J(detail) + ",\"auto\":true}");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (true) {
            if (ct.IsCancellationRequested) break;
            if (_confEv.Wait(300)) break;
            if (sw.Elapsed.TotalSeconds > 45) { Emit("status", "confirmação expirou — compactação cancelada"); break; }
        }
        bool ok; int autoSel;
        lock (_sync) { ok = _confEv.IsSet && _confOk; autoSel = _confAuto; }
        Emit("confirm", "{\"hide\":true}");
        if (!ok || ct.IsCancellationRequested) return 0;
        return autoSel == 1 ? 2 : 1;
    }

    // ---------- pergunta de multipla escolha ao usuario (decisao, estilo AskUserQuestion do Claude Code) ----------
    public void AnswerAsk(int id, string answer) {
        lock (_sync) { if (id != _askId) return; _askAnswer = answer; _askEv.Set(); }
    }

    string GateAsk(List<AskQ> qs, CancellationToken ct) {
        int id;
        lock (_sync) { _askId++; id = _askId; _askAnswer = null; _askEv.Reset(); }
        var sb = new StringBuilder();
        sb.Append("{\"id\":").Append(id).Append(",\"qs\":[");
        for (int i = 0; i < qs.Count; i++) {
            if (i > 0) sb.Append(",");
            sb.Append("{\"q\":").Append(J(qs[i].Question))
              .Append(",\"h\":").Append(J(qs[i].Header))
              .Append(",\"multi\":").Append(qs[i].Multi ? "true" : "false")
              .Append(",\"opts\":[");
            for (int j = 0; j < qs[i].Opts.Count; j++) {
                if (j > 0) sb.Append(",");
                sb.Append("{\"label\":").Append(J(qs[i].Opts[j][0]))
                  .Append(",\"desc\":").Append(J(qs[i].Opts[j][1]))
                  .Append(",\"preview\":").Append(J(qs[i].Opts[j][2])).Append("}");
            }
            sb.Append("]}");
        }
        sb.Append("]}");
        Emit("ask", sb.ToString());
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (true) {
            if (ct.IsCancellationRequested) break;
            if (_askEv.Wait(300)) break;
            if (sw.Elapsed.TotalMinutes > 10) { Emit("status", "pergunta sem resposta (10 min) — seguindo sem"); break; }
        }
        string ans = null;
        lock (_sync) { if (_askEv.IsSet) ans = _askAnswer; }
        Emit("ask", "{\"hide\":true}");
        return ans;
    }

    // ask_user: aceita UMA pergunta (formato antigo) OU ate' 4 em "questions[]",
    // cada opcao pode ter "preview" (mono, ex.: mockup/codigo — estilo AskUserQuestion do Claude)
    string DoAskUser(Dictionary<string, object> inp, CancellationToken ct) {
        var qs = new List<AskQ>();
        object qv;
        if (inp != null && inp.TryGetValue("questions", out qv) && qv is List<object> && ((List<object>)qv).Count > 0) {
            foreach (object x in (List<object>)qv) {
                var qd = x as Dictionary<string, object>;
                if (qd != null) { AskQ a = ParseAskQ(qd); if (a != null) qs.Add(a); if (qs.Count >= 4) break; }
            }
        } else {
            AskQ a = ParseAskQ(inp);
            if (a != null) qs.Add(a);
        }
        if (qs.Count == 0) return "ERRO: envie 'question' + 2-4 'options', ou 'questions' (array de até 4 dessas perguntas, cada uma com {question, header, multiSelect, options}).";
        string ans = GateAsk(qs, ct);
        if (ans == null) {
            if (qs.Count == 1) return "O usuário cancelou ou não respondeu à pergunta. NÃO pergunte de novo: tome a decisão mais conservadora (ou nenhuma) e informe o que decidiu.";
            return "O usuário cancelou ou não respondeu às perguntas. NÃO pergunte de novo: tome as decisões mais conservadoras (ou nenhuma) e informe o que decidiu.";
        }
        if (qs.Count == 1) {
            if (ans.StartsWith("TEXTO:")) return "O usuário respondeu com texto livre: \"" + ans.Substring(6).Trim() + "\"";
            if (ans.StartsWith("ESCOLHA:")) return "O usuário escolheu: " + ans.Substring(8).Trim().Replace(" | ", " e ") + ".";
            return "O usuário respondeu: " + ans;
        }
        // multi: ans = JSON array ["ESCOLHA: x | y", "TEXTO: t", ""]
        var parts = MJ.Parse(ans) as List<object>;
        if (parts == null) return "O usuário respondeu: " + ans;
        var lines = new StringBuilder();
        for (int i = 0; i < qs.Count; i++) {
            string p = i < parts.Count && parts[i] is string ? (string)parts[i] : "";
            string pretty;
            if (p.StartsWith("ESCOLHA:")) pretty = p.Substring(8).Trim().Replace(" | ", " + ");
            else if (p.StartsWith("TEXTO:")) pretty = "texto livre: \"" + p.Substring(6).Trim() + "\"";
            else pretty = "(sem resposta)";
            lines.Append((i + 1)).Append(". ").Append(qs[i].Header).Append(": ").Append(pretty).Append('\n');
        }
        return "Respostas do usuário:\n" + lines.ToString().TrimEnd('\n') + "\nPerguntas marcadas (sem resposta): decida você a opção mais conservadora e informe.";
    }

    static AskQ ParseAskQ(Dictionary<string, object> d) {
        if (d == null) return null;
        string question = H.S(d, "question");
        if (string.IsNullOrEmpty(question)) return null;
        AskQ a = new AskQ();
        a.Question = question;
        a.Header = H.S(d, "header"); if (string.IsNullOrEmpty(a.Header)) a.Header = "decisão";
        object mv; a.Multi = d.TryGetValue("multiSelect", out mv) && mv is bool && (bool)mv;
        object ov;
        if (d.TryGetValue("options", out ov) && ov is List<object>) {
            foreach (object it in (List<object>)ov) {
                var od = it as Dictionary<string, object>;
                if (od == null) continue;
                string lb = H.S(od, "label"); if (string.IsNullOrEmpty(lb)) continue;
                string de = H.S(od, "description"); if (de == null) de = "";
                string pv = H.S(od, "preview"); if (pv == null) pv = "";
                a.Opts.Add(new string[] { lb, de, pv });
                if (a.Opts.Count >= 4) break;
            }
        }
        if (a.Opts.Count < 2) return null;
        return a;
    }

    // ---------- compactacao da conversa (resumo das trocas antigas) ----------
    void CompactHistory(CancellationToken ct) {
        try {
            List<string> msgs;
            lock (_sync) { msgs = new List<string>(_history); }
            if (msgs.Count < 8) return;
            int keep = 6;
            var oldMsgs = msgs.GetRange(0, msgs.Count - keep);
            var recent = msgs.GetRange(msgs.Count - keep, keep);
            Emit("status", "compactando conversa…");
            string summary = Summarize(oldMsgs, ct);
            if (string.IsNullOrEmpty(summary)) { Emit("note", "compactação falhou — mantendo histórico"); return; }
            var nh = new List<string>();
            nh.Add("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":" + J("[RESUMO da conversa anterior, gerado automaticamente]") + "}]}");
            nh.Add("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":" + J(summary) + "}]}");
            nh.AddRange(recent);
            lock (_sync) { _history.Clear(); _history.AddRange(nh); }
            Emit("note", "conversa compactada: " + msgs.Count + " → " + nh.Count + " mensagens (histórico completo continua salvo)");
        } catch (Exception ex) { Emit("note", "compactação: " + ex.Message); }
    }

    string Summarize(List<string> oldMsgs, CancellationToken ct) {
        try {
            string model = string.IsNullOrEmpty(_fast) ? _big : _fast;
            string body = "{\"model\":" + J(model) + ",\"max_tokens\":1024,\"stream\":false"
                + ",\"system\":" + J("Resuma a conversa a seguir em português do Brasil, de forma densa (máx ~500 palavras): o que foi perguntado, respondido e decidido; nomes, caminhos, números e pendências. Saia APENAS com o resumo.")
                + ",\"messages\":[" + string.Join(",", oldMsgs) + "]}";
            return NonStreamOnce(body, ct);
        } catch { return null; }
    }

    // ida nao-streaming (compactacao) com o mesmo retry de 429/5xx do turno principal
    string NonStreamOnce(string body, CancellationToken ct) {
        for (int attempt = 0; ; attempt++) {
            try { return NonStreamTry(body, ct); }
            catch (Exception ex) {
                if (attempt < RetryMs.Length && Retryable(ex, ct)) {
                    if (ct.WaitHandle.WaitOne(RetryMs[attempt])) break;
                    continue;
                }
                throw;
            }
        }
        return null;
    }

    string NonStreamTry(string body, CancellationToken ct) {
        var req = new HttpRequestMessage(HttpMethod.Post, _base + "/v1/messages");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + _key);
        req.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        using (HttpResponseMessage resp = _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct).GetAwaiter().GetResult()) {
            string txt = ReadAll(resp);
            if (!resp.IsSuccessStatusCode) throw new Exception("HTTP " + (int)resp.StatusCode + " " + Trunc(txt, 200));
            Dictionary<string, object> root = MJ.Parse(txt) as Dictionary<string, object>;
            List<object> content = root != null && root.ContainsKey("content") ? root["content"] as List<object> : null;
            if (content != null) foreach (object o in content) {
                Dictionary<string, object> b = o as Dictionary<string, object>;
                if (b != null && H.S(b, "type") == "text") return H.S(b, "text") ?? "";
            }
            return null;
        }
    }

    void Emit(string type, string text) { _q.Enqueue(new UiMsg { Type = type, Text = text }); }

    // cancelamento (botao Parar / Esc / nova conversa): o que ja chegou fica no card
    void StopCancelled() { Emit("stopped", ""); Emit("done", ""); }

    public class Blk {   // public: testes headless constroem blocos p/ ExecTools/McpCall
        public string Kind; public StringBuilder Text = new StringBuilder(); public string Id; public string Name; public StringBuilder Input = new StringBuilder();
        public bool Live;      // texto ja esta' sendo mostrado no card (delta emitido)
        public bool Trace;     // texto = banner da busca server Z.ai (descarta no card E no historico)
        public string Raw;     // bloco do servidor (server_tool_use/tool_result): JSON cru p/ replay
    }

    // heuristica leve: pergunta com cara de fato atual -> vale pre-buscar em paralelo
    static readonly string[] FreshKeys = new string[] {
        "hoje","atual","cotaç","cotac","preço","preco","placar","ganh","últim","ultim","notíc","notic",
        "previs","temperatur","clima","lanç","lanc","versão","versao","dólar","dolar","euro","bitcoin",
        "ibovespa","selic","ipca","quem ganhou","que horas","jogo","campeão","campea","feriado","release"
    };
    static bool LooksFresh(string s) {
        if (string.IsNullOrEmpty(s)) return false;
        string low = s.ToLowerInvariant();
        foreach (string k in FreshKeys) if (low.Contains(k)) return true;
        return false;
    }

    // heuristica: pedido de GERACAO LONGA -> sobe pro modelo grande direto. O flash
    // devolve [thinking, text] e o thinking consome o maxTokens — ensaio/lista longa
    // pode sair curto ou vazio. No big o orcamento rende (maxTokens 4096).
    static readonly string[] LongKeys = new string[] {
        "escreva","escrever","redija","redigir","elabore","ensaio","artigo","redação","redacao",
        "conto","crônica","cronica","história","historia","poema","roteiro","e-mail","email","carta",
        "relatório","relatorio","documentaç","documentac","tabuada","resumo detalhad","detalhad",
        "texto longo","lista completa","vários parágrafos","varios paragrafos"
    };
    static readonly Regex RxLen = new Regex("\\d+\\s*(palavras|parágrafos|paragrafos|p[áa]ginas|linhas|itens|perguntas|tópicos|topicos)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static bool LooksLongForm(string s) {
        if (string.IsNullOrEmpty(s)) return false;
        string low = s.ToLowerInvariant();
        foreach (string k in LongKeys) if (low.Contains(k)) return true;
        return RxLen.IsMatch(s);
    }

    void Run(object arg) {
        object[] a = (object[])arg;
        string userText = (string)a[0]; List<string> imgB64 = (List<string>)a[1]; string sys = (string)a[2];
        List<string[]> txtFiles = a.Length > 3 ? (List<string[]>)a[3] : null;
        List<string[]> pdfFiles = a.Length > 4 ? (List<string[]>)a[4] : null;
        var ct = _cts.Token;
        try {
            McpInit();   // Onda 4: sobe servidores MCP ANTES do 1o BuildBody (tools entram na lista)
            lock (_sync) {
                _useBig = false;
                _planOk = false;   // aprovacao de plano vale so' ate' o fim do turno
                _useVision = _auto && imgB64 != null && imgB64.Count > 0;   // imagem em auto -> modelo com visao
                // anexo de TEXTO sem imagem -> modelo grande: o flash ignora o conteudo
                // inline e sai "procurando" o arquivo no disco (10x file_list, resposta
                // vazia). PDF fica no flash — document block provado la (E2E fase 4).
                if (_auto && !_useVision && txtFiles != null && txtFiles.Count > 0) _useBig = true;
                // pedido de geracao longa (ensaio, artigo, lista grande) -> direto pro
                // modelo grande: no flash o bloco thinking come o maxTokens e o texto
                // sai curto/vasio sem nenhum erro (pedido do usuario 13/10).
                if (_auto && !_useVision && LooksLongForm(userText)) {
                    _useBig = true;
                    Emit("status", "↗ geração longa — usando " + _big);
                }
            }
            // conversa crescendo: compacta (resumo) antes de bater no teto duro. v3.13:
            // o resumo e' SO' para a API — o historico COMPLETO (_full) continua salvo no disco
            bool askCompact = false; int msgN = 0; double kb = 0;
            lock (_sync) {
                double chars = 0; foreach (string h in _history) chars += h.Length;
                if (_history.Count > 40 || chars > 300000) { _history.Clear(); _compactAsked = false; Emit("note", "contexto antigo descartado (o histórico completo continua salvo)"); }
                else if (!_compactAsked && (_history.Count > 28 || chars > 150000)) {
                    _compactAsked = true; askCompact = true; msgN = _history.Count; kb = chars / 1024;
                }
            }
            if (askCompact) {
                if (_autoCompact) { Emit("status", "🧹 autocompact: resumindo trocas antigas…"); CompactHistory(ct); }
                else {
                    int cc = GateCompact(string.Format("{0} mensagens • {1:0} KB. Resumir as trocas antigas (mantendo as últimas intactas) para a conversa continuar leve? O histórico completo continua salvo — o resumo é só para a API.", msgN, kb), ct);
                    if (cc == 1) CompactHistory(ct);
                    else if (cc == 2) {
                        _autoCompact = true;
                        Emit("status", "🧹 autocompact LIGADO — gravado no zquick.json; resumindo…");
                        CompactHistory(ct);
                    }
                }
            }
            var ub = new StringBuilder();
            var ubNoPdf = new StringBuilder();
            if (imgB64 != null) foreach (string b in imgB64) {
                string ib = "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":" + J(b) + "}},";
                ub.Append(ib); ubNoPdf.Append(ib);
            }
            if (pdfFiles != null) foreach (string[] pd in pdfFiles)
                ub.Append("{\"type\":\"document\",\"source\":{\"type\":\"base64\",\"media_type\":\"application/pdf\",\"data\":").Append(J(pd[1])).Append("}},");
            ub.Append("{\"type\":\"text\",\"text\":").Append(J(userText)).Append("}");
            ubNoPdf.Append("{\"type\":\"text\",\"text\":").Append(J(userText)).Append("}");
            if (txtFiles != null) foreach (string[] tf in txtFiles) {
                string fb = ",{\"type\":\"text\",\"text\":" + J("[ARQUIVO ANEXADO: " + tf[0] + " — o conteúdo completo já está AQUI embaixo, dentro desta mensagem. NÃO procure este arquivo no disco (não use file_list/file_read nele); responda a partir do texto injetado.]\n\n" + tf[1]) + "}";
                ub.Append(fb); ubNoPdf.Append(fb);
            }
            string uj = "{\"role\":\"user\",\"content\":[" + ub + "]}";
            lock (_sync) {
                _history.Add(uj); _full.Add(uj);
                _pdfFallback = (pdfFiles != null && pdfFiles.Count > 0) ? "{\"role\":\"user\",\"content\":[" + ubNoPdf + "]}" : null;
            }

            // ----- pre-busca especulativa -----
            // Pergunta com cara de "fato atual": dispara a busca em paralelo ANTES da 1a
            // ida ao modelo e injeta os resultados no system do round 0 — o modelo pode
            // responder em 1 ida (~6s de fila) em vez de 3 (decidir->buscar->responder).
            string sys0 = sys;
            bool noImg = imgB64 == null || imgB64.Count == 0;
            if (noImg && LooksFresh(userText) && _srvSearch) {
                // busca server-side Z.ai: o proprio servidor roda web_search_prime no
                // /v1/messages (11-16s, qualidade alta, recency filter automatico) —
                // pre-buscar Bing em paralelo seria custo morto; so' sobe pro big
                if (_auto) _useBig = true;
                Emit("status", "\U0001F310 busca Z.ai (no servidor)…");
            }
            else if (noImg && LooksFresh(userText)) {
                // fato atual -> quem responde e' o modelo grande: segue instrucao melhor
                // ("responda direto com os resultados") e faz buscas mais certeiras que o flash
                if (_auto) _useBig = true;
                Emit("status", "\U0001F50D pré-busca: " + Trunc(userText, 60));
                var ev = new ManualResetEventSlim(false);
                var specSources = new List<string>();
                string specResults = null;
                ThreadPool.QueueUserWorkItem(delegate {
                    try { specResults = DoSearch(userText, CancellationToken.None, specSources); } catch { }
                    ev.Set();
                });
                if (ev.Wait(1500) && specResults != null) {
                    Emit("note", "pré-busca: " + specSources.Count + " resultados prontos");
                    _specInject = "[O SISTEMA JÁ FEZ A BUSCA NA WEB para a sua pergunta. Resultados:]\nATENÇÃO: se estes resultados já respondem à pergunta, responda ao usuário DIRETO, NÃO chame web_search de novo. Só busque/fetch se forem claramente insuficientes.\n\n" + specResults;
                    if (specSources.Count > 0) Emit("sources", "[" + string.Join(",", specSources) + "]");
                }
                else { Emit("note", "pré-busca: não voltou a tempo (seguindo fluxo normal)"); }
            }

            string stop = ""; bool sawText = false; int mtBumps = 0;
            // teto de rodadas por turno: 16 (era 12 — sonda 16/10: tarefa real de
            // implementacao morreu NO teto: 6 rodadas de diagnostico + plano + 5
            // pos-plano = 12; turno terminou sem texto final e o plano pela metade).
            // Estourando o teto ha' RODADA DE FECHAMENTO sem tools (abaixo). Tokens
            // seguem limitados pelos tetos de compactacao (28 msgs / 150 KB / 40 / 300 KB).
            for (int round = 0; round < _maxRounds; round++) {
                if (ct.IsCancellationRequested) { StopCancelled(); return; }
                string body;
                lock (_sync) { body = BuildBody(round == 0 ? sys0 : sys); }
                List<Blk> blocks = null;
                bool pdfRetry = false;
                for (int attempt = 0; ; attempt++) {
                    bool streamed = false;
                    try { blocks = StreamOnce(body, ct, out stop, out streamed); break; }
                    catch (Exception ex) {
                        // provedor rejeitou a busca server-side (400) -> desliga e refaz
                        // o body com web_search cliente (1x; sonda 13/10: Z.ai aceita,
                        // mas perfis genericos podem nao)
                        if (_srvSearch && ex.Message.StartsWith("HTTP 400")) {
                            _srvSearch = false;
                            Emit("note", "busca server não aceita pelo provedor — usando Bing");
                            body = BuildBody(round == 0 ? sys0 : sys);
                            continue;
                        }
                        // idem cache_control (aceito pela Z.ai; outro endpoint pode nao)
                        if (_cacheCtl && ex.Message.StartsWith("HTTP 400")) {
                            _cacheCtl = false;
                            Emit("note", "cache_control não aceito — reenviando sem");
                            body = BuildBody(round == 0 ? sys0 : sys);
                            continue;
                        }
                        // endpoint rejeitou os document blocks de PDF -> reenvia sem (1x)
                        if (_pdfFallback != null && ex.Message.StartsWith("HTTP 400")) {
                            lock (_sync) { if (_history.Count > 0) _history[_history.Count - 1] = _pdfFallback; if (_full.Count > 0) _full[_full.Count - 1] = _pdfFallback; _pdfFallback = null; }
                            Emit("note", "PDF rejeitado pelo endpoint — reenviando sem o PDF");
                            pdfRetry = true; break;
                        }
                        // 429/5xx/falha de rede ANTES do 1o delta -> tenta de novo com backoff.
                        // Depois do 1o delta nao da: repetir a ida duplicaria a resposta no card.
                        if (!streamed && attempt < RetryMs.Length && Retryable(ex, ct)) {
                            Emit("status", "servidor ocupado — tentativa " + (attempt + 2) + "/" + (RetryMs.Length + 1) + "…");
                            if (ct.WaitHandle.WaitOne(RetryMs[attempt])) { StopCancelled(); return; }
                            continue;
                        }
                        throw;
                    }
                }
                if (pdfRetry) { round--; continue; }
                if (ct.IsCancellationRequested) { StopCancelled(); return; }
                List<string> bj = new List<string>();
                var okBlocks = new List<Blk>();
                bool roundText = false, roundTool = false;
                foreach (Blk b in blocks) {
                    // tool_use PARCIAL (corte max_tokens no meio do JSON): fora do
                    // historico E da execucao — o JSON invalido derrubaria o proximo
                    // request com 400
                    if (b.Kind == "tool_use" && !FragOk(b.Input.Length > 0 ? b.Input.ToString() : "{}")) continue;
                    okBlocks.Add(b);
                    string j2 = BlkJson(b); if (j2 != null) bj.Add(j2);
                    if (b.Kind == "text" && !b.Trace && b.Text.Length > 0) { sawText = true; roundText = true; }
                    if (b.Kind == "tool_use") roundTool = true;
                }
                // content vazio (so' thinking truncado) tambem nao entra: a API rejeita
                if (bj.Count > 0) { string aj = "{\"role\":\"assistant\",\"content\":[" + string.Join(",", bj) + "]}"; lock (_sync) { _history.Add(aj); _full.Add(aj); } }
                // glm-5.3: o thinking pode comer o maxTokens INTEIRO e a rodada voltar
                // so' com raciocinio truncado + stop=max_tokens — zero texto, zero tool
                // (caso 16/10 11:12: "pronto" com resposta VAZIA). Refaz a rodada com
                // teto maior em vez de encerrar mudo; o teto que funcionar fica
                // memorizado para o resto da conversa (2 bumps por turno, cap 16384).
                if (stop == "max_tokens" && !roundText && !roundTool && mtBumps < 2 && !ct.IsCancellationRequested) {
                    int cap = Math.Max(_maxTokens, 16384);
                    int bump = Math.Min(mtBumps == 0 ? Math.Max(_maxTokens * 2, 8192) : cap, cap);
                    if (bump > _maxTokens) {
                        mtBumps++; if (bump > _mtNeed) _mtNeed = bump;
                        Emit("status", "⚠ saída cortada pelo limite de tokens — repetindo com " + bump + "…");
                        round--; continue;
                    }
                }
                if (stop != "tool_use" || ct.IsCancellationRequested) {
                    // fim natural: cortes nunca silenciosos (glm pode voltar vazio quando
                    // o thinking come o maxTokens — a rodada "termina" sem dizer nada)
                    if (stop == "max_tokens") Emit("note", "⚠ rodada cortada pelo limite de tokens (aumente maxTokens no ⚙ se faltar conteúdo)");
                    else if (!sawText) Emit("note", "⚠ o modelo devolveu resposta vazia neste turno — tente reenviar ou um modelo maior no ⚙");
                    Emit("done", ""); return;
                }
                // executa tools — Onda 4: leitura/busca EM PARALELO, o resto serial na ordem
                string resJson = ExecTools(okBlocks, ct);
                string rj = "{\"role\":\"user\",\"content\":[" + resJson + "]}";
                lock (_sync) { _history.Add(rj); _full.Add(rj); }
            }
            // ----- teto de rodadas com tools pendentes: RODADA DE FECHAMENTO sem tools
            // no body (mesma garantia do subagente) — o modelo so' pode devolver texto.
            // Sem isto o turno morria no meio: tool_results entravam no historico, o loop
            // saa e ninguem respondia ("pronto" sem posicao final, plano pela metade).
            if (!ct.IsCancellationRequested) {
                Emit("status", "⚠ limite de rodadas — fechando o turno…");
                string lim = "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":" +
                    J("[LIMITE DE RODADAS ATINGIDO — as ferramentas foram DESLIGADAS nesta chamada. Responda agora ao usuário, em texto: (1) o que você já executou nesta tarefa e o resultado de cada ação (OK/erro), (2) o que ficou faltando do plano, (3) o próximo passo sugerido. NÃO invente resultado — baseie-se apenas nos tool_results acima.]") + "}]}";
                lock (_sync) { _history.Add(lim); _full.Add(lim); }
                try {
                    string stop2; bool streamed2;
                    List<Blk> blocks2 = StreamOnce(BuildBody(sys, false), ct, out stop2, out streamed2);
                    var bj2 = new List<string>();
                    foreach (Blk b in blocks2) { string j2 = BlkJson(b); if (j2 != null) bj2.Add(j2); }
                    if (bj2.Count > 0) { string aj2 = "{\"role\":\"assistant\",\"content\":[" + string.Join(",", bj2) + "]}"; lock (_sync) { _history.Add(aj2); _full.Add(aj2); } }
                } catch (Exception ex2) { if (!ct.IsCancellationRequested) Emit("note", "fechamento falhou: " + Trunc(ex2.Message, 120)); }
            }
            Emit("done", "");
        } catch (Exception ex) {
            if (ct.IsCancellationRequested) StopCancelled();
            else Emit("error", ex.Message);
        } finally { lock (_sync) { _busy = 0; } }
    }

    // ---------- execucao das tools do round (Onda 4 #5: leitura em paralelo) ----------
    // Somente-leitura (web_search/fetch_page/file_list/file_read/file_grep) roda
    // EM PARALELO (Task por bloco); o resto (mutantes com confirm, run_ps, ask_user,
    // plan, escalate, mcp_*) roda serial na thread do turno. Os tool_results voltam
    // SEMPRE na ordem original dos blocos — os ids tem que casar com os tool_use.
    public static bool Parallelizable(string name) {
        return name == "web_search" || name == "fetch_page" || name == "file_list"
            || name == "file_read" || name == "file_grep";
    }

    public string ExecTools(List<Blk> blocks, CancellationToken ct) {
        string[] outs = new string[blocks.Count];
        Task[] tasks = new Task[blocks.Count];
        int nPar = 0;
        for (int i = 0; i < blocks.Count; i++) {
            Blk b = blocks[i];
            if (b.Kind != "tool_use" || !Parallelizable(b.Name)) continue;
            Dictionary<string, object> inp = MJ.Parse(b.Input.Length > 0 ? b.Input.ToString() : "{}") as Dictionary<string, object>;
            string nm = b.Name;
            string query = inp != null ? H.S(inp, "query") : null;
            string url = inp != null ? H.S(inp, "url") : null;
            int idx = i;
            tasks[i] = Task.Factory.StartNew(delegate {
                try {
                    string o;
                    List<string> src = null;
                    if (nm == "web_search") { src = new List<string>(); Emit("status", "\U0001F50D " + (query ?? "?")); o = DoSearch(query, ct, src); }
                    else if (nm == "fetch_page") { Emit("status", "\U0001F4C4 " + (url ?? "?")); o = DoFetch(url, ct); }
                    else { Emit("status", "⚙ " + nm + "…"); o = LocalTool(nm, inp, ct); }
                    if (src != null && src.Count > 0 && _subDepth == 0) Emit("sources", "[" + string.Join(",", src.ToArray()) + "]");
                    outs[idx] = o;
                } catch (Exception ex) { outs[idx] = "ERRO: " + ex.Message; }
            });
            nPar++;
        }
        if (nPar >= 2) Emit("status", "⚙ " + nPar + " tools em paralelo…");
        var resJson = new StringBuilder();
        for (int i = 0; i < blocks.Count; i++) {
            Blk b = blocks[i];
            if (b.Kind != "tool_use") continue;
            if (ct.IsCancellationRequested) break;
            string outp;
            if (tasks[i] != null) { tasks[i].Wait(); outp = outs[i] ?? ""; }
            else {
                Dictionary<string, object> inp = MJ.Parse(b.Input.Length > 0 ? b.Input.ToString() : "{}") as Dictionary<string, object>;
                if (b.Name == "ask_user") { Emit("status", "❓ esperando sua escolha…"); outp = DoAskUser(inp, ct); }
                else if (b.Name == "plan") {
                    string title = H.S(inp, "title");
                    var steps = new List<string>();
                    object sv;
                    if (inp != null && inp.TryGetValue("steps", out sv) && sv is List<object>)
                        foreach (object x in (List<object>)sv) {
                            string s2 = x as string; if (string.IsNullOrEmpty(s2) || s2.Trim().Length == 0) continue;
                            steps.Add(s2.Trim()); if (steps.Count >= 8) break;
                        }
                    if (string.IsNullOrEmpty(title) || steps.Count == 0) outp = "ERRO: envie 'title' (resumo curto) e 'steps' (array de 1-8 passos curtos, verbo + objeto).";
                    else {
                        Emit("status", "\U0001F9ED plano proposto — aguardando sua decisão…");
                        if (GatePlan(title, steps, ct)) {
                            _planOk = true;
                            outp = "APROVADO pelo usuário. Execute os passos AGORA, em ordem, SEM pedir confirmação individual (o lote já foi aprovado; a janela aprova sozinha). Ao final, entregue um resumo curto do que fez.";
                        } else {
                            outp = "REJEITADO pelo usuário. NÃO execute as ações planejadas. Ajuste o plano (ou pergunte com ask_user o que ele prefere) e proponha de novo; só ações de leitura (file_list/file_read/file_grep/web_search) seguem liberadas.";
                        }
                    }
                }
                else if (b.Name == "research") {
                    string task = H.S(inp, "task"); string hint = H.S(inp, "hint");
                    if (string.IsNullOrEmpty(task)) outp = "ERRO: informe 'task' (a tarefa completa e autocontida — o subagente NÃO vê esta conversa).";
                    else { Emit("status", "\U0001F916 subagente de leitura…"); outp = SubResearch(task, hint, ct); }
                }
                else if (b.Name == "escalate") {
                    _useBig = true;
                    Emit("status", "↗ encaminhando ao " + _big + "…");
                    outp = "OK — escalated. The larger model will now answer the user directly.";
                }
                else if (b.Name.Length > 4 && b.Name.StartsWith("mcp_")) {
                    Emit("status", "⚙ " + b.Name + "…");
                    outp = McpCall(b.Name, b.Input.Length > 0 ? b.Input.ToString() : "{}");
                }
                else { Emit("status", "⚙ " + b.Name + "…"); outp = LocalTool(b.Name, inp, ct); }
            }
            if (resJson.Length > 0) resJson.Append(",");
            resJson.Append("{\"type\":\"tool_result\",\"tool_use_id\":").Append(J(b.Id)).Append(",\"content\":").Append(J(outp)).Append("}");
        }
        return resJson.ToString();
    }

    // ---------- subagente de leitura (Onda 5): contexto PROPRIo, so' leitura ----------
    // A tool 'research' nasce um loop agentico SEPARADO (ate' 6 rodadas + 1 fechamento
    // sem tools) que so' ve web_search/fetch_page/file_list/file_read/file_grep — nao
    // altera nada, nao ve a conversa original e nao pode spawnar outro sub. O texto do
    // sub NAO vai pro card (deltas suprimidos por _subDepth); o relatorio final volta
    // como tool_result — a conversa principal fica limpa (so' a conclusao, nao os dumps).
    const int SubMaxRounds = 6;

    string SubBody(string sys, List<string> hist, bool withTools) {
        var tools = new List<string>();
        if (withTools) {
            if (_srvSearch) tools.Add("{\"type\":\"web_search_20250305\",\"name\":\"web_search\"}");
            else tools.Add("{\"name\":\"web_search\",\"description\":\"Search the web for current information. Returns numbered results with title, URL and snippet.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}}");
            tools.Add("{\"name\":\"fetch_page\",\"description\":\"Fetch one web page by absolute http(s) URL and return its readable text (truncated).\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]}}");
            tools.Add("{\"name\":\"file_list\",\"description\":\"List files and folders of a directory on the user's Windows.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}");
            tools.Add("{\"name\":\"file_read\",\"description\":\"Read a text file from the user's Windows (first 8000 chars).\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}");
            tools.Add("{\"name\":\"file_grep\",\"description\":\"Search INSIDE files of a folder (recursive): matching lines as file:line: text.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"glob\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}}");
        }
        string m = !_auto ? _model : (_useBig ? _big : _model);
        return "{\"model\":\"" + m + "\",\"max_tokens\":" + _maxTokens + ",\"stream\":true,\"system\":" + J(sys)
            + ",\"tools\":[" + string.Join(",", tools.ToArray()) + "],\"messages\":[" + string.Join(",", hist.ToArray()) + "]}";
    }

    public string SubResearch(string task, string hint, CancellationToken ct) {
        if (_subDepth > 0) return "ERRO: o subagente não pode spawnar outro subagente.";
        var sw = System.Diagnostics.Stopwatch.StartNew();
        string sys = "Você é um SUBAGENTE de pesquisa do ZQuick, no Windows do usuário, com contexto PRÓPRIO — você NÃO vê a conversa original e não pode conversar com ninguém. Execute a tarefa sozinho até o fim usando as ferramentas de LEITURA (web_search, fetch_page, file_list, file_read, file_grep); você não altera nada. Ao terminar, devolva um RELATÓRIO final denso e direto em português: os achados concretos (caminhos, valores, trechos relevantes como arquivo:linha, URLs) e, se houver, o que não conseguiu confirmar. Sem preâmbulo."
            + (string.IsNullOrEmpty(hint) ? "" : "\n\nDica de onde começar: " + hint);
        var hist = new List<string>();
        hist.Add("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":" + J(task + "\n\n(Investigue com as ferramentas e depois entregue o relatório final.)") + "}]}");
        string lastText = "";
        _subDepth = 1;
        try {
            for (int round = 0; round < SubMaxRounds; round++) {
                if (ct.IsCancellationRequested) break;
                Emit("status", "\U0001F916 subagente: investigando (rodada " + (round + 1) + "/" + SubMaxRounds + ")…");
                string stop; bool streamed;
                List<Blk> blocks = StreamOnce(SubBody(sys, hist, true), ct, out stop, out streamed);
                var bj = new List<string>();
                var tbs = new List<Blk>();
                foreach (Blk b in blocks) {
                    string j2 = BlkJson(b); if (j2 != null) bj.Add(j2);
                    if (b.Kind == "text" && !b.Trace && b.Text.Length > 0) lastText = b.Text.ToString();
                    if (b.Kind == "tool_use") tbs.Add(b);
                }
                hist.Add("{\"role\":\"assistant\",\"content\":[" + string.Join(",", bj) + "]}");
                if (stop != "tool_use" || tbs.Count == 0) break;
                string resJson = ExecTools(tbs, ct);   // so' tools de leitura — rodam em paralelo
                hist.Add("{\"role\":\"user\",\"content\":[" + resJson + "]}");
                if (sw.Elapsed.TotalSeconds > 150) { Emit("status", "\U0001F916 subagente: tempo limite — colhendo o relatório…"); break; }
            }
            // garantia de entrega: sem tools no body o modelo so' pode responder texto
            if (lastText.Trim().Length == 0 && !ct.IsCancellationRequested) {
                Emit("status", "\U0001F916 subagente: fechando o relatório…");
                hist.Add("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Agora entregue o RELATÓRIO FINAL completo (sem chamar ferramentas).\"}]}");
                string stop2; bool streamed2;
                foreach (Blk b in StreamOnce(SubBody(sys, hist, false), ct, out stop2, out streamed2))
                    if (b.Kind == "text" && !b.Trace && b.Text.Length > 0) lastText = b.Text.ToString();
            }
        } catch (Exception ex) {
            if (!ct.IsCancellationRequested) Emit("note", "subagente: " + Trunc(ex.Message, 120));
            if (lastText.Trim().Length == 0) return "ERRO do subagente: " + Trunc(ex.Message, 300);
        } finally { _subDepth = 0; }
        if (ct.IsCancellationRequested && lastText.Trim().Length == 0) return "cancelado";
        int secs = (int)sw.Elapsed.TotalSeconds;
        Emit("status", "\U0001F916 subagente: relatório pronto (" + secs + "s)");
        return "RELATÓRIO DO SUBAGENTE de leitura (" + secs + "s):\n" + Trunc(lastText.Trim(), 8000);
    }

    // ---------- cliente MCP minimo (Onda 4): servidores stdio JSON-RPC ----------
    // Config no zquick.json: "mcpServers": { "nome": { "command": "...", "args": [...], "env": {...} } }.
    // Cada tool do servidor vira mcp_<nome>_<tool> na lista do modelo (schema saneado:
    // sem "pattern" — Z.ai rejeita, erro 1210). Protocolo: JSON-RPC 2.0 por linha no
    // stdio — initialize -> notifications/initialized -> tools/list -> tools/call.
    public class McpSrv {
        public string Name;
        System.Diagnostics.Process _p; StreamWriter _in;
        readonly System.Collections.Concurrent.ConcurrentQueue<string> _q = new System.Collections.Concurrent.ConcurrentQueue<string>();
        int _id; readonly object _idLock = new object();
        public List<string[]> Tools = new List<string[]>();   // {nome-prefixado, tool-anthropic-json, nome-real}

        public string Start(string command, string argsStr, string envJson) {
            try {
                System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo(command, argsStr ?? "");
                psi.UseShellExecute = false; psi.CreateNoWindow = true;
                psi.RedirectStandardInput = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
                psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
                psi.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                if (!string.IsNullOrEmpty(envJson)) {
                    Dictionary<string, object> ev = MJ.Parse(envJson) as Dictionary<string, object>;
                    if (ev != null) foreach (KeyValuePair<string, object> kv2 in ev) psi.EnvironmentVariables[kv2.Key] = kv2.Value == null ? "" : kv2.Value.ToString();
                }
                _p = System.Diagnostics.Process.Start(psi);
                _in = _p.StandardInput; _in.AutoFlush = true;
                Thread rd = new Thread(Pump); rd.IsBackground = true; rd.Start(_p.StandardOutput);
                Thread re = new Thread(PumpErr); re.IsBackground = true; re.Start(_p.StandardError);
                string init = Rpc("initialize", "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{}," +
                    "\"clientInfo\":{\"name\":\"zquick\",\"version\":\"3.5\"}}", 20);
                if (init == null) { Kill(); return "initialize sem resposta (20s)"; }
                Notify("notifications/initialized");
                return null;
            } catch (Exception ex) { Kill(); return ex.Message; }
        }
        void Pump(object o) { StreamReader sr = (StreamReader)o; try { while (true) { string l = sr.ReadLine(); if (l == null) break; if (l.Trim().Length > 0) _q.Enqueue(l); } } catch { } }
        void PumpErr(object o) { try { StreamReader sr = (StreamReader)o; while (sr.ReadLine() != null) { } } catch { } }
        void Send(string json) { try { _in.WriteLine(json); } catch { } }
        void Notify(string method) { Send("{\"jsonrpc\":\"2.0\",\"method\":" + J(method) + "}"); }

        // request/response com casamento por id; notificacoes do servidor sao descartadas
        public string Rpc(string method, string paramsJson, int timeoutSec) {
            int id; lock (_idLock) { id = ++_id; }
            Send("{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"method\":" + J(method) + ",\"params\":" + (string.IsNullOrEmpty(paramsJson) ? "{}" : paramsJson) + "}");
            var sw = System.Diagnostics.Stopwatch.StartNew();
            string d;
            while (sw.Elapsed.TotalSeconds < timeoutSec) {
                while (_q.TryDequeue(out d)) {
                    Dictionary<string, object> m = MJ.Parse(d) as Dictionary<string, object>;
                    if (m == null) continue;
                    object iv;
                    if (!m.TryGetValue("id", out iv)) continue;
                    if (iv is double && (int)(double)iv == id) return d;
                }
                if (_p == null || _p.HasExited) return null;
                Thread.Sleep(25);
            }
            return null;
        }

        public string ListTools() {   // null = ok; popula Tools com JSON anthropic pronto
            string r = Rpc("tools/list", "{}", 20);
            if (r == null) return "tools/list sem resposta";
            Dictionary<string, object> root = MJ.Parse(r) as Dictionary<string, object>;
            Dictionary<string, object> res = root != null ? H.O(root, "result") : null;
            object tv;
            List<object> tools = res != null && res.TryGetValue("tools", out tv) ? tv as List<object> : null;
            if (tools == null) return "resposta de tools/list inesperada";
            int n = 0;
            foreach (object x in tools) {
                Dictionary<string, object> t = x as Dictionary<string, object>;
                if (t == null) continue;
                string nm = H.S(t, "name"); if (string.IsNullOrEmpty(nm)) continue;
                string desc = H.S(t, "description"); if (desc == null) desc = "MCP tool";
                object sv;
                Dictionary<string, object> schema = t.TryGetValue("inputSchema", out sv) ? sv as Dictionary<string, object> : null;
                if (schema == null) schema = new Dictionary<string, object>();
                string pref = "mcp_" + Name + "_" + nm;
                string tj = "{\"name\":" + J(pref)
                    + ",\"description\":" + J("[MCP " + Name + "] " + desc)
                    + ",\"input_schema\":" + ToJson(StripPattern(schema)) + "}";
                Tools.Add(new string[] { pref, tj, nm });
                if (++n >= 40) break;
            }
            return n == 0 ? "nenhuma tool no servidor" : null;
        }

        public string Call(string realName, string argsJson, int timeoutSec) {
            string r = Rpc("tools/call", "{\"name\":" + J(realName) + ",\"arguments\":" + (string.IsNullOrEmpty(argsJson) ? "{}" : argsJson) + "}", timeoutSec);
            if (r == null) return "ERRO MCP: sem resposta em " + timeoutSec + "s";
            Dictionary<string, object> root = MJ.Parse(r) as Dictionary<string, object>;
            Dictionary<string, object> err = root != null ? H.O(root, "error") : null;
            if (err != null) return "ERRO MCP: " + Trunc(ToJson(err), 300);
            Dictionary<string, object> res = root != null ? H.O(root, "result") : null;
            object cv;
            List<object> content = res != null && res.TryGetValue("content", out cv) ? cv as List<object> : null;
            var sb = new StringBuilder();
            if (content != null) foreach (object x in content) {
                Dictionary<string, object> c = x as Dictionary<string, object>;
                if (c == null) continue;
                if (H.S(c, "type") == "text") { string tx = H.S(c, "text"); if (tx != null) { sb.Append(tx); sb.Append('\n'); } }
            }
            string o2 = sb.ToString().Trim();
            if (res != null && res.ContainsKey("isError") && res["isError"] is bool && (bool)res["isError"]) o2 = "ERRO MCP: " + o2;
            if (o2.Length == 0) o2 = "(sem texto no resultado)";
            return Trunc(o2, 8000);
        }

        public void Kill() {
            try { if (_in != null) _in.Close(); } catch { }
            try { if (_p != null) { if (!_p.HasExited) _p.Kill(); _p.Dispose(); } } catch { }
            _p = null; _in = null;
            string d; while (_q.TryDequeue(out d)) { }
        }
    }

    string _mcpCfg;                                          // json cru de cfg.mcpServers
    readonly List<McpSrv> _mcp = new List<McpSrv>();
    volatile bool _mcpTried;
    // skills (Onda 5): playbooks .md ao lado do app — o PS parseia e entrega {name,file}[]
    readonly List<string[]> _skills = new List<string[]>();  // {nome, caminho}
    volatile int _subDepth;   // >0 = dentro do subagente de leitura: delta/sources/note do sub NAO poluem o card

    public void SetMcpConfig(string json) { _mcpCfg = json; }

    public int McpInit() {   // idempotente: sobe servidores + tools/list; retorna total de tools MCP
        if (_mcpTried) return McpToolCount();
        _mcpTried = true;
        if (!string.IsNullOrEmpty(_mcpCfg)) {
            Dictionary<string, object> cfg = MJ.Parse(_mcpCfg) as Dictionary<string, object>;
            if (cfg != null) foreach (KeyValuePair<string, object> kv in cfg) {
                if (_mcp.Count >= 6) break;
                Dictionary<string, object> sc = kv.Value as Dictionary<string, object>;
                if (sc == null) continue;
                string cmd = H.S(sc, "command");
                if (string.IsNullOrEmpty(cmd)) { Emit("note", "mcp " + kv.Key + ": sem 'command' no config"); continue; }
                object av;
                List<object> argList = sc.TryGetValue("args", out av) ? av as List<object> : null;
                var argsB = new StringBuilder(); int ai = 0;
                if (argList != null) foreach (object a2 in argList) { if (ai++ > 0) argsB.Append(' '); argsB.Append('"').Append(Convert.ToString(a2).Replace("\"", "\\\"")).Append('"'); }
                McpSrv srv = new McpSrv(); srv.Name = kv.Key;
                string err = srv.Start(cmd, argsB.ToString(), sc.ContainsKey("env") ? ToJson(sc["env"]) : null);
                if (err == null) err = srv.ListTools();
                if (err != null) { Emit("note", "mcp " + kv.Key + " indisponível: " + err); srv.Kill(); }
                else { _mcp.Add(srv); Emit("note", "mcp " + kv.Key + ": " + srv.Tools.Count + " tool(s) prontas"); }
            }
        }
        return McpToolCount();
    }

    public int McpToolCount() { int c = 0; foreach (McpSrv s in _mcp) c += s.Tools.Count; return c; }

    public string McpToolSchema(string prefixedName) {
        foreach (McpSrv s in _mcp) foreach (string[] t in s.Tools) if (t[0] == prefixedName) return t[1];
        return null;
    }

    public string McpCall(string prefixedName, string argsJson) {
        foreach (McpSrv s in _mcp) foreach (string[] t in s.Tools)
            if (t[0] == prefixedName) return s.Call(t[2], argsJson, 90);
        return "ERRO MCP: tool desconhecida: " + prefixedName;
    }

    public void ShutdownMcp() { foreach (McpSrv s in _mcp) s.Kill(); _mcp.Clear(); }

    // skills (Onda 5): lista {name,file} entregue pelo PS (o parser de frontmatter vive la')
    public void SetSkills(string json) {
        _skills.Clear();
        List<object> arr = MJ.Parse(json) as List<object>;
        if (arr == null) return;
        foreach (object o in arr) {
            Dictionary<string, object> d = o as Dictionary<string, object>;
            if (d == null) continue;
            string n = H.S(d, "name"); string f = H.S(d, "file");
            if (!string.IsNullOrEmpty(n) && !string.IsNullOrEmpty(f)) _skills.Add(new string[] { n, f });
        }
    }
    public int SkillCount() { return _skills.Count; }
    // util p/ testes: a tool esta' declarada no body que seria enviado agora?
    public bool ToolDeclared(string name) { return BuildBody("sys").Contains("\"name\":\"" + name + "\""); }

    // remove "pattern" recursivo do schema (Z.ai rejeita com erro 1210)
    static object StripPattern(object o) {
        Dictionary<string, object> d = o as Dictionary<string, object>;
        if (d != null) {
            Dictionary<string, object> nd = new Dictionary<string, object>();
            foreach (KeyValuePair<string, object> kv in d) if (kv.Key != "pattern") nd[kv.Key] = StripPattern(kv.Value);
            return nd;
        }
        List<object> l = o as List<object>;
        if (l != null) { List<object> nl = new List<object>(); foreach (object x in l) nl.Add(StripPattern(x)); return nl; }
        return o;
    }

    string BuildBody(string sys) { return BuildBody(sys, true); }
    // v3.11: withTools=false => "tools":[] (rodada de fechamento — o modelo so'
    // responde texto; mesmo formato que o subagente ja' usa no relatorio final)
    string BuildBody(string sys, bool withTools) {
        var b = new StringBuilder();
        string vm = !_auto ? _model : (_useBig ? _big : (_useVision ? (_vision ?? _big) : _model));
        // system como array + cache_control no prefixo gordo: sonda 13/10 provou
        // cache real no endpoint Z.ai (1550 -> 14 input tokens, 1536 cache_read)
        string sysJson = _cacheCtl
            ? "[{\"type\":\"text\",\"text\":" + J(sys) + ",\"cache_control\":{\"type\":\"ephemeral\"}}]"
            : J(sys);
        var tools = new List<string>();
        if (_srvSearch)
            // server tool Z.ai: declarar no tools faz o SERVIDOR rodar web_search_prime
            // dentro do /v1/messages (blocos server_tool_use/tool_result chegam no
            // stream; usage web_search_requests: 0 nas sondas — sem cobranca aparente)
            tools.Add("{\"type\":\"web_search_20250305\",\"name\":\"web_search\"}");
        else
            tools.Add("{\"name\":\"web_search\",\"description\":\"Search the web for current information (news, prices, scores, versions, facts that may have changed). Returns numbered results with title, URL and snippet.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"the search query, in the same language as the question\"}},\"required\":[\"query\"]}}");
        tools.Add("{\"name\":\"fetch_page\",\"description\":\"Fetch one web page by absolute http(s) URL and return its readable text (truncated). Use to read details of a promising search result.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"absolute http or https URL\"}},\"required\":[\"url\"]}}");
        tools.Add("{\"name\":\"file_list\",\"description\":\"List files and folders of a directory on the user's Windows.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute directory path (empty = user home)\"}}}}");
        tools.Add("{\"name\":\"file_read\",\"description\":\"Read a text file from the user's Windows (first 8000 chars).\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute file path\"}},\"required\":[\"path\"]}}");
        tools.Add("{\"name\":\"file_grep\",\"description\":\"Search INSIDE files of a folder (content search, recursive): returns the matching lines as file:line: text. Use it to find where a term/name/config is defined or used — far cheaper than reading files one by one.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"text or regular expression to find in file contents\"},\"path\":{\"type\":\"string\",\"description\":\"absolute folder path to search in (empty = user home)\"},\"glob\":{\"type\":\"string\",\"description\":\"filename filter like *.ps1 or *.txt (empty = all files)\"}},\"required\":[\"pattern\"]}}");
        tools.Add("{\"name\":\"file_edit\",\"description\":\"Surgically replace one exact text snippet inside an existing file (find & replace; the user approves a red/green diff). old_str must match the file EXACTLY, including indentation and line breaks — include surrounding lines to make it unique, or set replace_all:true. new_str empty deletes the snippet. ALWAYS prefer this over file_write for changing an existing file. Previous version kept as <file>.zquick.bak.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute file path\"},\"old_str\":{\"type\":\"string\",\"description\":\"exact text to replace, copied from file_read (indentation counts)\"},\"new_str\":{\"type\":\"string\",\"description\":\"replacement text (empty string = delete old_str)\"},\"replace_all\":{\"type\":\"boolean\",\"description\":\"true = replace every occurrence of old_str\"}},\"required\":[\"path\",\"old_str\",\"new_str\"]}}");
        tools.Add("{\"name\":\"file_write\",\"description\":\"Create or overwrite a whole text file (any extension). For CHANGING an existing file prefer file_edit (surgical, cheaper, shows a diff). Requires the user's approval; previous version kept as <file>.zquick.bak; result verified by re-reading.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute file path\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}");
        tools.Add("{\"name\":\"file_move\",\"description\":\"Move or RENAME a file or folder. Requires the user's approval in the app window.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"src\":{\"type\":\"string\",\"description\":\"absolute source path\"},\"dest\":{\"type\":\"string\",\"description\":\"absolute destination path (full new name)\"}},\"required\":[\"src\",\"dest\"]}}");
        tools.Add("{\"name\":\"file_delete\",\"description\":\"Send a file or folder to the Recycle Bin. Requires the user's approval in the app window.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"]}}");
        tools.Add("{\"name\":\"note_add\",\"description\":\"Save a markdown note to the user's notes folder (Documents/ZQuick-Notas). Runs without approval.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"content\":{\"type\":\"string\",\"description\":\"markdown body\"}},\"required\":[\"title\",\"content\"]}}");
        tools.Add("{\"name\":\"memory_save\",\"description\":\"Save ONE durable fact about the user, their machines, servers, paths or preferences to the persistent memory, loaded into EVERY future conversation. Use for things you would otherwise need to ask again (e.g. 'meu servidor de planilhas é 192.168.0.99', 'prefiro respostas curtas'). Do NOT save conversation-specific content. Runs without approval.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"fact\":{\"type\":\"string\",\"description\":\"the fact, 1-2 sentences in Portuguese, self-contained\"}},\"required\":[\"fact\"]}}");
        tools.Add("{\"name\":\"run_ps\",\"description\":\"Run a PowerShell command on the user's Windows (open apps, system settings, processes, checks...). Commands run in ONE PERSISTENT session per conversation: current directory, variables and functions SURVIVE between calls (set $x in one call, read $x in the next). ALWAYS shown to the user for approval before running. Optional 'timeout' in seconds (5-120, default 60). Do NOT delete user files with this (use file_delete). Keep commands short.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"PowerShell command line\"},\"timeout\":{\"type\":\"number\",\"description\":\"max seconds to wait, 5-120 (default 60)\"}},\"required\":[\"command\"]}}");
        tools.Add("{\"name\":\"ask_user\",\"description\":\"Ask the user multiple-choice questions (ONE or up to 4 at once) and wait for their picks. Use when the task has ambiguity or decisions the user should make (which approach, which file, scope, taste, a risky trade-off). Do NOT use it for anything you can decide yourself or verify with file_list/web_search, and never ask the same question twice. Send one question via question/header/multiSelect/options, or several via questions:[{question, header, multiSelect, options}] (max 4). 2-4 options each; each option: short label (1-5 words) + description of what it implies; optional 'preview' (mono text — code snippet, mockup or config shown beside the option; use it when comparing concrete artifacts). The user can always answer free text instead.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"the complete question in Portuguese, specific, ending with ?\"},\"header\":{\"type\":\"string\",\"description\":\"short chip label, max ~12 chars\"},\"multiSelect\":{\"type\":\"boolean\",\"description\":\"true = the user may pick several options\"},\"options\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"label\":{\"type\":\"string\",\"description\":\"concise option, 1-5 words\"},\"description\":{\"type\":\"string\",\"description\":\"what choosing this implies\"},\"preview\":{\"type\":\"string\",\"description\":\"mono preview shown beside the option (code/mockup/config)\"}},\"required\":[\"label\"]}},\"questions\":{\"type\":\"array\",\"description\":\"alternative: up to 4 questions at once\",\"items\":{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\"},\"header\":{\"type\":\"string\"},\"multiSelect\":{\"type\":\"boolean\"},\"options\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"label\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"preview\":{\"type\":\"string\"}},\"required\":[\"label\"]}}},\"required\":[\"question\",\"options\"]}}},\"required\":[\"question\",\"options\"]}}");
        tools.Add("{\"name\":\"plan\",\"description\":\"Propose a multi-step plan of ACTIONS (create/edit/move/delete files, run commands) and wait for the user's approval ONCE. Approved: every listed action runs in this turn WITHOUT individual confirmations. Rejected: nothing runs. Use when the task needs 3+ steps that alter files or the system. Do NOT use it for read-only exploration or single actions.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"short plan title in Portuguese\"},\"steps\":{\"type\":\"array\",\"description\":\"ordered steps, each short (verb + object)\",\"items\":{\"type\":\"string\"}}},\"required\":[\"title\",\"steps\"]}}");
        tools.Add("{\"name\":\"research\",\"description\":\"Spawn a READ-ONLY subagent with its own separate context to investigate and report back a dense summary (paths, values, file:line snippets, URLs). The subagent does NOT see this conversation — write a self-contained task. Use for wide scans (many files/folders, repeated web searches) so this conversation stays clean; NOT worth it for a single quick file_read/web_search.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"complete, self-contained research task in Portuguese: what to find, where to look, what to report\"},\"hint\":{\"type\":\"string\",\"description\":\"optional: where to start (folder path, URL or search term)\"}},\"required\":[\"task\"]}}");
        if (_skills.Count > 0)
            tools.Add("{\"name\":\"skill_read\",\"description\":\"Load the full instructions of one SKILL (a named playbook saved by the user). Call it when the task matches a skill listed in the system prompt, then follow those instructions.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"skill name exactly as listed in the system prompt\"}},\"required\":[\"name\"]}}");
        if (_auto && !_useBig && !_useVision) // vision-routed nao oferece escalate: o big nao enxerga
            tools.Add("{\"name\":\"escalate\",\"description\":\"Hand the question over to the larger, smarter model. Call this when the user's question needs deep reasoning, careful multi-step analysis, long code, or when you feel your answer would be noticeably better from a stronger model. Do NOT call it for quick factual questions, simple lookups, translations or chit-chat.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"reason\":{\"type\":\"string\",\"description\":\"short reason in Portuguese\"}}}}");
        // tools MCP (Onda 4): entram ANTES do cache_control (que cai na ultima =
        // cobre o prefixo inteiro); a lista e' estavel dentro da conversa
        if (_mcp.Count > 0) foreach (McpSrv s in _mcp) foreach (string[] t in s.Tools) tools.Add(t[1]);
        if (_cacheCtl) {
            // cache_control na ULTIMA tool: o cache cobre o prefixo inteiro (system+tools)
            int last = tools.Count - 1;
            tools[last] = tools[last].Substring(0, tools[last].Length - 1) + ",\"cache_control\":{\"type\":\"ephemeral\"}}";
        }
        if (!withTools) tools.Clear();   // fechamento do turno: "tools":[] — so' texto sai
        b.Append("{\"model\":\"").Append(vm)
         .Append("\",\"max_tokens\":").Append(Math.Max(_maxTokens, _mtNeed))
         .Append(",\"stream\":true,\"system\":").Append(sysJson)
         .Append(",\"tools\":[").Append(string.Join(",", tools.ToArray()))
         .Append("],\"messages\":[");
        var msgs = new List<string>(_history);
        if (_specInject != null && msgs.Count > 0) {
            // costura a pre-busca como bloco extra no fim da ultima msg do usuario (round 0)
            string last = msgs[msgs.Count - 1];
            int p = last.LastIndexOf("]}");   // terminador estrutural de content-array + objeto
            if (p > 0) msgs[msgs.Count - 1] = last.Substring(0, p) + ",{\"type\":\"text\",\"text\":" + J(_specInject) + "}]}";
            _specInject = null;   // so o round 0
        }
        b.Append(string.Join(",", msgs)).Append("]}");
        return b.ToString();
    }

    List<Blk> StreamOnce(string body, CancellationToken ct, out string stop, out bool streamed) {
        stop = "end_turn"; streamed = false;
        var blocks = new Dictionary<int, Blk>();
        var req = new HttpRequestMessage(HttpMethod.Post, _base + "/v1/messages");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + _key);
        req.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        string txt = "";
        var swt = System.Diagnostics.Stopwatch.StartNew(); double ttft = -1;
        using (HttpResponseMessage resp = _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).GetAwaiter().GetResult()) {
            if (!resp.IsSuccessStatusCode) {
                txt = ReadAll(resp);
                throw new Exception("HTTP " + (int)resp.StatusCode + " " + Trunc(txt, 300));
            }
            using (Stream st = resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
            using (StreamReader sr = new StreamReader(st, Encoding.UTF8)) {
                string line;
                // watchdog: stream calado (nenhuma linha em 120s) derruba a conexao —
                // sem isto um SSE morto deixa o turno pendurado para sempre (HttpClient
                // .Timeout nao cobre a leitura do body depois dos headers)
                bool stalled = false;
                var stall = new Timer(delegate { stalled = true; try { resp.Dispose(); } catch {} }, null, TimeSpan.FromSeconds(120), TimeSpan.FromMilliseconds(-1));
                try {
                    while ((line = sr.ReadLine()) != null) {
                        try { stall.Change(TimeSpan.FromSeconds(120), TimeSpan.FromMilliseconds(-1)); } catch {}
                        if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
                        if (!line.StartsWith("data:")) continue;
                        string data = line.Substring(5).TrimStart();
                        if (data == "[DONE]") break;
                        Dictionary<string, object> root = MJ.Parse(data) as Dictionary<string, object>;
                        if (root == null) continue;
                        string typ = H.S(root, "type");
                        if (typ == "content_block_start") {
                            int idx = (int)H.N(root, "index");
                            Dictionary<string, object> cb = H.O(root, "content_block");
                            string k = H.S(cb, "type");
                            Blk blk = new Blk(); blk.Kind = k;
                            if (k == "tool_use" || k == "server_tool_use") {
                                blk.Id = H.S(cb, "id"); blk.Name = H.S(cb, "name");
                                Dictionary<string, object> inpd = H.O(cb, "input");
                                if (inpd != null && inpd.Count > 0) blk.Input.Append(ToJson(inpd));   // server tool pode entregar o input inteiro no start
                            }
                            else if (k == "tool_result") {   // resultado da busca server-side (vem DENTRO da msg do assistente)
                                blk.Raw = ToJson(cb);                 // volta cru pro historico na proxima ida
                                HarvestSources(H.S(cb, "content"));   // "[[{title,link,content}]]" -> rodape Fontes
                            }
                            blocks[idx] = blk;
                        } else if (typ == "content_block_stop") {
                            int idx = (int)H.N(root, "index");
                            Blk blk;
                            if (blocks.TryGetValue(idx, out blk)) {
                                if (blk.Kind == "text" && !blk.Trace && !blk.Live && blk.Text.Length > 0) {
                                    if (SrvTrace(blk.Text.ToString())) blk.Trace = true;   // bloco curto sintetizado
                                    else { blk.Live = true; if (_subDepth == 0) Emit("delta", blk.Text.ToString()); }   // bloco curto que comeca com '*': decide so' no fim
                                }
                                if (blk.Kind == "server_tool_use") {   // loga a query real da busca server
                                    Dictionary<string, object> sq = MJ.Parse(blk.Input.ToString()) as Dictionary<string, object>;
                                    string q2 = sq != null ? H.S(sq, "search_query") : null; if (q2 == null && sq != null) q2 = H.S(sq, "query");
                                    if (_subDepth == 0) Emit("status", "\U0001F50D " + (string.IsNullOrEmpty(q2) ? (blk.Name ?? "busca server") : q2));
                                }
                            }
                        } else if (typ == "content_block_delta") {
                            int idx = (int)H.N(root, "index");
                            Blk blk;
                            if (!blocks.TryGetValue(idx, out blk)) continue;
                            Dictionary<string, object> del = H.O(root, "delta");
                            string dk = H.S(del, "type");
                            if (dk == "text_delta") {
                                string tx = H.S(del, "text"); if (tx == null) tx = "";
                                if (ttft < 0) { ttft = swt.Elapsed.TotalSeconds; if (_subDepth == 0) Emit("note", string.Format("1º token em {0:0.0}s", ttft)); }
                                streamed = true;
                                blk.Text.Append(tx);
                                if (blk.Kind == "text") {
                                    if (blk.Live && _subDepth == 0) Emit("delta", tx);
                                    else if (!blk.Trace) {
                                        // filtro dos blocos SINTETIZADOS pelo servidor Z.ai: o banner
                                        // "**<globo> Z.ai Built-in Tool**" e o dump "**Output:** **web_search_prime
                                        // _result_summary:** [{...}" — nao vai pro card nem pro historico
                                        string sofar = blk.Text.ToString();
                                        if (!sofar.StartsWith("*")) { blk.Live = true; if (_subDepth == 0) Emit("delta", sofar); }
                                        else if (sofar.Length >= 24) {
                                            if (SrvTrace(sofar)) blk.Trace = true;
                                            else { blk.Live = true; if (_subDepth == 0) Emit("delta", sofar); }
                                        }
                                    }
                                }
                            } else if (dk == "input_json_delta") {
                                string pj = H.S(del, "partial_json"); if (pj != null) blk.Input.Append(pj);
                            }
                        } else if (typ == "message_delta") {
                            Dictionary<string, object> md = H.O(root, "delta");
                            string srn = md == null ? null : H.S(md, "stop_reason");
                            if (srn != null) stop = srn;
                        }
                    }
                } catch (Exception) {
                    if (stalled && !ct.IsCancellationRequested) throw new Exception("stream parado 120s sem dados — interrompido (o texto que já chegou ficou na resposta)");
                    throw;
                } finally { try { stall.Dispose(); } catch {} }
            }
        }
        var list = new List<Blk>();
        for (int i = 0; blocks.ContainsKey(i); i++) list.Add(blocks[i]);
        return list;
    }

    static string ReadAll(HttpResponseMessage r) {
        try {
            using (Stream st = r.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
            using (StreamReader sr = new StreamReader(st, Encoding.UTF8)) return sr.ReadToEnd();
        } catch { return ""; }
    }

    string BlkJson(Blk b) {
        if (b.Kind == "text") {
            if (b.Trace || b.Text.Length == 0) return null;   // banner Z.ai / texto vazio: fora do historico
            return "{\"type\":\"text\",\"text\":" + J(b.Text.ToString()) + "}";
        }
        if (b.Kind == "thinking") return null;   // raciocinio interno: nunca reenvia
        if (b.Kind == "server_tool_use" || b.Kind == "tool_result") return b.Raw;   // bloco gerado pelo servidor: volta como veio
        string inp = b.Input.ToString().Trim(); if (inp.Length == 0) inp = "{}";
        return "{\"type\":\"tool_use\",\"id\":" + J(b.Id) + ",\"name\":" + J(b.Name) + ",\"input\":" + inp + "}";
    }

    // ---------- tools ----------
    // Cadeia de fallback: RSS (estavel) -> HTML (se layout mudar, este quebra primeiro) -> zai (quando houver saldo).
    string DoSearch(string q, CancellationToken ct, List<string> sources) {
        string[] chain = _search == "zai" ? new string[] { "zai", "rss", "html" } : new string[] { "rss", "html", "zai" };
        string lastErr = null;
        foreach (string e in chain) {
            try {
                sources.Clear();
                string r = null;
                if (e == "rss") r = BingRssSearch(q, ct, sources);
                else if (e == "html") r = BingSearch(q, ct, sources);
                else r = ZaiSearch(q, ct, sources);
                if (r != null) return r;
            } catch (Exception ex) { lastErr = ex.Message; }
        }
        return "Search unavailable (" + (lastErr ?? "no results") + "). Answer from your own knowledge and clearly say you could not search the web right now.";
    }

    string BingRssSearch(string q, CancellationToken ct, List<string> sources) {
        string xml = HttpGet("https://www.bing.com/search?q=" + Uri.EscapeDataString(q) + "&format=rss&setlang=pt&count=12", ct, 15);
        var res = new List<string>(); int n = 0;
        foreach (Match m in RxItem.Matches(xml)) {
            string url = System.Net.WebUtility.HtmlDecode(m.Groups[2].Value).Trim();
            if (!url.StartsWith("http")) continue;
            string title = Strip(System.Net.WebUtility.HtmlDecode(m.Groups[1].Value));
            string snip = Strip(System.Net.WebUtility.HtmlDecode(m.Groups[3].Value));
            n++;
            res.Add("[" + n + "] " + title + "\nURL: " + url + (snip.Length > 0 ? "\n" + Trunc(snip, 260) : ""));
            sources.Add(SourceJson(title, url));
            if (n >= 6) break;
        }
        if (n == 0) return null;
        return "Web search results (Bing) for \"" + q + "\":\n\n" + string.Join("\n\n", res);
    }

    string BingSearch(string q, CancellationToken ct, List<string> sources) {
        string html = HttpGet("https://www.bing.com/search?q=" + Uri.EscapeDataString(q) + "&setlang=pt&count=12", ct, 15);
        html = System.Net.WebUtility.HtmlDecode(html);
        var ms = RxAlgo.Matches(html); if (ms.Count == 0) ms = RxH2.Matches(html);
        var res = new List<string>(); int n = 0;
        foreach (Match m in ms) {
            string url = UnwrapBing(m.Groups[1].Value);
            if (url == null || url.Length < 10) continue;
            Uri uo; bool uok = Uri.TryCreate(url, UriKind.Absolute, out uo);
            if (uok && (uo.Host.EndsWith("bing.com") || uo.Host.EndsWith("microsoft.com"))) continue;
            string title = Strip(m.Groups[2].Value);
            Match pm = RxP.Match(m.Groups.Count > 3 ? m.Groups[3].Value : "");
            string snip = pm.Success ? Strip(pm.Groups[1].Value) : "";
            n++;
            res.Add("[" + n + "] " + title + "\nURL: " + url + (snip.Length > 0 ? "\n" + Trunc(snip, 260) : ""));
            sources.Add(SourceJson(title, url));
            if (n >= 6) break;
        }
        if (n == 0) return null;
        return "Web search results (Bing) for \"" + q + "\":\n\n" + string.Join("\n\n", res);
    }

    string ZaiSearch(string q, CancellationToken ct, List<string> sources) {
        string body = "{\"tool\":\"web_search\",\"messages\":[{\"role\":\"user\",\"content\":" + J(q) + "}],\"stream\":false}";
        var req = new HttpRequestMessage(HttpMethod.Post, _native + "/tools");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + _key);
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        using (HttpResponseMessage resp = _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).GetAwaiter().GetResult()) {
            string txt = ReadAll(resp);
            if (!resp.IsSuccessStatusCode) throw new Exception("HTTP " + (int)resp.StatusCode + " " + Trunc(txt, 200));
            var res = new List<string>(); int n = 0;
            Dictionary<string, object> root = MJ.Parse(txt) as Dictionary<string, object>;
            System.Collections.IEnumerable arr = root != null && root.ContainsKey("search_results") ? root["search_results"] as System.Collections.IEnumerable : null;
            if (arr != null) {
                foreach (object ito in arr) {
                    Dictionary<string, object> it = ito as Dictionary<string, object>;
                    if (it == null) continue;
                    string title = H.S(it, "title"); if (title == null) title = "";
                    string url = H.S(it, "url"); if (url == null) url = H.S(it, "link"); if (url == null) url = "";
                    string sn = H.S(it, "snippet"); if (sn == null) sn = "";
                    n++;
                    res.Add("[" + n + "] " + title + "\nURL: " + url + (sn.Length > 0 ? "\n" + Trunc(sn, 260) : ""));
                    sources.Add(SourceJson(title, url));
                    if (n >= 6) break;
                }
            }
            if (n == 0) return null;
            return "Web search results for \"" + q + "\":\n\n" + string.Join("\n\n", res);
        }
    }

    string DoFetch(string url, CancellationToken ct) {
        try {
            if (string.IsNullOrEmpty(url) || !(url.StartsWith("http://") || url.StartsWith("https://"))) return "invalid url";
            string html = HttpGet(url, ct, 12);
            html = Regex.Replace(html, "(?is)<(script|style|svg|head|noscript)[^>]*>.*?</\\1>", " ");
            string text = System.Net.WebUtility.HtmlDecode(Regex.Replace(html, "(?s)<[^>]+>", " "));
            text = Regex.Replace(text, "\\s{2,}", " ").Trim();
            return "PAGE " + url + " (texto):\n" + (text.Length > 6000 ? text.Substring(0, 6000) : text);
        } catch (Exception ex) { return "fetch failed: " + ex.Message; }
    }

    // ---------- acoes locais no Windows (tools dedicadas + run_ps) ----------
    // v3.11: file_edit errou o old_str -> devolve as linhas "quase iguais" do arquivo.
    // Caso real (16/10): o modelo copiou o trecho do output do run_ps, onde o emoji
    // do comentario virou "??" (ANSI vs UTF-8) — o edit nunca casa. Com a dica ele
    // refaz em 1 rodada com o trecho REAL, sem file_read inteiro + tentativa as cegas.
    static string NormLine(string s) {
        var sb = new StringBuilder(); bool q = false, ws = false;
        foreach (char c in s) {
            if (c == '?' || c < 33 || c > 126) { if (!q) { sb.Append('?'); q = true; } ws = false; continue; }   // nao-ASCII/controle -> '?' colapsado
            q = false;
            if (c == ' ' || c == '\t') { if (!ws) { sb.Append(' '); ws = true; } continue; }                      // branco colapsado
            ws = false;
            sb.Append(char.ToLowerInvariant(c));
        }
        return sb.ToString().Trim();
    }
    static string EditMissHint(string t, string oldStr) {
        string firstLine = oldStr.Replace("\r\n", "\n").Split('\n')[0];
        string probe = NormLine(firstLine);
        if (probe.Length < 10)
            return "ERRO: old_str não encontrado no arquivo. Copie o trecho EXATO com file_read (indentação conta) ou localize com file_grep.";
        var sb = new StringBuilder(); int found = 0, lineNo = 1;
        foreach (string ln in t.Replace("\r\n", "\n").Split('\n')) {
            if (NormLine(ln).IndexOf(probe, StringComparison.Ordinal) >= 0) {
                sb.Append("\n").Append(lineNo).Append(": ").Append(Trunc(ln.TrimEnd(), 120));
                if (++found >= 3) break;
            }
            lineNo++;
        }
        return "ERRO: old_str não encontrado no arquivo. DICA: trecho copiado do output do run_ps pode ter acentos/emojis corrompidos (ANSI×UTF-8) — copie do file_read."
            + (found > 0
                ? " Linha(s) equivalente(s) — copie EXATAMENTE daqui (indentação conta):" + sb.ToString()
                : " Copie o trecho EXATO com file_read (indentação conta) ou localize com file_grep.");
    }

    string LocalTool(string name, Dictionary<string, object> inp, CancellationToken ct) {
        string p = H.S(inp, "path");
        try {
            if (name == "skill_read") {   // Onda 5: carrega o corpo da skill (leitura livre)
                string sn = H.S(inp, "name");
                if (string.IsNullOrEmpty(sn)) return "ERRO: informe 'name' (o nome da skill listado no system).";
                foreach (string[] sk in _skills) if (sk[0] == sn) {
                    string t = File.ReadAllText(sk[1]);
                    return "SKILL " + sn + " (" + sk[1] + ") — siga estas instruções:\n" + (t.Length > 8000 ? t.Substring(0, 8000) + "\n…(truncado)" : t);
                }
                var skNames = new StringBuilder();
                foreach (string[] sk in _skills) { if (skNames.Length > 0) skNames.Append(", "); skNames.Append(sk[0]); }
                return "ERRO: skill desconhecida '" + sn + "'. Disponíveis: " + skNames;
            }
            if (name == "file_list") {
                string dir = string.IsNullOrEmpty(p) ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : p;
                if (!Directory.Exists(dir)) return "ERRO: pasta não encontrada: " + dir;
                var sb = new StringBuilder(); sb.Append("Conteúdo de ").Append(dir).Append(":\n");
                int n = 0;
                foreach (string d in Directory.GetDirectories(dir)) { sb.Append("[PASTA]  ").Append(Path.GetFileName(d)).Append('\n'); if (++n >= 300) break; }
                foreach (string f in Directory.GetFiles(dir)) { sb.Append("         ").Append(Path.GetFileName(f)).Append(" (").Append(new FileInfo(f).Length).Append(" B)\n"); if (++n >= 300) { sb.Append("…(limite 300 entradas)\n"); break; } }
                return sb.ToString();
            }
            if (name == "file_read") {
                if (string.IsNullOrEmpty(p) || !File.Exists(p)) return "ERRO: arquivo não encontrado: " + p;
                string t = File.ReadAllText(p);
                return "ARQUIVO " + p + " (" + t.Length + " chars):\n" + (t.Length > 8000 ? t.Substring(0, 8000) + "\n…(truncado)" : t);
            }
            if (name == "file_grep") {
                string pattern = H.S(inp, "pattern");
                string glob = H.S(inp, "glob");
                string dir = string.IsNullOrEmpty(p) ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : p;
                if (string.IsNullOrEmpty(pattern)) return "ERRO: informe 'pattern' (texto ou regex).";
                if (!Directory.Exists(dir)) return "ERRO: pasta não encontrada: " + dir;
                if (string.IsNullOrEmpty(glob)) glob = "*";
                Regex rx;
                try { rx = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.Compiled); }
                catch (Exception) { rx = new Regex(Regex.Escape(pattern), RegexOptions.IgnoreCase | RegexOptions.Compiled); }
                // binarios/imagens: so' gastariam tempo; caps: 50 resultados / 400 arquivos / 8s
                string[] skipExt = new string[] { ".exe",".dll",".sys",".png",".jpg",".jpeg",".gif",".bmp",".webp",".ico",".pdf",".zip",".7z",".rar",".msi",".iso",".woff",".woff2",".ttf",".otf",".mp3",".mp4",".avi",".mkv",".mov",".bin",".dat",".pdb" };
                var sbG = new StringBuilder();
                var pending = new Stack<string>();
                pending.Push(dir);   // pilha manual: pasta sem permissao nao derruba a varredura
                int matches = 0, files = 0;
                var swG = System.Diagnostics.Stopwatch.StartNew();
                while (pending.Count > 0 && matches < 50 && files < 400 && swG.Elapsed.TotalSeconds <= 8) {
                    string d = pending.Pop();
                    string[] subs = null;
                    try { subs = Directory.GetDirectories(d); } catch { }
                    if (subs != null) foreach (string s in subs) {
                        try { if ((File.GetAttributes(s) & FileAttributes.ReparsePoint) == 0) pending.Push(s); } catch { }   // junction = laco infinito
                    }
                    string[] fsArr = null;
                    try { fsArr = Directory.GetFiles(d, glob); } catch { }
                    if (fsArr == null) continue;
                    foreach (string f in fsArr) {
                        if (matches >= 50 || files >= 400 || swG.Elapsed.TotalSeconds > 8) break;
                        files++;
                        if (Array.IndexOf(skipExt, Path.GetExtension(f).ToLowerInvariant()) >= 0) continue;
                        try {
                            if (new FileInfo(f).Length > 2000000) continue;
                            string[] lines = File.ReadAllLines(f);
                            for (int li = 0; li < lines.Length && matches < 50; li++) {
                                if (rx.IsMatch(lines[li])) {
                                    matches++;
                                    string one = lines[li].Trim();
                                    if (one.Length > 160) one = one.Substring(0, 160) + "…";
                                    sbG.Append(f).Append(':').Append(li + 1).Append(": ").Append(one).Append('\n');
                                }
                            }
                        } catch { }
                    }
                }
                if (matches == 0) return "Nenhum resultado de \"" + pattern + "\" em " + dir + " (" + files + " arquivo(s) varridos).";
                return "GREP \"" + pattern + "\" em " + dir + " — " + matches + " linha(s), " + files + " arquivo(s) varridos"
                    + (matches >= 50 ? " (limite 50)" : "") + (files >= 400 ? " (limite 400 arquivos)" : "")
                    + (swG.Elapsed.TotalSeconds > 8 ? " (parou por tempo)" : "") + ":\n" + sbG.ToString();
            }
            if (name == "file_edit") {
                string path = H.S(inp, "path");
                string oldStr = H.S(inp, "old_str"); string newStr = H.S(inp, "new_str");
                object rav; bool replAll = inp != null && inp.TryGetValue("replace_all", out rav) && rav is bool && (bool)rav;
                if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(oldStr)) return "ERRO: informe 'path' e 'old_str' exato (copie do file_read, com indentação; new_str vazio = apagar o trecho).";
                if (!File.Exists(path)) return "ERRO: arquivo não encontrado: " + path;
                string t = File.ReadAllText(path);
                if (t.Length > 2000000) return "ERRO: arquivo grande demais para edição (2 MB).";
                bool hadBom; try { byte[] pb = File.ReadAllBytes(path); hadBom = pb.Length >= 3 && pb[0] == 0xEF && pb[1] == 0xBB && pb[2] == 0xBF; } catch { hadBom = false; }
                int n = CountOcc(t, oldStr);
                if (n == 0) return EditMissHint(t, oldStr);
                if (n > 1 && !replAll) return "ERRO: old_str aparece " + n + "× no arquivo. Inclua linhas de contexto ao redor para ficar único, ou envie \"replace_all\":true.";
                int first = t.IndexOf(oldStr, StringComparison.Ordinal);
                int line = 1; for (int i = 0; i < first; i++) if (t[i] == '\n') line++;
                string full = Path.GetFullPath(path);
                string summ = full + " — " + (replAll ? n + " substituição(ões)" : "1 substituição") + " (linha " + line + ")";
                if (!GateConfirm("file_edit", full, "Editar arquivo", summ, DiffJson(oldStr, newStr), ct)) return "NEGADO pelo usuário.";
                bool bak = false;
                try { if (File.Exists(full)) { File.Copy(full, full + ".zquick.bak", true); bak = true; } } catch { }
                string nt = replAll ? t.Replace(oldStr, newStr ?? "")
                    : t.Substring(0, first) + (newStr ?? "") + t.Substring(first + oldStr.Length);
                File.WriteAllText(full, nt, new UTF8Encoding(hadBom)); // preserva BOM original (5.1 le sem-BOM como ANSI)
                string chk = File.ReadAllText(full);
                string verify = (string.IsNullOrEmpty(newStr) || chk.Contains(newStr)) ? "verificado na re-leitura" : "ATENÇÃO: new_str ausente na re-leitura";
                bool oldGone = !chk.Contains(oldStr) || (newStr != null && newStr.Contains(oldStr));
                return "OK — editado: " + summ + (bak ? " • backup .zquick.bak" : "") + " • " + verify + (oldGone ? "" : " • old_str ainda presente (estava dentro de new_str?)");
            }
            if (name == "file_write") {
                string path = H.S(inp, "path"); string content = H.S(inp, "content") ?? "";
                if (string.IsNullOrEmpty(path)) return "ERRO: path obrigatório";
                string full = Path.GetFullPath(path);
                if (!GateConfirm("file_write", full, "Gravar arquivo", full + "\n(" + content.Length + " caracteres)", null, ct)) return "NEGADO pelo usuário.";
                string d = Path.GetDirectoryName(full);
                if (!Directory.Exists(d)) Directory.CreateDirectory(d);
                bool bak = false;
                try { if (File.Exists(full)) { File.Copy(full, full + ".zquick.bak", true); bak = true; } } catch { }
                bool wb; try { byte[] pb2 = File.Exists(full) ? File.ReadAllBytes(full) : new byte[0]; wb = pb2.Length >= 3 && pb2[0] == 0xEF && pb2[1] == 0xBB && pb2[2] == 0xBF; } catch { wb = false; }
                File.WriteAllText(full, content, new UTF8Encoding(wb)); // preserva BOM se o arquivo ja tinha
                string verify = File.ReadAllText(full) == content ? "verificado na re-leitura" : "ATENÇÃO: re-leitura difere do enviado";
                return "OK — gravado: " + full + (bak ? " (versão anterior em " + Path.GetFileName(full) + ".zquick.bak)" : "") + " • " + verify;
            }
            if (name == "file_move") {
                string src = H.S(inp, "src"), dest = H.S(inp, "dest");
                if (string.IsNullOrEmpty(src) || string.IsNullOrEmpty(dest)) return "ERRO: src e dest obrigatórios";
                if (!File.Exists(src) && !Directory.Exists(src)) return "ERRO: não encontrado: " + src;
                if (File.Exists(dest) || Directory.Exists(dest)) return "ERRO: destino já existe: " + dest;
                if (!GateConfirm("file_move", Path.GetDirectoryName(Path.GetFullPath(dest)), "Mover / renomear", src + "\n→ " + dest, null, ct)) return "NEGADO pelo usuário.";
                if (Directory.Exists(src)) Directory.Move(src, dest); else File.Move(src, dest);
                return "OK — movido/renomeado para " + dest;
            }
            if (name == "file_delete") {
                if (string.IsNullOrEmpty(p) || (!File.Exists(p) && !Directory.Exists(p))) return "ERRO: não encontrado: " + p;
                if (!GateConfirm("file_delete", Path.GetFullPath(p), "Apagar (vai para a Lixeira)", p, null, ct)) return "NEGADO pelo usuário.";
                int rc = Recycle.ToRecycleBin(p);
                return rc == 0 ? "OK — enviado para a Lixeira: " + p : "ERRO: falha ao enviar para a Lixeira (código " + rc + ")";
            }
            if (name == "note_add") {
                string title = H.S(inp, "title"); string content = H.S(inp, "content") ?? "";
                if (string.IsNullOrEmpty(title)) return "ERRO: title obrigatório";
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "ZQuick-Notas");
                Directory.CreateDirectory(dir);
                string fp = Path.Combine(dir, DateTime.Now.ToString("yyyy-MM-dd") + " " + Slug(title) + ".md");
                File.WriteAllText(fp, "# " + title + "\n\n_" + DateTime.Now.ToString("dd/MM/yyyy HH:mm") + " — via ZQuick_\n\n" + content + "\n", new UTF8Encoding(false));
                return "OK — nota salva: " + fp;
            }
            if (name == "memory_save") {
                string fact = H.S(inp, "fact");
                if (string.IsNullOrEmpty(fact)) return "ERRO: informe 'fact' (o fato durável, 1-2 frases).";
                if (string.IsNullOrEmpty(MemPath)) return "ERRO: memória não configurada.";
                string one = "- " + Regex.Replace(fact.Trim(), "\\s+", " ") + " _(" + DateTime.Now.ToString("dd/MM/yy") + ")_";
                var keep = new List<string>();
                if (File.Exists(MemPath)) foreach (string l in File.ReadAllLines(MemPath)) if (l.Trim().Length > 0) keep.Add(l.TrimEnd('\r'));
                foreach (string l in keep) if (l.Contains(fact)) return "OK — já estava na memória: " + Trunc(fact, 120);
                keep.Add(one);
                if (keep.Count > 150) keep.RemoveRange(0, keep.Count - 150);
                File.WriteAllText(MemPath, string.Join("\n", keep.ToArray()) + "\n", new UTF8Encoding(false));
                return "OK — memorizado para as próximas conversas: " + Trunc(fact, 120);
            }
            if (name == "run_ps") {
                string cmd = H.S(inp, "command");
                if (string.IsNullOrEmpty(cmd)) return "ERRO: command obrigatório";
                double tmoD = H.N(inp, "timeout");
                int tmo = tmoD < 0 ? 60 : (int)tmoD;
                if (tmo < 5) tmo = 5; if (tmo > 120) tmo = 120;
                if (!GateConfirm("run_ps", cmd, "Comando PowerShell (sessão persistente)", cmd, null, ct)) return "NEGADO pelo usuário.";
                return RunPsSession(cmd, tmo);
            }
            return "unknown tool";
        } catch (Exception ex) { return "ERRO: " + ex.Message; }
    }

    static string Slug(string s) {
        var sb = new StringBuilder();
        foreach (char c in s) {
            if (char.IsLetterOrDigit(c)) sb.Append(c);
            else if (sb.Length == 0 || sb[sb.Length - 1] != '-') sb.Append('-');
        }
        string r = sb.ToString().Trim('-');
        if (r.Length > 50) r = r.Substring(0, 50);
        return r.Length > 0 ? r : "nota";
    }

    static int CountOcc(string s, string sub) {
        if (string.IsNullOrEmpty(s) || string.IsNullOrEmpty(sub)) return 0;
        int n = 0, i = 0;
        while ((i = s.IndexOf(sub, i, StringComparison.Ordinal)) >= 0) { n++; i += sub.Length; }
        return n;
    }

    // diff vermelho/verde p/ a ConfirmBar: linhas de old_str com "- ", de new_str com "+ "
    static string DiffJson(string oldStr, string newStr) {
        var dj = new StringBuilder(); int cap = 0;
        foreach (string ln in oldStr.Split('\n')) { if (cap++ >= 80) break; if (dj.Length > 0) dj.Append(","); dj.Append("{\"s\":").Append(J("- " + ln.TrimEnd('\r'))).Append("}"); }
        if (!string.IsNullOrEmpty(newStr)) foreach (string ln in newStr.Split('\n')) { if (cap++ >= 80) break; if (dj.Length > 0) dj.Append(","); dj.Append("{\"s\":").Append(J("+ " + ln.TrimEnd('\r'))).Append("}"); }
        if (cap >= 80) dj.Append(",{\"s\":\"…(diff truncado)\"}");
        return "[" + dj.ToString() + "]";
    }

    string RunPs(string cmd) {
        try {
            string ps = string.IsNullOrEmpty(PsExe) ? "powershell.exe" : PsExe;
            string enc = Convert.ToBase64String(Encoding.Unicode.GetBytes("[Console]::OutputEncoding=[Text.Encoding]::UTF8; " + cmd));
            var psi = new System.Diagnostics.ProcessStartInfo(ps, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + enc);
            psi.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
            using (System.Diagnostics.Process pr = System.Diagnostics.Process.Start(psi)) {
                var oTask = pr.StandardOutput.ReadToEndAsync();
                var eTask = pr.StandardError.ReadToEndAsync();
                if (!Task.WaitAll(new Task[] { oTask, eTask }, 60000)) {
                    try { pr.Kill(); } catch {}
                    return "TIMEOUT (60s) — processo encerrado. Saída até ali:\n" + Trunc((oTask.Status == TaskStatus.RanToCompletion ? oTask.Result : "") ?? "", 4000);
                }
                pr.WaitForExit();
                string all = (oTask.Result ?? "") + (string.IsNullOrEmpty(eTask.Result) ? "" : "\n[stderr]\n" + eTask.Result);
                return "EXIT " + pr.ExitCode + "\n" + (all.Trim().Length > 0 ? Trunc(all.Trim(), 8000) : "(sem saída)");
            }
        } catch (Exception ex) { return "ERRO: " + ex.Message; }
    }

    // ---------- sessao de shell persistente (#3) ----------
    // Processo filho vivo com pipes redirecionados: cwd, variaveis, funcoes e
    // imports sobrevivem entre chamadas run_ps da MESMA conversa. Reset/New-Conversation
    // (KillShell) fecha a sessao. Protocolo: comando em base64 UTF-16LE (linha 100%
    // ASCII) + sentinela __ZQEND__<tag>|<cwd>|<exitcode> no fim da saida.
    readonly System.Collections.Concurrent.ConcurrentQueue<string> _shOutQ = new System.Collections.Concurrent.ConcurrentQueue<string>();

    void KillShell() {
        lock (_shLock) {
            try { if (_shIn != null) _shIn.Close(); } catch {}
            try { if (_sh != null) { if (!_sh.HasExited) _sh.Kill(); _sh.Dispose(); } } catch {}
            _sh = null; _shIn = null; _shOut = null; _shErr = null;
            string d; while (_shOutQ.TryDequeue(out d)) { }
            _shErrBuf.Clear();
        }
    }

    void OutPump(object arg) {
        StreamReader sr = (StreamReader)arg;
        try { while (true) { string l = sr.ReadLine(); if (l == null) break; _shOutQ.Enqueue(l); } } catch { }
    }
    void ErrPump(object arg) {
        StreamReader sr = (StreamReader)arg;
        try {
            while (true) {
                string l = sr.ReadLine();
                if (l == null) break;
                lock (_shLock) _shErrBuf.Add(l);
            }
        } catch { }
    }

    bool EnsureShell() {
        lock (_shLock) {
            if (_sh != null && !_sh.HasExited) return true;
            try { if (_sh != null) { if (!_sh.HasExited) _sh.Kill(); _sh.Dispose(); } } catch {}
            string d; while (_shOutQ.TryDequeue(out d)) { }
            _shErrBuf.Clear();
            string ps = string.IsNullOrEmpty(PsExe) ? "powershell.exe" : PsExe;
            var psi = new System.Diagnostics.ProcessStartInfo(ps, "-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass");
            psi.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
            _sh = System.Diagnostics.Process.Start(psi);
            _shIn = _sh.StandardInput; _shOut = _sh.StandardOutput; _shErr = _sh.StandardError;
            _shIn.AutoFlush = true;
            Thread ot = new Thread(OutPump); ot.IsBackground = true; ot.Start(_shOut);
            Thread et = new Thread(ErrPump); et.IsBackground = true; et.Start(_shErr);
        }
        // init: UTF8 nas duas pontas + sem barra de progresso (sujaria o pipe)
        string init = ShRun("[Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference='SilentlyContinue'", 15);
        return !init.StartsWith("TIMEOUT") && !init.StartsWith("ERRO");
    }

    string ShRun(string cmd, int timeoutSec) {
        string tag = Guid.NewGuid().ToString("N").Substring(0, 10);
        string b64 = Convert.ToBase64String(Encoding.Unicode.GetBytes(cmd));
        // PARENTESES no argumento do Invoke-Expression: em modo-argumento o parser
        // quebra "X.Y(Z)" em 2 parametros posicionais (Byte[]) sem eles (repro 13/10)
        string line = "Invoke-Expression ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(\"" + b64
            + "\"))); Write-Output (\"__ZQEND__" + tag + "|\" + (Get-Location).Path + \"|\" + $(if ($null -eq $LASTEXITCODE) { 'ps' } else { $LASTEXITCODE }))";
        string d;
        while (_shOutQ.TryDequeue(out d)) { }   // descarta prompts/sobras do comando anterior
        _shIn.WriteLine(line);
        var sb = new StringBuilder();
        string cwd = null, exit = "ps";
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.Elapsed.TotalSeconds < timeoutSec) {
            string l = null;
            if (_shOutQ.TryDequeue(out l)) {
                if (l.StartsWith("__ZQEND__" + tag + "|")) {
                    int p1 = l.IndexOf('|');
                    int p2 = l.LastIndexOf('|');
                    cwd = p2 > p1 ? l.Substring(p1 + 1, p2 - p1 - 1) : l.Substring(p1 + 1);
                    exit = l.Substring(p2 + 1);
                    break;
                }
                // o filho pwsh ECOA "PS <cwd>> <linha enviada>" (com o base64) e prompts
                // "PS <cwd>>" no stdout redirecionado — fora da saida util
                if (l.StartsWith("PS ") && (l.IndexOf(b64, StringComparison.Ordinal) >= 0 || l.TrimEnd().EndsWith(">"))) continue;
                sb.Append(l).Append('\n');
                if (sb.Length > 60000) { sb.Length = 59990; sb.Append("…\n"); }
            } else Thread.Sleep(25);
        }
        if (cwd == null) {
            KillShell();
            return "TIMEOUT (" + timeoutSec + "s) — sessão reiniciada. Saída até ali:\n" + Trunc(sb.ToString(), 4000);
        }
        Thread.Sleep(30);   // deixa o stderr da vez chegar no pump
        string errs;
        lock (_shLock) { errs = string.Join("\n", _shErrBuf.ToArray()); _shErrBuf.Clear(); }
        return "EXIT " + (exit.Length == 0 ? "ps" : exit)
             + (string.IsNullOrEmpty(errs) ? "" : "\n[stderr]\n" + Trunc(errs, 2000))
             + "\n" + (sb.Length > 0 ? Trunc(sb.ToString().TrimEnd('\n'), 8000) : "(sem saída)")
             + "\n[cwd: " + cwd + "]";
    }

    string RunPsSession(string cmd, int timeoutSec) {
        try {
            if (!EnsureShell()) return "ERRO: sessão persistente não subiu — comando avulso:\n" + RunPs(cmd);
            return "PS (sessão persistente)\n" + ShRun(cmd, timeoutSec);
        } catch (Exception ex) {
            KillShell();
            return "ERRO na sessão (" + ex.Message + ") — comando avulso:\n" + RunPs(cmd);
        }
    }

    // ---------- serializador JSON p/ blocos do servidor (replay) e seeds ----------
    static string ToJson(object o) {
        if (o == null) return "null";
        if (o is string) return J((string)o);
        if (o is bool) return ((bool)o) ? "true" : "false";
        if (o is double) {
            double dd = (double)o;
            if (dd == Math.Floor(dd) && Math.Abs(dd) < 9e15) return ((long)dd).ToString(System.Globalization.CultureInfo.InvariantCulture);
            return dd.ToString("R", System.Globalization.CultureInfo.InvariantCulture);
        }
        if (o is Dictionary<string, object>) {
            var d = (Dictionary<string, object>)o;
            var sb = new StringBuilder("{");
            bool first = true;
            foreach (KeyValuePair<string, object> kv in d) {
                if (!first) sb.Append(",");
                first = false;
                sb.Append(J(kv.Key)).Append(":").Append(ToJson(kv.Value));
            }
            return sb.Append("}").ToString();
        }
        if (o is List<object>) {
            var l = (List<object>)o;
            var sb = new StringBuilder("[");
            for (int i = 0; i < l.Count; i++) { if (i > 0) sb.Append(","); sb.Append(ToJson(l[i])); }
            return sb.Append("]").ToString();
        }
        return J(o.ToString());
    }

    // content do tool_result da busca server: string JSON aninhada "[[{title,link,content,refer}]]"
    void HarvestSources(string content) {
        try {
            if (string.IsNullOrEmpty(content)) return;
            var found = new List<string[]>();
            Collect(MJ.Parse(content), found);
            var sb = new StringBuilder();
            int n = 0;
            foreach (string[] f in found) {
                if (n > 0) sb.Append(",");
                sb.Append(SourceJson(f[0], f[1]));
                if (++n >= 6) break;
            }
            if (n > 0 && _subDepth == 0) Emit("sources", "[" + sb.ToString() + "]");
        } catch { }
    }
    static void Collect(object o, List<string[]> found) {
        if (o == null || found.Count >= 12) return;
        var d = o as Dictionary<string, object>;
        if (d != null) {
            string title = H.S(d, "title"); if (title == null) title = "";
            string url = H.S(d, "link"); if (url == null) url = H.S(d, "url"); if (url == null) url = H.S(d, "link_url");
            if (url != null && url.StartsWith("http")) {
                bool dup = false;
                foreach (string[] x in found) if (x[1] == url) { dup = true; break; }
                if (!dup) found.Add(new string[] { title, url });
            }
            foreach (KeyValuePair<string, object> kv in d) Collect(kv.Value, found);
            return;
        }
        var l = o as List<object>;
        if (l != null) foreach (object x in l) Collect(x, found);
    }

    string HttpGet(string url, CancellationToken ct, int timeoutSec) {
        using (CancellationTokenSource cts = CancellationTokenSource.CreateLinkedTokenSource(ct)) {
            cts.CancelAfter(TimeSpan.FromSeconds(timeoutSec));
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("User-Agent", UA);
            req.Headers.TryAddWithoutValidation("Accept-Language", "pt-BR,pt;q=0.9,en;q=0.8");
            using (HttpResponseMessage r = _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token).GetAwaiter().GetResult()) {
                if (!r.IsSuccessStatusCode) throw new Exception("HTTP " + (int)r.StatusCode + " " + Trunc(url, 80));
                return ReadAll(r);
            }
        }
    }

    string UnwrapBing(string href) {
        if (!(href.StartsWith("http"))) return null;
        Match m = Regex.Match(href, "[?&]u=a1([A-Za-z0-9_-]+)");
        if (!m.Success) return href;
        string b = m.Groups[1].Value.Replace('-', '+').Replace('_', '/');
        while (b.Length % 4 != 0) b += "=";
        try { return Encoding.UTF8.GetString(Convert.FromBase64String(b)); } catch { return null; }
    }

    static string SourceJson(string title, string url) {
        return "{\"title\":" + J(title ?? "") + ",\"url\":" + J(url ?? "") + "}";
    }
    // blocos de texto sintetizados pelo servidor Z.ai na busca server-side (nao sao
    // resposta do modelo): banner "🌐 Z.ai Built-in Tool" e dump "Output:" (probe
    // 13/10: vem como "**Output:**\n**web_search_prime_result_summary:**" — newline,
    // nao espaco, entre os dois)
    static bool SrvTrace(string s) {
        if (string.IsNullOrEmpty(s)) return false;
        if (s.StartsWith("**\U0001F310")) return true;
        if (s.StartsWith("**Output:**")) {
            string rest = s.Substring(11).TrimStart(' ', '\n', '\r', '\t');
            return rest.StartsWith("**web_search");
        }
        return false;
    }
    static string Strip(string s) { return Regex.Replace(s ?? "", "<[^>]+>", "").Trim(); }
    static string Trunc(string s, int n) { if (s == null) s = ""; return s.Length > n ? s.Substring(0, n) + "…" : s; }
    static string J(string s) {
        if (s == null) s = "";
        var sb = new StringBuilder("\"");
        foreach (char c in s) {
            if (c == '"') sb.Append("\\\"");
            else if (c == '\\') sb.Append("\\\\");
            else if (c == '\n') sb.Append("\\n");
            else if (c == '\r') sb.Append("\\r");
            else if (c == '\t') sb.Append("\\t");
            else if (c == '\b') sb.Append("\\b");
            else if (c == '\f') sb.Append("\\f");
            else if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4"));
            else sb.Append(c);
        }
        return sb.Append("\"").ToString();
    }
}

} // namespace
'@
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Add-Type -TypeDefinition $engineCs
} else {
    # Windows PowerShell 5.1: precisa referencia explicita do System.Net.Http
    Add-Type -TypeDefinition $engineCs -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'Microsoft.CSharp.dll', 'System.Net.Http.dll')
}
Log ("engine compilado (PS $($PSVersionTable.PSVersion), PSScriptRoot=$PSScriptRoot)")

# ---------- engine + perfil ativo ----------
$queue = [System.Collections.Concurrent.ConcurrentQueue[ZQuick.UiMsg]]::new()

function Get-ProfileNames { @($cfg.profiles.PSObject.Properties.Name) }
function Get-ActiveProfile {
    $n = [string]$cfg.profile
    if (-not $cfg.profiles.$n) { $n = Get-ProfileNames | Select-Object -First 1 }
    $cfg.profiles.$n
}
# v3.10: a lista de modelos pode carregar "⭐" de recomendado no fim (só exibição) —
# o id limpo (sem estrela) é o que vai pra API
function Clean-ModelId([string]$m) { ([string]$m).Trim() -replace '\s*⭐\s*$','' }
function New-EngineFromProfile {
    $p = Get-ActiveProfile
    $auth = Resolve-ProfileAuth $p
    $model = [string]$cfg.model
    if (-not $model) { $model = 'auto' }
    $models = @(); foreach ($m in @($p.models)) { $models += (Clean-ModelId $m) }
    if ($models -notcontains $model) { $model = 'auto'; if ($models -notcontains 'auto' -and $models.Count -gt 0) { $model = $models[0] } }
    $eng = [ZQuick.Engine]::new($auth.base, $auth.key, $model,
        [string]$p.fastModel, [string]$p.bigModel,
        [int]$cfg.maxTokens, [string]$cfg.searchEngine, $queue, [bool]$cfg.promptCache)
    if ($p.visionModel) { $eng.SetVisionModel([string]$p.visionModel) }
    if ($cfg.maxRounds) { $eng.SetMaxRounds([int]$cfg.maxRounds) }   # v3.11: teto de rodadas por turno (default 16)
    if ($cfg.autoCompact) { $eng.SetAutoCompact($true) }   # v3.13: compacta sem perguntar
    if ($cfg.passthrough) { $eng.SetPassthrough($true) }   # v3.12: passthrough memorizado no json volta ligado
    $eng.MemPath = $memFile
    # Onda 5: skills .md ao lado do app — lista {name,file} entregue ao engine
    # (skill_read so' entra nas tools quando existir pelo menos uma)
    $skillList = Get-SkillList
    if ($skillList -and $skillList.Count -gt 0) {
        try {
            $sj2 = ConvertTo-Json -InputObject (@($skillList | ForEach-Object { @{ name = $_[0]; file = $_[1] } })) -Compress
            $eng.SetSkills($sj2)
        } catch { Log "skills-config: $_" }
    }
    if ($cfg.mcpServers) {
        # Onda 4: servidores MCP sobem no 1o turno (McpInit) — aqui so' entrega o config
        try { $eng.SetMcpConfig(($cfg.mcpServers | ConvertTo-Json -Depth 6 -Compress)) } catch { Log "mcp-config: $_" }
    }
    $rules = @{ runPs = @(); paths = @() }
    if ($cfg.allow) { $rules = $cfg.allow }
    $eng.SetAllowRules([string[]]$rules.runPs, [string[]]$rules.paths)
    # run_ps executa num powershell de verdade: pwsh quando o app roda em pwsh,
    # powershell.exe quando roda como exe PS2EXE (5.1)
    try { $pe = (Get-Process -Id $PID).Path } catch { $pe = $null }
    if (-not $pe -or $pe -notmatch '(?:powershell|pwsh)\.exe$') { $pe = 'powershell.exe' }
    $eng.PsExe = $pe
    $eng
}
# tolerante: sem chave valida no perfil, o app abre e o engine nasce no 1o envio
try { $script:engine = New-EngineFromProfile } catch { $script:engine = $null; Log "engine inicial: $_" }
function Ensure-Engine {
    if ($null -ne $script:engine) { return $true }
    try {
        Reload-Config
        $script:engine = New-EngineFromProfile
        return $true
    } catch {
        Log "ensure-engine: $_"
        if ($StatusText) { $StatusText.Text = 'sem API key — edite zquick.json ao lado do exe e envie de novo' }
        return $false
    }
}

# ---------- system prompt ----------
$sysPrompt = if ($cfg.systemPrompt) { [string]$cfg.systemPrompt } else {
    $dateStr = Get-Date -Format "dddd, dd 'de' MMMM 'de' yyyy"
    ("Hoje é $dateStr. Você é o ZQuick, um assistente de consulta rápida dentro de uma janela compacta no Windows. " +
     "Responda em português do Brasil, direto ao ponto, sem preâmbulos. NUNCA narre seu processo (não escreva o que pretende fazer) — entregue apenas a resposta. " +
     "Para fatos atuais, preços, notícias, placares, datas ou versões, " +
     "faça UMA única chamada de web_search (a query no mesmo idioma da pergunta) e responda DIRETO com os snippets — " +
     "cada ida e volta ao servidor custa ~5s de espera para o usuário, então evite buscar de novo ou abrir páginas. " +
     "Só use fetch_page (ou uma 2ª busca) se os snippets forem claramente insuficientes para responder. " +
     "Ao usar busca, cite as fontes no formato [1], [2] ao final da resposta. " +
     "Sempre que existirem páginas úteis relacionadas (documentação, fontes de dados, leituras), inclua as URLs completas (https://…) na resposta — o app as transforma em links clicáveis. " +
     "Se o usuário anexar imagens (prints), interprete o que foi pedido. " +
     "Arquivo anexado (PDF, DOCX, texto/código) chega DENTRO da mensagem — responda pelo conteúdo anexado, sem procurar no disco. " +
     "Você também pode AGIR no Windows do usuário: file_list/file_read (leitura, sem confirmação), " +
     "file_grep (busca de CONTEÚDO dentro dos arquivos de uma pasta, recursiva — quando quiser achar onde algo está definido ou usado, prefira file_grep a ler arquivo por arquivo), " +
     "file_edit (edição cirúrgica troca-por-troca com diff para o usuário aprovar — para alterar arquivo existente, SEMPRE prefira file_edit a regravar com file_write), " +
     "file_write (cria/sobrescreve arquivo inteiro)/file_move/file_delete (alteram algo — o usuário autoriza cada uma na janela; apagar vai para a Lixeira), " +
     "note_add (grava nota em Documentos\\ZQuick-Notas, sem confirmação), " +
     "memory_save (grava fato DURÁVEL sobre o usuário/suas máquinas/preferências — vale para as próximas conversas; use quando aprender algo que vai precisar de novo e não for específico da conversa atual) " +
     "e run_ps (QUALQUER comando PowerShell — sempre autorizado pelo usuário; os comandos rodam numa SESSÃO PERSISTENTE por conversa: pasta atual, variáveis e funções criadas numa chamada existem na seguinte; " +
     "NUNCA apague arquivos do usuário com run_ps, use file_delete). Se o usuário negar, informe e não repita a mesma ação. " +
     "REGRA DE AUTO-PRESERVAÇÃO: você roda em .local\bin\zquick — é o app oficial E o repo git desta máquina (config, histórico em history\, skills). " +
     "NUNCA execute, reinstale ou 'atualize o ZQuick' a partir de Desktop\Kit-ZQuick (é kit de DISTRIBUIÇÃO com config de placeholder e sem chave — rodá-lo destrói a sessão do usuário), " +
     "NUNCA apague/mova pastas do repo ou de .local, e para reiniciar o app use SOMENTE o zquick.exe/zquick.ps1 do próprio repo. " +
     "Caminho de arquivo ENTRE ASPS na mensagem do usuário = menção (@): o arquivo existe — leia com file_read/file_grep em vez de perguntar o que tem nele. " +
     "Quando a tarefa tiver ambiguidade ou decisão que cabe ao usuário (qual abordagem, qual arquivo, escopo, preferência), pergunte UMA vez com ask_user: " +
     "de 1 a 4 perguntas de uma vez (questions), cada uma com 2-4 opções de label curto + descrição do que a escolha implica; quando estiver comparando artefatos concretos (código, mockup, config), inclua 'preview' nas opções. " +
     "O usuário pode responder texto livre ou cancelar; se cancelar/não responder, decida sozinho a opção mais conservadora e informe — não repita a pergunta. " +
     "Antes de executar 3+ ações que ALTERAM arquivos ou o sistema (criar/editar/mover/apagar, comandos), PROponha com plan {title, steps[]}: o usuário aprova UMA vez e as ações rodam sem confirmação individual; se rejeitar, nada executa — replique o plano ajustado ou pergunte. " +
     "Ao mexer com arquivos, confirme os caminhos com file_list antes. " +
     "Tools com prefixo mcp_ vêm de servidores externos (MCP) configurados pelo usuário — use-as como usaria as built-in quando fizer sentido. " +
     "A tool research dispara um SUBAGENTE de leitura com contexto próprio (ele NÃO vê esta conversa) para investigações amplas — muitos arquivos/pastas ou buscas repetidas: passe uma tarefa autocontida e use o relatório que voltar; para uma leitura/busca única use file_read/web_search direto. " +
     "Quando houver skills listadas no fim deste prompt, são playbooks do usuário: se a tarefa combinar com uma, carregue-a com skill_read ANTES de responder e siga as instruções. " +
     "Formatação leve: negrito e listas simples quando ajudar, nada de títulos grandes.")
}

# ---------- XAML ----------
$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZQuick — busca rápida" Width="860" Height="600" MinWidth="520" MinHeight="360"
        WindowStyle="None" ResizeMode="CanResize" AllowsTransparency="True"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="False"
        Background="#202024" UseLayoutRounding="True" FontFamily="Segoe UI" FontSize="12">
  <!-- Onda 6: moldura própria — a faixa do topo vira a "caption" (arrastável);
       bordas de resize/snap continuam do sistema via WindowChrome -->
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="40" ResizeBorderThickness="6" GlassFrameThickness="1"
                  CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2A30"/>
      <Setter Property="Foreground" Value="#E8E8EC"/>
      <Setter Property="BorderBrush" Value="#3A3A44"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="ChromeBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E8E8EC"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="9,5"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#3A3A44"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Padding="14,10,14,8">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <ComboBox x:Name="ProfileBox" Width="110" FontSize="12" VerticalContentAlignment="Center" ToolTip="Perfil / provedor LLM" WindowChrome.IsHitTestVisibleInChrome="True"/>
          <ComboBox x:Name="ModelBox" Width="135" FontSize="12" Margin="8,0,0,0" VerticalContentAlignment="Center" ToolTip="Modelo" WindowChrome.IsHitTestVisibleInChrome="True"/>
          <Button x:Name="NewBtn" Content="Nova" Margin="8,0,0,0" WindowChrome.IsHitTestVisibleInChrome="True"/>
          <Button x:Name="HistBtn" Content="🕘" Margin="8,0,0,0" ToolTip="Histórico — retomar conversa salva" WindowChrome.IsHitTestVisibleInChrome="True"/>
          <Button x:Name="TopBtn" Content="📌" Margin="8,0,0,0" ToolTip="sempre no topo — manter a janela sobre as outras" WindowChrome.IsHitTestVisibleInChrome="True"/>
          <Button x:Name="PassBtn" Content="⚡" Margin="8,0,0,0" ToolTip="passthrough — aprovar ações (edits/comandos) sem confirmar; clica AQUI para ligar/desligar" WindowChrome.IsHitTestVisibleInChrome="True"/>
          <Button x:Name="SettingsBtn" Content="⚙" Margin="14,0,0,0" ToolTip="Configurações — chaves, janela, aparência, geral" Style="{StaticResource ChromeBtn}"/>
          <Button x:Name="MinBtn" Content="—" ToolTip="ocultar na bandeja (Alt+Q traz de volta)" Style="{StaticResource ChromeBtn}"/>
          <Button x:Name="MaxBtn" Content="▢" ToolTip="maximizar / restaurar" Style="{StaticResource ChromeBtn}"/>
          <Button x:Name="CloseBtn" Content="✕" ToolTip="ocultar na bandeja (sair de verdade: ícone Z → Sair)" Style="{StaticResource ChromeBtn}"/>
        </StackPanel>
        <TextBlock Text="⚡ ZQuick" FontSize="15" FontWeight="SemiBold" Foreground="#E8E8EC" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
    <Border DockPanel.Dock="Bottom">
      <StackPanel>
        <ScrollViewer x:Name="AttachScroll" MaxHeight="76" Visibility="Collapsed" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled" Margin="14,6,14,0">
          <StackPanel x:Name="AttachPanel" Orientation="Horizontal"/>
        </ScrollViewer>
        <Border x:Name="ConfirmBar" Visibility="Collapsed" Background="#3A3A44" CornerRadius="6" Margin="14,6,14,0" Padding="10,8">
          <StackPanel>
            <TextBlock x:Name="ConfirmTitle" Foreground="#E8E8EC" FontWeight="SemiBold" FontSize="12"/>
            <TextBlock x:Name="ConfirmDetail" Foreground="#9A9AA5" FontSize="11" TextWrapping="Wrap"
                       FontFamily="Cascadia Mono, Consolas" Margin="0,4,0,6" MaxHeight="90"/>
            <ScrollViewer x:Name="ConfirmDiffScroll" Visibility="Collapsed" MaxHeight="120" Margin="0,0,0,6"
                          VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                          Background="#16161A" BorderBrush="#3A3A44" BorderThickness="1" Padding="6,4">
              <StackPanel x:Name="ConfirmDiff"/>
            </ScrollViewer>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="ConfirmYes" Content="✅ Executar" FontWeight="SemiBold"/>
              <Button x:Name="ConfirmAlwaysBtn" Content="✔ Sempre" Margin="8,0,0,0"
                      ToolTip="Executar e não perguntar mais para isto (comando exato ou pasta) — grava no zquick.json"/>
              <Button x:Name="ConfirmNo" Content="✕ Negar" Margin="8,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border x:Name="PlanBar" Visibility="Collapsed" Background="#3A3A44" CornerRadius="6" Margin="14,6,14,0" Padding="10,8">
          <StackPanel>
            <TextBlock x:Name="PlanTitle" Foreground="#E8E8EC" FontWeight="SemiBold" FontSize="12" TextWrapping="Wrap"/>
            <ScrollViewer MaxHeight="140" Margin="0,4,0,6" VerticalScrollBarVisibility="Auto"
                          Background="#16161A" BorderBrush="#3A3A44" BorderThickness="1" Padding="6,4">
              <StackPanel x:Name="PlanSteps"/>
            </ScrollViewer>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="PlanYes" Content="✅ Aprovar e executar" FontWeight="SemiBold"/>
              <Button x:Name="PlanNo" Content="✕ Rejeitar" Margin="8,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border x:Name="AskBar" Visibility="Collapsed" Background="#3A3A44" CornerRadius="6" Margin="14,6,14,0" Padding="10,8">
          <StackPanel>
            <TextBlock x:Name="AskHeader" Foreground="#9A9AA5" FontSize="10" FontWeight="SemiBold" Text="DECISÃO"/>
            <TextBlock x:Name="AskTitle" Foreground="#E8E8EC" FontWeight="SemiBold" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,6"/>
            <StackPanel x:Name="AskPanel"/>
            <StackPanel x:Name="AskFreeRow" Orientation="Horizontal" Margin="0,6,0,0" Visibility="Collapsed">
              <TextBox x:Name="AskInput" MinWidth="240" Height="30" VerticalContentAlignment="Center"
                       Background="#16161A" Foreground="#E8E8EC" BorderBrush="#3A3A44" BorderThickness="1"
                       CaretBrush="#E8E8EC" Padding="6,4" FontSize="12"/>
              <Button x:Name="AskSendBtn" Content="Enviar" Margin="6,0,0,0"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
              <Button x:Name="AskOkBtn" Content="✔ Confirmar escolhas" FontWeight="SemiBold" Visibility="Collapsed"/>
              <Button x:Name="AskOtherBtn" Content="✎ Outra resposta…" Margin="8,0,0,0"/>
              <Button x:Name="AskCancelBtn" Content="✕ Cancelar" Margin="8,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
        <DockPanel Margin="14,8,14,6">
          <Button x:Name="SendBtn" DockPanel.Dock="Right" Content="Enviar" Padding="14,8" Margin="8,0,0,0" FontSize="13" FontWeight="SemiBold"/>
          <TextBox x:Name="InputBox" Height="68" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                   Background="#16161A" Foreground="#E8E8EC" BorderBrush="#3A3A44" BorderThickness="1"
                   CaretBrush="#E8E8EC" Padding="8,6" FontSize="13"/>
        </DockPanel>
        <DockPanel Margin="14,0,14,10">
          <TextBlock x:Name="StatusText" Foreground="#9A9AA5" FontSize="11" Text="Pronto"/>
          <TextBlock x:Name="ModelText" Foreground="#6E6E7A" FontSize="11" HorizontalAlignment="Right"/>
        </DockPanel>
      </StackPanel>
    </Border>
    <FlowDocumentScrollViewer x:Name="AnswerView" VerticalScrollBarVisibility="Auto" Padding="14,8,14,4" IsToolBarVisible="False">
      <FlowDocument x:Name="AnswerDoc" Foreground="#E8E8EC" FontFamily="Cascadia Mono, Consolas" FontSize="13"
                    TextAlignment="Left" PagePadding="0" ColumnWidth="3000"/>
    </FlowDocumentScrollViewer>
  </DockPanel>
</Window>
'@
[xml]$xaml = Theme-Xaml $xamlStr
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'ProfileBox','ModelBox','NewBtn','HistBtn','TopBtn','PassBtn','SettingsBtn','MinBtn','MaxBtn','CloseBtn','AttachScroll','AttachPanel','ConfirmBar','ConfirmTitle','ConfirmDetail','ConfirmDiffScroll','ConfirmDiff','ConfirmYes','ConfirmAlwaysBtn','ConfirmNo','PlanBar','PlanTitle','PlanSteps','PlanYes','PlanNo','AskBar','AskHeader','AskTitle','AskPanel','AskInput','AskSendBtn','AskOkBtn','AskOtherBtn','AskCancelBtn','AskFreeRow','SendBtn','InputBox','StatusText','ModelText','AnswerView','AnswerDoc') {
    Set-Variable -Name $n -Scope Script -Value $window.FindName($n)
}
$script:baseOpacity = 1.0
if ($cfg.windowOpacity -and [double]$cfg.windowOpacity -gt 0 -and [double]$cfg.windowOpacity -lt 1) {
    $script:baseOpacity = [double]$cfg.windowOpacity
    $window.Opacity = $script:baseOpacity
}

# ---------- v3.9: 📌 sempre no topo + Ctrl+roda = opacidade ao vivo ----------
function Set-TopBtnVisual([bool]$on) {
    $TopBtn.Background = $(if ($on) { $T.accent } else { $T.panel })
    $TopBtn.ToolTip = $(if ($on) { 'sempre no topo: ATIVO — clique para desligar' } else { 'sempre no topo — manter a janela sobre as outras' })
}
if ($cfg.alwaysOnTop) { $window.Topmost = $true; Set-TopBtnVisual $true }
$TopBtn.Add_Click({ Set-Topmost (-not $window.Topmost) })
# v3.12: ⚡ passthrough — GateConfirm aprova tudo enquanto ligado (só o botão alterna; persiste no json)
function Set-PassBtnVisual([bool]$on) {
    $PassBtn.Background = $(if ($on) { $T.accent } else { $T.panel })
    $PassBtn.ToolTip = $(if ($on) { 'passthrough: ATIVO — ações rodam SEM confirmação; clique para desligar' } else { 'passthrough — aprovar ações (edits/comandos) sem confirmar; clique para ligar' })
}
function Set-Passthrough([bool]$on) {
    if ($script:engine) { try { $script:engine.SetPassthrough($on) } catch { Log "passthrough: $_" } }
    $cfg.passthrough = $on
    Set-PassBtnVisual $on
    Save-Config
    $StatusText.Text = $(if ($on) { '⚡ passthrough: ações sem confirmação' } else { '⚡ passthrough: desligado' })
    Log ("chrome: passthrough {0}" -f $on)
}
if ($cfg.passthrough) { Set-PassBtnVisual $true }
$PassBtn.Add_Click({ Set-Passthrough (-not [bool]$cfg.passthrough) })
function Set-Topmost([bool]$on) {
    $window.Topmost = $on
    $cfg.alwaysOnTop = $on
    Set-TopBtnVisual $on
    Save-Config
    $StatusText.Text = $(if ($on) { '📌 sempre no topo: sim' } else { '📌 sempre no topo: não' })
    Log ("chrome: topmost {0}" -f $on)
}
# Ctrl+roda do mouse sobre QUALQUER janela do app: opacidade 40-100% (persiste com debounce)
$script:opacSaveTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:opacSaveTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:opacSaveTimer.Add_Tick({
    $script:opacSaveTimer.Stop()
    $cfg.windowOpacity = $script:baseOpacity
    Save-Config
    Log ("config: opacidade salva {0:P0} (Ctrl+roda)" -f $script:baseOpacity)
})
function Add-OpacityWheel($win) {
    $win.Add_PreviewMouseWheel({
        param($s, $e)
        if (-not ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { return }
        $e.Handled = $true
        $op = [Math]::Min(1.0, [Math]::Max(0.4, [Math]::Round($script:baseOpacity + $(if ($e.Delta -gt 0) { 0.05 } else { -0.05 }), 2)))
        if ([Math]::Abs($op - $script:baseOpacity) -lt 0.005) { return }
        $script:baseOpacity = $op
        $s.Opacity = $op          # janela que recebeu a roda (principal OU dialogo aberto)
        $window.Opacity = $op
        $StatusText.Text = ("opacidade {0:P0} (Ctrl+roda ajusta)" -f $op)
        if (-not $script:opacSaveTimer.IsEnabled) { $script:opacSaveTimer.Start() }
    })
}
Add-OpacityWheel $window

# ---------- Onda 6: janela memorizada (tamanho/posição) + fonte da área de resposta ----------
try {
    if ([int]$cfg.window.width  -ge 520 -and [int]$cfg.window.height -ge 360) {
        $window.Width  = [int]$cfg.window.width
        $window.Height = [int]$cfg.window.height
    }
    if (-not $cfg.window.center -and $null -ne $cfg.window.x -and $null -ne $cfg.window.y) {
        # lembrar última posição: clamp p/ tela virtual (não deixar a janela nascer fora)
        $vxL = [System.Windows.SystemParameters]::VirtualScreenLeft;  $vyT = [System.Windows.SystemParameters]::VirtualScreenTop
        $vxR = $vxL + [System.Windows.SystemParameters]::VirtualScreenWidth; $vyB = $vyT + [System.Windows.SystemParameters]::VirtualScreenHeight
        $window.WindowStartupLocation = 'Manual'
        $window.Left = [Math]::Max($vxL, [Math]::Min([double]$cfg.window.x, $vxR - $window.Width))
        $window.Top  = [Math]::Max($vyT, [Math]::Min([double]$cfg.window.y, $vyB - 40))
    }
} catch { Log "boot-janela: $_" }
# v3.8: fonte escala a interface TODA — o XAML ja vem pre-escalado pelo Theme-Xaml (FSz p/ o criado via codigo)
if ($cfg.answerFont)     { try { $AnswerDoc.FontFamily = [System.Windows.Media.FontFamily]::new([string]$cfg.answerFont) } catch {} }
$InputBox.Height = FSz 68          # altura fixa do composer escala junto (senao o textarea espreme o texto maior)
$AttachScroll.MaxHeight = FSz 76

# v3.8: re-escala AO VIVO a janela principal (walk visual + conteudo do documento):
# todo elemento com FontSize local (do XAML pre-escalado ou FSz no codigo) e' re-multiplicado por novo/velho
function Set-FontScale([double]$newScale) {
    if ($newScale -lt 0.5 -or $newScale -gt 2.5) { return }
    $old = $script:fscale
    if ([Math]::Abs($newScale - $old) -lt 0.005) { return }
    $f = $newScale / $old
    $script:fscale = $newScale
    $InputBox.Height = [Math]::Round(68 * $newScale, 1)       # composer acompanha (fixa no XAML, fora do walk)
    $AttachScroll.MaxHeight = [Math]::Round(76 * $newScale, 1)
    $ctrlProp = [System.Windows.Controls.Control]::FontSizeProperty
    $tbProp   = [System.Windows.Controls.TextBlock]::FontSizeProperty
    $txtProp  = [System.Windows.Documents.TextElement]::FontSizeProperty
    $docProp  = [System.Windows.Documents.FlowDocument]::FontSizeProperty
    $rescale = {
        param($e)
        if ($null -eq $e) { return }
        $p = $null
        if     ($e -is [System.Windows.Controls.Control])         { $p = $ctrlProp }
        elseif ($e -is [System.Windows.Controls.TextBlock])       { $p = $tbProp }
        elseif ($e -is [System.Windows.Documents.FlowDocument])   { $p = $docProp }
        elseif ($e -is [System.Windows.Documents.TextElement])    { $p = $txtProp }
        if ($p) {
            $lv = $e.ReadLocalValue($p)
            if ($lv -is [double]) { try { $e.SetValue($p, [Math]::Round([double]$lv * $f, 1)) } catch {} }
        }
        if ($e -is [System.Windows.Media.Visual]) {
            $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($e)
            for ($i = 0; $i -lt $n; $i++) { & $rescale ([System.Windows.Media.VisualTreeHelper]::GetChild($e, $i)) }
        }
        if ($e -is [System.Windows.Documents.FlowDocument])   { foreach ($b in @($e.Blocks))  { & $rescale $b } }
        elseif ($e -is [System.Windows.Documents.List])       { foreach ($li in @($e.ListItems)) { foreach ($b in @($li.Blocks)) { & $rescale $b } } }
        elseif ($e -is [System.Windows.Documents.Paragraph])  { foreach ($il in @($e.Inlines)) { & $rescale $il } }
        elseif ($e -is [System.Windows.Documents.Span])       { foreach ($il in @($e.Inlines)) { & $rescale $il } }
        elseif ($e -is [System.Windows.Documents.InlineUIContainer]) { & $rescale $e.Child }
    }
    try {
        & $rescale $window            # controles: botoes, menus, textarea, status...
        & $rescale $AnswerDoc         # paragrafos/runs do documento (titulos, rotulos de tool)
        Log ("fontscale: {0:P0} -> {1:P0}" -f $old, $newScale)
    } catch { Log "fontscale erro: $_" }
}

# redimensionar/mover salva (com atraso p/ não escrever a cada pixel); só normal+visível
function Save-WindowPos {
    if (-not $window.IsVisible -or $window.WindowState -ne 'Normal') { return }
    $cfg.window.width  = [int]$window.Width
    $cfg.window.height = [int]$window.Height
    $cfg.window.x = [int]$window.Left; $cfg.window.y = [int]$window.Top
    Save-Config
    Log ("config: janela salva {0}x{1} @{2},{3}" -f $cfg.window.width, $cfg.window.height, $cfg.window.x, $cfg.window.y)
}
$script:winSaveTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:winSaveTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:winSaveTimer.Add_Tick({ $script:winSaveTimer.Stop(); Save-WindowPos })
$window.Add_SizeChanged({ if (-not $script:winSaveTimer.IsEnabled) { $script:winSaveTimer.Start() } })
$window.Add_LocationChanged({ if (-not $script:winSaveTimer.IsEnabled) { $script:winSaveTimer.Start() } })

# ---------- estado ----------
$script:busy = $false
$script:exiting = $false
$script:stopped = $false     # veio 'stopped' do engine: resposta interrompida a pedido
$script:queued = $null       # mensagem digitada durante a resposta (envia sozinha no fim do turno)
$script:curAnswer = ''
$script:lastAnswer = ''
$script:pendSources = @()
$script:livePanel = $null
$script:liveCopyBtn = $null   # v3.14: botao ⧉ do card ao vivo — Finish-Turn preenche o Tag
# clipboard via Win32 (v3.14): Set-Clipboard do PS 5.1 trava/colide com retry interno longo;
# OpenClipboard+SetClipboardData com retry curto e' deterministico
Add-Type -Namespace ZQ -Name Clip -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern bool OpenClipboard(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool EmptyClipboard();
[DllImport("user32.dll")] public static extern bool CloseClipboard();
[DllImport("user32.dll")] public static extern IntPtr SetClipboardData(uint fmt, IntPtr data);
[DllImport("kernel32.dll")] public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
[DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
[DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
[DllImport("kernel32.dll")] public static extern IntPtr GlobalFree(IntPtr h);
'@
function Set-ClipText([string]$text) {
    $bytes = [Text.Encoding]::Unicode.GetBytes($text + [string][char]0)
    for ($i = 0; $i -lt 12; $i++) {
        if (-not [ZQ.Clip]::OpenClipboard([IntPtr]::Zero)) { Start-Sleep -Milliseconds 120; continue }
        try {
            $null = [ZQ.Clip]::EmptyClipboard()
            $h = [ZQ.Clip]::GlobalAlloc(2, [UIntPtr][uint64]$bytes.Length)   # GMEM_MOVEABLE
            if ($h -eq [IntPtr]::Zero) { return $false }
            $p = [ZQ.Clip]::GlobalLock($h)
            if ($p -eq [IntPtr]::Zero) { $null = [ZQ.Clip]::GlobalFree($h); return $false }
            [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $p, $bytes.Length)
            $null = [ZQ.Clip]::GlobalUnlock($h)
            if ([ZQ.Clip]::SetClipboardData(13, $h) -eq [IntPtr]::Zero) { $null = [ZQ.Clip]::GlobalFree($h); return $false }  # 13 = CF_UNICODETEXT
            return $true
        } finally { $null = [ZQ.Clip]::CloseClipboard() }
    }
    return $false
}
# anexos: {Kind: img|txt|pdf, Name, B64, Text}
$script:attachments = [System.Collections.Generic.List[object]]::new()
$script:confirmId = 0
$script:sendTime = [datetime]::MinValue
$script:convFile = $null
$script:convResumed = $false
$script:curQuestion = ''
$script:modelLabel = ''

# ---------- helpers de UI ----------
function Open-Url($u) {
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new([string]$u)
        $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch { Log "open-url: $_" }
}

function Add-InlineTokens([System.Windows.Documents.InlineCollection]$col, [string]$text) {
    $rx = [regex]'(`[^`]+`)|(\*\*[^*]+\*\*)|(https?://[^\s)\]<]+)|(\[\d{1,2}\])'
    $pos = 0
    foreach ($m in $rx.Matches($text)) {
        if ($m.Index -gt $pos) { $col.Add([System.Windows.Documents.Run]::new($text.Substring($pos, $m.Index - $pos))) | Out-Null }
        $tok = $m.Value; $g = $m.Groups
        if ($g[1].Success) {        # `codigo`
            $r = [System.Windows.Documents.Run]::new($tok.Trim('`')); $r.Foreground = $T.code; $r.FontFamily = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas')
            $col.Add($r) | Out-Null
        } elseif ($g[2].Success) {  # **negrito**
            $r = [System.Windows.Documents.Run]::new($tok.Trim('*')); $r.FontWeight = 'SemiBold'
            $col.Add($r) | Out-Null
        } elseif ($g[3].Success) {  # url
            $h = [System.Windows.Documents.Hyperlink]::new()
            $h.NavigateUri = [Uri]::new($tok); $h.Foreground = $T.accent
            $h.Inlines.Add([System.Windows.Documents.Run]::new($tok)) | Out-Null
            $h.Add_RequestNavigate({ param($s, $e) Open-Url $e.Uri.ToString(); $e.Handled = $true }.GetNewClosure())
            $col.Add($h) | Out-Null
        } else {                    # [n] fonte
            $n = [int]$tok.Trim('[', ']')
            $src = @($script:pendSources)
            if ($n -ge 1 -and $n -le $src.Count -and $src[$n - 1].url) {
                $h = [System.Windows.Documents.Hyperlink]::new()
                $h.NavigateUri = [Uri]::new([string]$src[$n - 1].url); $h.Foreground = $T.accent
                $h.Inlines.Add([System.Windows.Documents.Run]::new($tok)) | Out-Null
                $h.Add_RequestNavigate({ param($s, $e) Open-Url $e.Uri.ToString(); $e.Handled = $true }.GetNewClosure())
                $col.Add($h) | Out-Null
            } else {
                $r = [System.Windows.Documents.Run]::new($tok); $r.Foreground = $T.accent
                $col.Add($r) | Out-Null
            }
        }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $text.Length) { $col.Add([System.Windows.Documents.Run]::new($text.Substring($pos))) | Out-Null }
}

function Add-MdLines([System.Windows.Documents.BlockCollection]$blocks, [string]$text, [bool]$question) {
    foreach ($ln in ($text -split "`r?`n")) {
        $ln = $ln.TrimEnd()
        $para = [System.Windows.Documents.Paragraph]::new()
        $para.Margin = '0,1'
        if ($question) { $para.Foreground = $T.q; $para.FontWeight = 'SemiBold' }
        else { $para.Foreground = $T.fg }
        $line = $ln
        if ($line -match '^(#{1,4})\s+(.*)$') { $line = $Matches[2]; $para.FontWeight = 'SemiBold'; $para.FontSize = (FSz 14) }
        if ($line -match '^[-*]\s+') {
            $b = [System.Windows.Documents.Run]::new('• '); $b.Foreground = $T.dim; $para.Inlines.Add($b) | Out-Null
            $line = $line -replace '^[-*]\s+', ''
        }
        if ($line.Length -gt 0) { Add-InlineTokens $para.Inlines $line }
        $blocks.Add($para) | Out-Null
    }
}

function New-Card([string]$title) {
    $sec = [System.Windows.Documents.Section]::new()
    $sec.Background = $T.card; $sec.Padding = '12,10'; $sec.Margin = '0,0,0,8'
    if ($title) {
        $t = [System.Windows.Documents.Paragraph]::new()
        $null = $t.Inlines.Add([System.Windows.Documents.Run]::new($title))
        $t.FontSize = (FSz 10); $t.Foreground = '#6E6E7A'; $t.Margin = '0,0,0,4'
        $sec.Blocks.Add($t) | Out-Null
    }
    @{ Section = $sec; Blocks = $sec.Blocks }
}

function Add-CopyIcon([System.Windows.Documents.BlockCollection]$blocks) {
    # v3.14: icone de copiar no topo direito do card do bot (o botao "Copiar" saiu
    # da barra). O texto a copiar vive no Tag — setado no fim do turno (Finish-Turn)
    # ou no load da conversa. Devolve o botao pra alguem preencher o Tag.
    $btn = [System.Windows.Controls.Button]::new()
    $btn.Content = [string][char]0x29C9
    $btn.FontSize = (FSz 11)
    $btn.Padding = '4,1'
    $btn.Background = [System.Windows.Media.Brushes]::Transparent
    $btn.BorderThickness = '0'
    $btn.Foreground = $T.dim
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand
    $btn.Opacity = 0.5
    $btn.HorizontalAlignment = 'Right'
    $btn.ToolTip = 'copiar resposta'
    $btn.Tag = ''
    $btn.Add_Click({ param($s2,$e2)
        try {
            if (-not $s2.Tag) { $StatusText.Text = 'nada para copiar ainda'; Log 'copiar: tag vazia'; return }
            $txt3 = [string]$s2.Tag
            if (Set-ClipText $txt3) { $StatusText.Text = 'resposta copiada'; Log ("copiar: {0} chars pro clipboard" -f $txt3.Length) }
            else { $StatusText.Text = 'clipboard ocupado — tenta de novo'; Log 'copiar erro: clipboard ocupado' }
        } catch { Log ('copiar erro: ' + $_.Exception.Message) }
    }.GetNewClosure())
    $btn.Add_MouseEnter({ param($s2,$e2) $s2.Opacity = 1 }.GetNewClosure())
    $btn.Add_MouseLeave({ param($s2,$e2) $s2.Opacity = 0.5 }.GetNewClosure())
    $buc = [System.Windows.Documents.BlockUIContainer]::new()
    $buc.Child = $btn
    $buc.Margin = '0,0,0,2'
    $blocks.Add($buc) | Out-Null
    return $btn
}

function Scroll-AnswerToEnd {
    try {
        $sv = $AnswerView.Template.FindName('PART_ContentHost', $AnswerView)
        if ($sv -is [System.Windows.Controls.ScrollViewer]) { $sv.ScrollToEnd() }
    } catch { Log "scroll: $_" }
}

function Update-LiveAnswer {
    if ($null -eq $script:livePanel) { return }
    $script:livePanel.Clear()
    if ($script:curAnswer) { Add-MdLines $script:livePanel $script:curAnswer $false }
    if ($script:busy) {
        $d = [System.Windows.Documents.Paragraph]::new()
        $d.Inlines.Add([System.Windows.Documents.Run]::new('▌')) | Out-Null
        $d.Foreground = $T.accent2
        $script:livePanel.Add($d) | Out-Null
    }
    Scroll-AnswerToEnd
}

function Show-Sources($json) {
    # so' REGISTRA as fontes: os [n] da resposta viram link na hora. O rodape
    # "Fontes:" e' desenhado uma unica vez no fim do turno (Add-SourcesFooter) —
    # Update-LiveAnswer reconstruiria o livePanel a cada delta e apagaria o rodape.
    try {
        $arr = @(ConvertFrom-Json $json)
        if ($arr.Count -eq 0) { return }
        $script:pendSources = $arr
        Log ('fontes: ' + $arr.Count)
    } catch { Log "sources: $_" }
}

function Add-SourcesFooter {
    # rodape "Fontes:" no fim do card — depois do ultimo Update-LiveAnswer do turno
    try {
        if (@($script:pendSources).Count -eq 0 -or $null -eq $script:livePanel) { return }
        $tb = [System.Windows.Documents.Paragraph]::new(); $tb.Margin = '0,6,0,0'
        $lbl = [System.Windows.Documents.Run]::new('Fontes: '); $lbl.Foreground = $T.dim; $tb.Inlines.Add($lbl) | Out-Null
        $i = 0
        foreach ($s in @($script:pendSources)) {
            $i++
            if ($i -gt 1) { $sep = [System.Windows.Documents.Run]::new(' · '); $sep.Foreground = $T.dim; $tb.Inlines.Add($sep) | Out-Null }
            $h = [System.Windows.Documents.Hyperlink]::new()
            $h.NavigateUri = [Uri]::new([string]$s.url); $h.Foreground = $T.accent
            $h.Inlines.Add([System.Windows.Documents.Run]::new("[$i] $($s.title)")) | Out-Null
            $h.Add_RequestNavigate({ param($s2, $e) Open-Url $e.Uri.ToString(); $e.Handled = $true }.GetNewClosure())
            $tb.Inlines.Add($h) | Out-Null
        }
        $script:livePanel.Add($tb) | Out-Null
    } catch { Log "sources-footer: $_" }
}

function Set-Busy([bool]$b) {
    $script:busy = $b
    # ocupado: o botao vira "Parar" (clicavel) — Cancel() preserva o que ja chegou no card
    $SendBtn.Content = if ($b) { '⏹ Parar' } else { 'Enviar' }
    $SendBtn.ToolTip = if ($b) { 'Interromper a resposta — o que já chegou fica no card' } else { $null }
}

function Finish-Turn {
    if (-not $script:busy) { return }
    Set-Busy $false
    $ConfirmBar.Visibility = 'Collapsed'
    $PlanBar.Visibility = 'Collapsed'
    $script:lastAnswer = $script:curAnswer
    if ($script:liveCopyBtn) { $script:liveCopyBtn.Tag = $script:lastAnswer }   # v3.14: icone do card copia a resposta certa
    $el = if ($script:sendTime -gt [datetime]::MinValue) { [int]((Get-Date) - $script:sendTime).TotalSeconds } else { 0 }
    $StatusText.Text = "Pronto • ${el}s"
    $prev = ($script:lastAnswer -replace '\s+', ' ').Trim()
    if ($prev.Length -gt 100) { $prev = $prev.Substring(0, 100) + '…' }
    Log ("respondido: {0} chars em {1}s | {2}" -f $script:lastAnswer.Length, $el, $prev)
    Update-LiveAnswer
    if ($script:stopped) {
        # resposta interrompida pelo Parar: marca no fim do card (Update-LiveAnswer
        # ja refez o painel — so' agora e' seguro acrescentar)
        $script:stopped = $false
        if ($script:livePanel) {
            $sp = [System.Windows.Documents.Paragraph]::new(); $sp.Margin = '0,4,0,0'
            $sr = [System.Windows.Documents.Run]::new('⏹ interrompido')
            $sr.Foreground = $T.dim
            $null = $sp.Inlines.Add($sr)
            $script:livePanel.Add($sp) | Out-Null
        }
    }
    Add-SourcesFooter
    Save-History
    Update-CtxMeter
    # mensagem na fila (digitada durante a resposta): envia sozinha. Timer 1-tiro
    # afasta a corrida com o finally do engine (busy=0) e deixa o "Pronto" respirar.
    if ($script:queued) {
        $qt = [System.Windows.Threading.DispatcherTimer]::new()
        $qt.Interval = [TimeSpan]::FromMilliseconds(400)
        $qt.Add_Tick({
            param($s2, $e2)
            $s2.Stop()
            $q = $script:queued; $script:queued = $null
            if (-not $q -or $script:busy) { return }
            try {
                foreach ($it in @($q.items)) { $script:attachments.Add($it); New-FileChip ([string]$it.Name) }
                if (@($q.items).Count -gt 0) { $AttachScroll.Visibility = 'Visible' }
                $InputBox.Text = [string]$q.text
                Log 'fila: despachada'
                Send-Current
            } catch { Log "fila-dispatch: $_" }
        })
        $qt.Start()
    }
}

# rodape: modelo + consumo estimado do contexto (100% = limiar de compactacao, 150k chars)
function Update-CtxMeter {
    try {
        $chars = 0
        if ($script:engine) { foreach ($h in @($script:engine.GetHistory())) { $chars += ([string]$h).Length } }
        $pct = [int](100 * $chars / 150000); if ($pct -gt 100) { $pct = 100 }
        $ModelText.Text = if ($script:modelLabel) { "{0} • ctx {1}%" -f $script:modelLabel, $pct } else { "ctx ${pct}%" }
    } catch { Log "ctx: $_" }
}

# ---------- anexos ----------
function Add-ImageAttachment([System.Windows.Media.Imaging.BitmapSource]$bmp) {
    try {
        $src = $bmp.GetAsFrozen()
        $w = $src.PixelWidth; $h = $src.PixelHeight
        $mx = [Math]::Max($w, $h)
        if ($mx -gt 1568) {
            $s = 1568.0 / $mx
            $tt = [System.Windows.Media.ScaleTransform]::new($s, $s)
            $src = [System.Windows.Media.Imaging.TransformedBitmap]::new($src, $tt).GetAsFrozen()
        }
        $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($src))
        $ms = [System.IO.MemoryStream]::new()
        $enc.Save($ms)
        $b64 = [Convert]::ToBase64String($ms.ToArray())
        $script:attachments.Add([pscustomobject]@{ Kind = 'img'; Name = $null; B64 = $b64; Text = $null })

        $chip = [System.Windows.Controls.Border]::new()
        $chip.Background = $T.input; $chip.BorderBrush = $T.border; $chip.BorderThickness = '1'; $chip.CornerRadius = '6'; $chip.Margin = '0,0,6,0'; $chip.Padding = '2'
        $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Orientation = 'Horizontal'
        $img = [System.Windows.Controls.Image]::new(); $img.Source = $src; $img.MaxWidth = 84; $img.MaxHeight = 56; $img.Stretch = 'Uniform'; $img.Margin = '2'
        $sp.Children.Add($img) | Out-Null
        $idx = $script:attachments.Count - 1
        $xb = [System.Windows.Controls.Button]::new(); $xb.Content = '✕'; $xb.Padding = '4,2'; $xb.Margin = '2'; $xb.FontSize = (FSz 10)
        $xb.Add_Click({ param($s, $e)
            $script:attachments.RemoveAt($idx)
            $AttachPanel.Children.Remove($chip)
            if ($AttachPanel.Children.Count -eq 0) { $AttachScroll.Visibility = 'Collapsed' }
        }.GetNewClosure())
        $sp.Children.Add($xb) | Out-Null
        $chip.Child = $sp
        $AttachPanel.Children.Add($chip) | Out-Null
        $AttachScroll.Visibility = 'Visible'
        $StatusText.Text = "imagem anexada ($($script:attachments.Count))"
    } catch { Log "attach: $_"; $StatusText.Text = "erro ao anexar: $_" }
}

function New-FileChip([string]$name) {
    $chip = [System.Windows.Controls.Border]::new()
    $chip.Background = $T.input; $chip.BorderBrush = $T.border; $chip.BorderThickness = '1'; $chip.CornerRadius = '6'; $chip.Margin = '0,0,6,0'; $chip.Padding = '4,3'
    $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Orientation = 'Horizontal'
    $tb = [System.Windows.Controls.TextBlock]::new()
    $tb.Text = "📄 $name"; $tb.Foreground = $T.fg; $tb.FontSize = (FSz 11)
    $tb.MaxWidth = 180; $tb.TextTrimming = 'CharacterEllipsis'; $tb.Margin = '4,0,0,0'; $tb.VerticalAlignment = 'Center'
    $sp.Children.Add($tb) | Out-Null
    $idx = $script:attachments.Count - 1
    $xb = [System.Windows.Controls.Button]::new(); $xb.Content = '✕'; $xb.Padding = '4,2'; $xb.Margin = '2'; $xb.FontSize = (FSz 10)
    $xb.Add_Click({ param($s, $e)
        $script:attachments.RemoveAt($idx)
        $AttachPanel.Children.Remove($chip)
        if ($AttachPanel.Children.Count -eq 0) { $AttachScroll.Visibility = 'Collapsed' }
    }.GetNewClosure())
    $sp.Children.Add($xb) | Out-Null
    $chip.Child = $sp
    $AttachPanel.Children.Add($chip) | Out-Null
    $AttachScroll.Visibility = 'Visible'
}

$textExts = @('.txt','.md','.csv','.tsv','.json','.xml','.log','.ps1','.psm1','.psd1','.py','.js','.ts','.cs','.cpp','.c','.h','.hpp','.java','.rb','.go','.rs','.php','.html','.htm','.css','.scss','.sh','.bat','.cmd','.ini','.cfg','.conf','.yml','.yaml','.sql','.env','.srt','.tex')

function Add-FileAttachment([string]$path) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { $StatusText.Text = "arquivo não encontrado: $path"; return }
        $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
        $name = [IO.Path]::GetFileName($path)
        if ($ext -in '.png','.jpg','.jpeg','.webp','.bmp','.gif') { Add-ImageFile $path; return }
        if ($ext -eq '.pdf') {
            $b = [IO.File]::ReadAllBytes($path)
            if ($b.Length -gt 6MB) { $StatusText.Text = "PDF grande demais ($([int]($b.Length/1MB)) MB — máx. 6 MB)"; return }
            $script:attachments.Add([pscustomobject]@{ Kind = 'pdf'; Name = $name; B64 = [Convert]::ToBase64String($b); Text = $null })
            New-FileChip $name
            $StatusText.Text = "PDF anexado: $name ($([int]($b.Length/1KB)) KB)"
        }
        elseif ($ext -eq '.docx') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($path)
            try {
                $entry = $zip.GetEntry('word/document.xml')
                if (-not $entry) { $StatusText.Text = "docx sem texto legível: $name"; return }
                $sr = [IO.StreamReader]::new($entry.Open())
                $xml = $sr.ReadToEnd(); $sr.Close()
                $t = [Net.WebUtility]::HtmlDecode(($xml -replace '</w:p>', "`n" -replace '<[^>]+>', '')) -replace '[ \t]+', ' '
                if ($t.Length -gt 60000) { $t = $t.Substring(0, 60000) + "`n…(truncado em 60.000 caracteres)" }
                $script:attachments.Add([pscustomobject]@{ Kind = 'txt'; Name = $name; B64 = $null; Text = "[conteúdo extraído do .docx]`n$t" })
                New-FileChip $name
                $StatusText.Text = "documento anexado: $name ($($t.Length) caracteres)"
            } finally { $zip.Dispose() }
        }
        elseif ($ext -in $textExts) {
            $t = [IO.File]::ReadAllText($path)
            if ($t.Length -gt 60000) { $t = $t.Substring(0, 60000) + "`n…(arquivo truncado em 60.000 caracteres)" }
            $script:attachments.Add([pscustomobject]@{ Kind = 'txt'; Name = $name; B64 = $null; Text = $t })
            New-FileChip $name
            $StatusText.Text = "arquivo anexado: $name ($($t.Length) caracteres)"
        }
        else { $StatusText.Text = "tipo não suportado ($ext): aceito imagem, PDF, DOCX, texto/código" }
    } catch { Log "file-attach: $_"; $StatusText.Text = "erro ao anexar: $_" }
}

function Add-AnyFile([string]$path) {
    if ($path -match '\.(png|jpe?g|webp|bmp|gif)$') { Add-ImageFile $path }
    else { Add-FileAttachment $path }
}

function Add-ClipboardImage {
    try {
        if (-not [System.Windows.Clipboard]::ContainsImage()) { return }
        $img = [System.Windows.Clipboard]::GetImage()
        if ($img) { Add-ImageAttachment $img }
    } catch { Log "clipboard: $_" }
}

function Add-ImageFile($path) {
    try {
        $bmp = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($path), [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        Add-ImageAttachment $bmp
    } catch { Log "imgfile: $_" }
}

# ---------- envio ----------
function Send-Current {
    if (-not (Ensure-Engine)) { $InputBox.Focus() | Out-Null; return }
    $text = $InputBox.Text.Trim()
    # /uitest: hooks de desenvolvimento — E2E deterministico dos paineis ask/plan
    if ($text -eq '/uitest ask2') {
        $InputBox.Clear()
        Show-AskBar ([pscustomobject]@{
            id = 99
            qs = @(
                @{ q = 'Qual formato do relatório?'; h = 'FORMATO'; multi = $false; opts = @(
                    @{ label = 'Resumo'; desc = '1 parágrafo direto'; preview = "Total: R$ 1.234,56`nPagamentos: 12`nMês: out/2026" }
                    @{ label = 'Detalhado'; desc = 'tabela completa'; preview = "| Data | Valor |`n|------|-------|`n| 01/10 | 100,00 |`n| 02/10 | 200,00 |" }
                ) }
                @{ q = 'Incluir o quê?'; h = 'ESCOPO'; multi = $true; opts = @(
                    @{ label = 'Gráficos'; desc = 'gera PNGs' }
                    @{ label = 'Fontes'; desc = 'links no fim' }
                ) }
            )
        })
        Log 'uitest: ask2'
        return
    }
    if ($text -eq '/uitest plan') {
        $InputBox.Clear()
        Show-PlanBar ([pscustomobject]@{ id = 99; title = 'Teste de plano (uitest)'; steps = @('criar arquivo A na Desktop', 'criar arquivo B na Desktop', 'conferir os dois') })
        Log 'uitest: plan'
        return
    }
    if ($text -eq '/uitest at') {
        # hook E2E do dialogo de mencao: chars INJETADOS nao viram texto nesta
        # sessao (TSF descarta input injetado — so' keydown puro chega), então
        # o PreviewTextInput nao e' acionavel por teste; o dialogo em si e' (13/10)
        $InputBox.Clear()
        Log 'uitest: at'
        Open-MentionDialog | Out-Null
        return
    }
    $imgs = [System.Collections.Generic.List[string]]::new()
    $txtFiles = [System.Collections.Generic.List[string[]]]::new()
    $pdfs = [System.Collections.Generic.List[string[]]]::new()
    foreach ($at in @($script:attachments)) {
        if ($at.Kind -eq 'img') { $imgs.Add([string]$at.B64) }
        elseif ($at.Kind -eq 'txt') { $txtFiles.Add(@([string]$at.Name, [string]$at.Text)) }
        elseif ($at.Kind -eq 'pdf') { $pdfs.Add(@([string]$at.Name, [string]$at.B64)) }
    }
    if (-not $text -and $imgs.Count -eq 0 -and $txtFiles.Count -eq 0 -and $pdfs.Count -eq 0) { return }
    if ($script:busy) {
        # fila: Enter durante a resposta guarda a mensagem (textos/arquivos, nao imagem)
        # e envia sozinho quando o turno acaba — a UI nao fica bloqueada
        $hasImg = @($script:attachments | Where-Object { $_.Kind -eq 'img' }).Count -gt 0
        if ($hasImg) { $StatusText.Text = 'imagem não entra na fila — aguarde ou use ⏹ Parar'; return }
        $script:queued = @{ text = $text; items = @($script:attachments) }
        $InputBox.Clear()
        $script:attachments.Clear(); $AttachPanel.Children.Clear(); $AttachScroll.Visibility = 'Collapsed'
        $StatusText.Text = '✉ na fila — envia sozinho quando a resposta acabar'
        Log ('fila: +1 mensagem (' + $text.Length + ' chars)')
        return
    }

    $q = New-Card $null
    $qtxt = "❯ $text"
    if ($imgs.Count -gt 0) { $qtxt += [Environment]::NewLine + "📎 $($imgs.Count) imagem(ns)" }
    $fnames = @($script:attachments | Where-Object { $_.Kind -ne 'img' } | ForEach-Object { [string]$_.Name })
    if ($fnames.Count -gt 0) { $qtxt += [Environment]::NewLine + "📎 " + ($fnames -join ', ') }
    Add-MdLines $q.Blocks $qtxt $true
    $AnswerDoc.Blocks.Add($q.Section) | Out-Null
    $a = New-Card $null
    $script:liveCopyBtn = Add-CopyIcon $a.Blocks      # topo direito (v3.14)
    $inner = [System.Windows.Documents.Section]::new()  # texto vive aqui dentro: o Update-LiveAnswer nao apaga o icone
    $null = $a.Section.Blocks.Add($inner)
    $AnswerDoc.Blocks.Add($a.Section) | Out-Null
    $script:livePanel = $inner.Blocks
    $script:curAnswer = ''; $script:pendSources = @()

    $InputBox.Clear()
    $script:attachments.Clear(); $AttachPanel.Children.Clear(); $AttachScroll.Visibility = 'Collapsed'

    Set-Busy $true
    $script:sendTime = Get-Date
    $StatusText.Text = 'enviando…'
    Scroll-AnswerToEnd
    Log ("envio: {0} chars, {1} imagem(ns), {2} arquivo(s)" -f $text.Length, $imgs.Count, ($txtFiles.Count + $pdfs.Count))
    # pergunta nova do zero = arquivo novo (item proprio no historico);
    # conversa retomada mantem o arquivo dela (convFile ja esta setado)
    if (-not $script:convFile) {
        New-Item -ItemType Directory -Force $histDir | Out-Null
        $script:convFile = Join-Path $histDir ('conv-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
        $script:convResumed = $false
    }
    $script:curQuestion = $text
    # system prompt = base + memoria (lida a CADA envio: fato salvo nesta conversa ja
    # vale para o proximo envio, e o arquvivo e' editavel a mao)
    $script:engine.Ask($text, $imgs, $txtFiles, $pdfs, ($sysPrompt + (Get-MemoryBlock) + (Get-SkillsBlock)))
}

function New-Conversation {
    $script:engine.Reset()
    $script:busy = $false
    $script:curAnswer = ''; $script:lastAnswer = ''; $script:pendSources = @(); $script:livePanel = $null
    $script:convFile = $null
    $script:convResumed = $false
    $script:queued = $null
    $AnswerDoc.Blocks.Clear()
    $script:attachments.Clear(); $AttachPanel.Children.Clear(); $AttachScroll.Visibility = 'Collapsed'
    $ConfirmBar.Visibility = 'Collapsed'
    $PlanBar.Visibility = 'Collapsed'
    if ($AskBar.Visibility -eq 'Visible') { $script:askCard = $null; Hide-AskBar }
    $script:stopped = $false
    Set-Busy $false
    Update-CtxMeter
    $StatusText.Text = 'nova conversa'
    Add-Placeholder
    [void]$InputBox.Focus()
}

function Add-Placeholder {
    $c = New-Card $null
    Add-MdLines $c.Blocks "Pergunte qualquer coisa — ou cole arquivos com **Ctrl+V** (print, PDF, documento, código)." $false
    $hint = [System.Windows.Documents.Paragraph]::new()
    $null = $hint.Inlines.Add([System.Windows.Documents.Run]::new(("$([string]$cfg.hotkey) mostra/oculta • Enter envia • Shift+Enter quebra linha • Esc fecha a conversa")))
    $hint.Foreground = $T.dim; $hint.FontSize = (FSz 11); $hint.Margin = '0,4,0,0'
    $c.Blocks.Add($hint) | Out-Null
    $AnswerDoc.Blocks.Add($c.Section) | Out-Null
}

# ---------- historico de conversas (salvar / retomar) ----------
$histDir = Join-Path $appDir 'history'
$script:convFile = $null

function Save-History {
    try {
        if ($null -eq $script:engine -or -not $script:convFile) { return }
        $msgs = @($script:engine.GetFull())   # v3.13: disco guarda a conversa COMPLETA — a compactação resume só a cópia da API
        if ($msgs.Count -lt 2) { return }
        # salva TUDO, inclusive imagens (base64) — retomar devolve os pixels ao modelo
        $q = [string]$script:curQuestion
        if (-not $q) { $q = '(imagem)' }
        # renomear/favoritar (v3.13): campos viajam junto quando a conversa retomada é regravada
        $hfav = $false; $htitle = $null
        if ($script:convResumed -and (Test-Path $script:convFile)) {
            try { $old = Get-Content -Path $script:convFile -Raw -Encoding utf8 | ConvertFrom-Json; $hfav = [bool]$old.fav; $htitle = [string]$old.title } catch {}
        }
        $obj = [ordered]@{
            time = (Get-Date).ToString('s'); profile = [string]$cfg.profile; model = [string]$cfg.model
            q = $q; a = $script:lastAnswer; msgs = @($msgs)
        }
        if ($hfav) { $obj.fav = $true }
        if ($htitle) { $obj.title = $htitle }
        New-Item -ItemType Directory -Force $histDir | Out-Null
        [pscustomobject]$obj | ConvertTo-Json -Depth 4 | Set-Content -Path $script:convFile -Encoding utf8
        # poda: 200 itens mais recentes OU teto de ~50MB (imagem em base64 engorda)
        $all = @(Get-ChildItem $histDir -Filter 'conv-*.json' | Sort-Object Name -Descending)
        if ($all.Count -gt 200) {
            $all | Select-Object -Skip 200 | ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {} }
            $all = @(Get-ChildItem $histDir -Filter 'conv-*.json' | Sort-Object Name -Descending)
        }
        $tot = ($all | Measure-Object Length -Sum).Sum
        if ($tot -gt 50MB) {
            for ($i = $all.Count - 1; $i -ge 0 -and $tot -gt 40MB; $i--) {
                $tot -= $all[$i].Length
                try { Remove-Item $all[$i].FullName -Force -ErrorAction Stop } catch {}
            }
        }
        # conversa nova (nao retomada): item proprio por pergunta — proxima pergunta abre arquivo novo
        if (-not $script:convResumed) { $script:convFile = $null }
    } catch { Log "save-history: $_" }
}

# fragmento de historia tem que ser JSON fechado — o bug de compactacao de 16/10 gravava o par
# [RESUMO]/summary sem o terminador "]}". Ao ler do disco: repara o deficit, senao descarta (o
# render do Load-Conversation e o corpo do request dependem de fragmentos validos).
function Repair-MsgFragments($msgs) {
    $out = @(); $fixed = 0; $dropped = 0
    foreach ($m in $msgs) {
        $s = [string]$m
        $ok = $true
        try { $null = $s | ConvertFrom-Json } catch { $ok = $false }
        if ($ok) { $out += $s; continue }
        try { $null = ($s + ']}') | ConvertFrom-Json; $out += ($s + ']}'); $fixed++ }
        catch { $dropped++ }
    }
    if ($fixed -or $dropped) { Log ("load-history: {0} fragmento(s) reparado(s), {1} descartado(s)" -f $fixed, $dropped) }
    ,$out
}

function Load-Conversation([string]$file) {
    try {
        if ($script:busy) { $StatusText.Text = 'aguarde a resposta atual…'; return }
        $j = Get-Content -Path $file -Raw -Encoding utf8 | ConvertFrom-Json
        $r = Repair-MsgFragments @($j.msgs)   # sem @() em volta: a funcao ja devolve o array com ,@()
        $msgs = @($r)
        if ($msgs.Count -lt 1) { return }
        if ($script:engine) {
            $script:engine.Reset()
            $l = [System.Collections.Generic.List[string]]::new()
            foreach ($m in $msgs) { $l.Add([string]$m) }
            $script:engine.SetHistory($l)
        }

        $AnswerDoc.Blocks.Clear()
        $script:curAnswer = ''; $script:lastAnswer = ''; $script:pendSources = @(); $script:livePanel = $null
        foreach ($m in $msgs) {
            $o = $m | ConvertFrom-Json
            $isUser = ([string]$o.role -eq 'user')
            $c = New-Card $null
            $cbtn = $null; $botTxt = ''
            if (-not $isUser) { $cbtn = Add-CopyIcon $c.Blocks }   # v3.14: cada resposta retomada ganha o icone de copiar
            $any = $false
            foreach ($b in @($o.content)) {
                if ([string]$b.type -eq 'text') {
                    $txt = [string]$b.text
                    if (-not $txt) { continue }
                    $any = $true
                    if ($isUser) { Add-MdLines $c.Blocks ("❯ " + $txt) $true }
                    else { Add-MdLines $c.Blocks $txt $false; $script:lastAnswer = $txt; $botTxt += $txt }
                } elseif ([string]$b.type -eq 'image') {
                    $any = $true
                    try {
                        $bytes = [Convert]::FromBase64String([string]$b.source.data)
                        $bmpI = [System.Windows.Media.Imaging.BitmapImage]::new()
                        $msb = [System.IO.MemoryStream]::new($bytes)
                        $bmpI.BeginInit()
                        $bmpI.StreamSource = $msb
                        $bmpI.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                        $bmpI.EndInit()
                        $bmpI.Freeze()
                        $img = [System.Windows.Controls.Image]::new()
                        $img.Source = $bmpI; $img.MaxWidth = 160; $img.Margin = '0,3'
                        $iu = [System.Windows.Documents.InlineUIContainer]::new()
                        $iu.Child = $img
                        $ip = [System.Windows.Documents.Paragraph]::new()
                        $ip.Inlines.Add($iu) | Out-Null
                        $c.Blocks.Add($ip) | Out-Null
                    } catch { Log "hist-img: $_" }
                }
            }
            if ($cbtn -and $botTxt) { $cbtn.Tag = $botTxt }   # icone copia a resposta deste card
            if ($any) { $AnswerDoc.Blocks.Add($c.Section) | Out-Null }
        }
        Scroll-AnswerToEnd
        # conversa retomada CONTINUA no mesmo arquivo (proximo envio atualiza ele)
        $script:convFile = $file
        $script:convResumed = $true
        Update-CtxMeter
        $StatusText.Text = 'conversa retomada'
        Log ("historico: retomou {0} msgs de {1}" -f $msgs.Count, (Split-Path $file -Leaf))
        [void]$InputBox.Focus()
    } catch { Log "load-history: $_"; $StatusText.Text = "erro ao retomar: $_" }
}

# ---------- Onda 6: dialogo de configuracoes (⚙) ----------
function Set-CfgProp($obj, [string]$name, $value) {
    # grava propriedade em PSCustomObject (json) OU hashtable (defaults)
    if ($obj -is [System.Collections.IDictionary]) { $obj[$name] = $value }
    elseif ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { Add-Member -InputObject $obj -MemberType NoteProperty -Name $name -Value $value -Force }
}
function Get-CfgProp($obj, [string]$name) {
    if ($obj -is [System.Collections.IDictionary]) { return $obj[$name] }
    return $obj.$name
}
function Show-Settings {
    try {
        $sxStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZQuick — configurações" Width="640" Height="600" MinWidth="520" MinHeight="420"
        WindowStyle="None" ResizeMode="CanResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False" Background="#202024" FontFamily="Segoe UI" FontSize="12">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="36" ResizeBorderThickness="6" GlassFrameThickness="1"
                  CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2A30"/>
      <Setter Property="Foreground" Value="#E8E8EC"/>
      <Setter Property="BorderBrush" Value="#3A3A44"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="ChromeBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E8E8EC"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="9,5"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#3A3A44"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Padding="14,8,4,6">
      <DockPanel>
        <Button DockPanel.Dock="Right" x:Name="SetClose" Content="✕" ToolTip="fechar (descarta)" Style="{StaticResource ChromeBtn}"/>
        <TextBlock Text="⚙ Configurações" FontSize="14" FontWeight="SemiBold" Foreground="#E8E8EC" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
    <Border DockPanel.Dock="Bottom" Padding="14,8,14,10">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <TextBlock x:Name="SetStatus" Foreground="#6E6E7A" FontSize="11" VerticalAlignment="Center" Margin="0,0,12,0" Text="Aplicar grava no zquick.json"/>
        <Button x:Name="SetApply" Content="✔ Aplicar" FontWeight="SemiBold" IsDefault="True"/>
        <Button x:Name="SetCancel" Content="Cancelar" Margin="8,0,0,0" IsCancel="True"/>
      </StackPanel>
    </Border>
    <TabControl Background="#202024" BorderThickness="0" Margin="6,0,6,6">
      <TabItem Header="Perfil &amp; chaves">
        <Border Background="#16161A" Padding="12">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock Text="Perfil (troque/crie perfis no zquick.json; aqui edita o selecionado)" Foreground="#6E6E7A" FontSize="11" Margin="0,0,0,4"/>
              <ComboBox x:Name="SetProfile" FontSize="12" HorizontalAlignment="Left" MinWidth="200"/>
              <TextBlock Text="Chave da API — cole uma nova para trocar (vazio = mantém a atual/herdada)" Foreground="#9A9AA5" FontSize="11" Margin="0,12,0,4"/>
              <PasswordBox x:Name="SetKey" FontFamily="Cascadia Mono, Consolas"/>
              <TextBlock Text="Base URL (vazio = herda de ~/.claude/settings.json)" Foreground="#9A9AA5" FontSize="11" Margin="0,10,0,4"/>
              <TextBox x:Name="SetBase" FontFamily="Cascadia Mono, Consolas"
                       ToolTip="Endpoint base da API do provedor. O app chama &lt;base&gt;/v1/messages (padrão Anthropic Messages). Não precisa ser Anthropic: GLM/Z.ai, Kimi, DeepSeek, MiniMax e Qwen expõem esse mesmo padrão — cole a URL e a chave do provedor."/>
              <TextBlock Text="✓ Não precisa ser Claude: qualquer LLM que exponha API no padrão Anthropic serve — GLM (Z.ai) · Kimi · DeepSeek · MiniMax · Qwen…" Foreground="#9A9AA5" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
              <TextBlock Text="Cole a Base URL do provedor e a chave; o /v1/messages entra automático. Ex.: api.anthropic.com · api.z.ai/api/anthropic · api.moonshot.ai/anthropic · api.deepseek.com/anthropic · api.minimax.io/anthropic" Foreground="#6E6E7A" FontSize="11" Margin="0,3,0,0" TextWrapping="Wrap"/>
              <Grid Margin="0,12,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="fastModel (rápido)" Foreground="#9A9AA5" FontSize="11" Margin="0,0,0,4"/>
                  <TextBox x:Name="SetFast" FontFamily="Cascadia Mono, Consolas"/>
                  <TextBlock Text="bigModel (forte, modo auto)" Foreground="#9A9AA5" FontSize="11" Margin="0,10,0,4"/>
                  <TextBox x:Name="SetBig" FontFamily="Cascadia Mono, Consolas"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="visionModel (lê imagem)" Foreground="#9A9AA5" FontSize="11" Margin="0,0,0,4"/>
                  <TextBox x:Name="SetVision" FontFamily="Cascadia Mono, Consolas"/>
                  <DockPanel Margin="0,10,0,4">
                    <Button DockPanel.Dock="Right" x:Name="SetListModels" Content="🔎 listar da API" Margin="6,0,0,0" Padding="8,2" FontSize="11"
                            ToolTip="Busca a lista de modelos do provedor (GET /v1/models do padrão Anthropic) e preenche a caixa abaixo"/>
                    <TextBlock Text="modelos (vírgula — caixa do topo)" Foreground="#9A9AA5" FontSize="11" VerticalAlignment="Center"/>
                  </DockPanel>
                  <TextBox x:Name="SetModels" FontFamily="Cascadia Mono, Consolas"/>
                </StackPanel>
              </Grid>
              <TextBlock Text="Se o perfil editado for o atual, o motor é recriado no próximo envio." Foreground="#6E6E7A" FontSize="11" Margin="0,12,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </TabItem>
      <TabItem Header="Janela">
        <Border Background="#16161A" Padding="12">
          <StackPanel>
            <TextBlock Text="Tamanho (largura × altura, em DIP)" Foreground="#9A9AA5" FontSize="11" Margin="0,0,0,4"/>
            <StackPanel Orientation="Horizontal">
              <TextBox x:Name="SetW" Width="80" FontFamily="Cascadia Mono, Consolas"/>
              <TextBlock Text=" × " Foreground="#9A9AA5" VerticalAlignment="Center"/>
              <TextBox x:Name="SetH" Width="80" FontFamily="Cascadia Mono, Consolas"/>
            </StackPanel>
            <CheckBox x:Name="SetCenter" Content="centralizar ao abrir (desmarcado = reabrir na última posição)" Foreground="#E8E8EC" Margin="0,14,0,0"/>
            <CheckBox x:Name="SetTop" Content="sempre no topo (janela sobre as outras; 📌 na barra também alterna)" Foreground="#E8E8EC" Margin="0,10,0,0"/>
            <TextBlock Text="Opacidade (também ajustável com Ctrl+roda do mouse na janela)" Foreground="#9A9AA5" FontSize="11" Margin="0,16,0,2"/>
            <StackPanel Orientation="Horizontal">
              <Slider x:Name="SetOpacity" Width="260" Minimum="0.4" Maximum="1.0" TickFrequency="0.05" IsSnapToTickEnabled="True"/>
              <TextBlock x:Name="SetOpVal" Foreground="#E8E8EC" FontSize="12" VerticalAlignment="Center" Margin="10,0,0,0"/>
            </StackPanel>
            <TextBlock Text="Arrastar/redimensionar também memoriza (salva 1s depois de soltar o mouse)." Foreground="#6E6E7A" FontSize="11" Margin="0,14,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
      </TabItem>
      <TabItem Header="Aparência">
        <Border Background="#16161A" Padding="12">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <StackPanel>
                  <TextBlock Text="Fonte do texto" Foreground="#9A9AA5" FontSize="11" Margin="0,0,0,4"/>
                  <ComboBox x:Name="SetFont" IsEditable="True" MinWidth="240" FontSize="12"/>
                </StackPanel>
                <StackPanel Margin="16,0,0,0">
                  <TextBlock Text="Tamanho (13 = padrão; aumenta a interface toda)" Foreground="#9A9AA5" FontSize="11" Margin="0,0,0,4"/>
                  <TextBox x:Name="SetFontSize" Width="60" FontFamily="Cascadia Mono, Consolas"/>
                </StackPanel>
              </StackPanel>
              <TextBlock Text="Prévia — mini ZQuick reflete as cores ao vivo enquanto você edita" Foreground="#9A9AA5" FontSize="11" Margin="0,14,0,4"/>
              <Border x:Name="SetPrevHost" BorderBrush="#2E2E38" BorderThickness="1" CornerRadius="4" Margin="0,0,0,4" Padding="6"/>
              <TextBlock Text="Cores (hex #RRGGBB — efeito completo ao reabrir; principais superfícies aplicam na hora)" Foreground="#9A9AA5" FontSize="11" Margin="0,6,0,6"/>
              <UniformGrid x:Name="SetColors" Columns="2"/>
              <Button x:Name="SetResetColors" Content="restaurar cores padrão" HorizontalAlignment="Left" Margin="0,10,0,0"/>
              <TextBlock Text="Temas salvos" Foreground="#9A9AA5" FontSize="11" Margin="0,14,0,4"/>
              <StackPanel Orientation="Horizontal">
                <TextBox x:Name="SetThemeName" Width="120" ToolTip="nome do tema" FontSize="12"/>
                <Button x:Name="SetThemeSave" Content="💾 salvar" Margin="6,0,0,0" ToolTip="guarda as 14 cores atuais das caixas com este nome"/>
                <ComboBox x:Name="SetThemeList" Width="140" Margin="12,0,0,0" ToolTip="temas embutidos (padrão, matrix) + os seus guardados no zquick.json"/>
                <Button x:Name="SetThemeLoad" Content="◀ aplicar" Margin="6,0,0,0" ToolTip="carrega o tema escolhido nas caixas de hex (✔ Aplicar grava)"/>
                <Button x:Name="SetThemeDel" Content="🗑" Margin="6,0,0,0" ToolTip="apagar o tema escolhido da lista"/>
              </StackPanel>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </TabItem>
      <TabItem Header="Geral">
        <Border Background="#16161A" Padding="12">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock Text="Busca web" Foreground="#9A9AA5" FontSize="11" Margin="0,0,0,4"/>
              <ComboBox x:Name="SetSearch" FontSize="12" HorizontalAlignment="Left" MinWidth="200"/>
              <TextBlock Text="maxTokens (teto da resposta)" Foreground="#9A9AA5" FontSize="11" Margin="0,12,0,4"/>
              <TextBox x:Name="SetMaxTok" Width="100" FontFamily="Cascadia Mono, Consolas"/>
              <CheckBox x:Name="SetCache" Content="cache de prompt (cache_control no system+tools)" Foreground="#E8E8EC" Margin="0,14,0,0"/>
              <CheckBox x:Name="SetHideBlur" Content="fechar a janela ao perder o foco" Foreground="#E8E8EC" Margin="0,10,0,0"/>
              <TextBlock Text="systemPrompt (personalidade; vazio = padrão)" Foreground="#9A9AA5" FontSize="11" Margin="0,14,0,4"/>
              <TextBox x:Name="SetSys" AcceptsReturn="True" TextWrapping="Wrap" Height="110" VerticalScrollBarVisibility="Auto"/>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@
        [xml]$sx = Theme-Xaml $sxStr
        $sw = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($sx))
        $g = @{}
        foreach ($n in 'SetClose','SetProfile','SetKey','SetBase','SetFast','SetBig','SetVision','SetModels','SetListModels','SetW','SetH','SetCenter','SetTop','SetOpacity','SetOpVal','SetFont','SetFontSize','SetColors','SetResetColors','SetPrevHost','SetThemeName','SetThemeSave','SetThemeList','SetThemeLoad','SetThemeDel','SetSearch','SetMaxTok','SetCache','SetHideBlur','SetSys','SetStatus','SetApply','SetCancel') {
            $g[$n] = $sw.FindName($n)
        }
        Add-OpacityWheel $sw   # Ctrl+roda funciona tambem com o dialogo aberto/em cima
        $sw.Opacity = $script:baseOpacity   # dialogo abre ja na opacidade da janela principal
        # ---- carrega valores atuais ----
        $profNames = @($cfg.profiles.PSObject.Properties.Name)
        $g['SetProfile'].ItemsSource = $profNames
        $g['SetProfile'].SelectedItem = [string]$cfg.profile
        $g['SetSearch'].ItemsSource = @('zai-server', 'bing', 'zai')
        $g['SetSearch'].SelectedItem = [string]$cfg.searchEngine
        $g['SetFont'].ItemsSource = @('Cascadia Mono, Consolas', 'Cascadia Code, Consolas', 'Consolas', 'Courier New', 'Segoe UI', 'JetBrains Mono, Consolas')
        $g['SetFont'].Text = "$(if ($cfg.answerFont) { [string]$cfg.answerFont } else { 'Cascadia Mono, Consolas' })"
        $g['SetFontSize'].Text = [string]$(if ($cfg.answerFontSize) { [int]$cfg.answerFontSize } else { 13 })
        $g['SetW'].Text = [string][int]$cfg.window.width
        $g['SetH'].Text = [string][int]$cfg.window.height
        $g['SetCenter'].IsChecked = [bool]$cfg.window.center
        $g['SetTop'].IsChecked = [bool]$cfg.alwaysOnTop
        $op0 = [double]$cfg.windowOpacity; if ($op0 -le 0 -or $op0 -gt 1) { $op0 = 1.0 }
        $g['SetOpacity'].Value = $op0
        $g['SetOpVal'].Text = ('{0:P0}' -f $op0)
        $g['SetMaxTok'].Text = [string][int]$cfg.maxTokens
        $g['SetCache'].IsChecked = [bool]$cfg.promptCache
        $g['SetHideBlur'].IsChecked = [bool]$cfg.hideOnBlur
        $g['SetSys'].Text = "$(if ($cfg.systemPrompt) { [string]$cfg.systemPrompt } else { '' })"

        # estado do dialogo em escopo de SCRIPT + handlers como scriptblocks simples:
        # "$script:" dentro de GetNewClosure resolve no modulo da closure, NAO aqui (licao ask_user)
        $script:setG = $g
        $script:setSW = $sw
        $script:setProfNames = $profNames
        $script:setFillProf = { param([string]$pn)
            $p = $cfg.profiles.$pn
            if (-not $p) { return }
            $script:setG['SetBase'].Text   = "$(if (Get-CfgProp $p 'baseUrl') { [string](Get-CfgProp $p 'baseUrl') } else { '' })"
            $script:setG['SetFast'].Text   = "$(if (Get-CfgProp $p 'fastModel') { [string](Get-CfgProp $p 'fastModel') } else { '' })"
            $script:setG['SetBig'].Text    = "$(if (Get-CfgProp $p 'bigModel')  { [string](Get-CfgProp $p 'bigModel')  } else { '' })"
            $script:setG['SetVision'].Text = "$(if (Get-CfgProp $p 'visionModel') { [string](Get-CfgProp $p 'visionModel') } else { '' })"
            $ms = @(Get-CfgProp $p 'models') | ForEach-Object { [string]$_ }
            $script:setG['SetModels'].Text = $ms -join ', '
            $script:setG['SetKey'].Clear()
        }
        $g['SetProfile'].Add_SelectionChanged({ param($s, $e)
            & $script:setFillProf ([string]$s.SelectedItem)
        })
        & $script:setFillProf ([string]$cfg.profile)

        # ---- grade de cores (swatch + nome + hex) ----
        $colorKeys = @('bg','card','panel','input','border','fg','dim','status','q','accent','accent2','code','trayA','trayB')
        # v3.15: nomes legiveis (tooltip mostra a chave usada no json/LEIA-ME)
        $colorNames = @{
            bg = 'Fundo da janela';    card = 'Card da resposta';   panel = 'Painéis/diálogos'
            input = 'Caixa de texto';  border = 'Bordas';           fg = 'Texto principal'
            dim = 'Texto secundário';  status = 'Barra de status';  q = 'Pergunta'
            accent = 'Destaque/enviar'; accent2 = 'Destaque 2';     code = 'Código'
            trayA = 'Bandeja (início)'; trayB = 'Bandeja (fim)'
        }
        $colorDesc = @{
            bg      = 'fundo geral da janela principal'
            card    = 'fundo dos balões de pergunta e resposta'
            panel   = 'fundo de diálogos e barras (config, histórico, confirmações)'
            input   = 'fundo da caixa de digitação'
            border  = 'bordas, divisores e molduras'
            fg      = 'texto principal (respostas e caixa)'
            dim     = 'texto apagado: notas, modelo, dicas'
            status  = 'texto do rodapé / barra de status'
            q       = 'cor da pergunta ecoada na conversa'
            accent  = 'botão enviar, seleções e links'
            accent2 = 'tom secundário do destaque (hover)'
            code    = 'trechos de código no meio do texto'
            trayA   = 'início do gradiente do ícone da bandeja'
            trayB   = 'fim do gradiente do ícone da bandeja'
        }
        $boxes = @{}
        foreach ($k in $colorKeys) {
            $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'; $row.Margin = '0,0,8,6'
            $swRect = [System.Windows.Shapes.Rectangle]::new()
            $swRect.Width = 16; $swRect.Height = 16
            $swRect.Stroke = '#3A3A44'; $swRect.StrokeThickness = 1
            try { $swRect.Fill = $T[$k] } catch {}
            $lbl = [System.Windows.Controls.TextBlock]::new()
            $lbl.Text = $colorNames[$k]; $lbl.Width = 120; $lbl.Foreground = $T.status; $lbl.FontSize = (FSz 11)
            $lbl.ToolTip = $colorDesc[$k]
            $lbl.FontFamily = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas')
            $lbl.VerticalAlignment = 'Center'
            $bx = [System.Windows.Controls.TextBox]::new()
            $bx.Width = 90; $bx.FontFamily = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas'); $bx.FontSize = (FSz 11)
            $bx.Text = $T[$k]; $bx.VerticalAlignment = 'Center'
            $bx.Tag = $swRect
            $bx.Add_TextChanged({ param($s2, $e2)
                try { $s2.Tag.Fill = ([System.Windows.Media.ColorConverter]::ConvertFromString($s2.Text)) -as [System.Windows.Media.SolidColorBrush] } catch {}
                if ($script:setPrevUpd) { & $script:setPrevUpd }
            })
            # v3.13: clicar no swatch abre o seletor visual (arco-iris) — o hex escolhido volta pra caixa
            $swRect.Tag = $bx
            $swRect.Cursor = [System.Windows.Input.Cursors]::Hand
            $swRect.ToolTip = 'clique para escolher a cor no seletor visual'
            $swRect.Add_MouseLeftButtonDown({ param($s2, $e2)
                try {
                    $hex2 = Show-ColorPicker ([string]$s2.Tag.Text)
                    if ($hex2) { $s2.Tag.Text = $hex2 }
                } catch { Log ('picker erro: ' + $_) }
                $e2.Handled = $true
            }.GetNewClosure())
            # v3.16: ⟲ volta SO esta cor pro padrao (Tag carrega caixa + valor default)
            $rst = [System.Windows.Controls.Button]::new()
            $rst.Content = '⟲'; $rst.Width = 24; $rst.MinWidth = 24; $rst.Padding = '0,0'
            $rst.FontSize = (FSz 11); $rst.Margin = '4,0,0,0'; $rst.VerticalAlignment = 'Center'
            $rst.ToolTip = 'voltar esta cor para o padrão'
            $rst.Tag = @{ box = $bx; def = $themeDefaults[$k] }
            $rst.Add_Click({ param($s2, $e2)
                try { $s2.Tag.box.Text = $s2.Tag.def } catch { Log ('reset cor: ' + $_) }
            })
            $null = $row.Children.Add($swRect); $null = $row.Children.Add($lbl); $null = $row.Children.Add($rst); $null = $row.Children.Add($bx)
            $null = $g['SetColors'].Children.Add($row)
            $boxes[$k] = $bx
        }
        $script:setBoxes = $boxes
        $script:setColorKeys = $colorKeys

        # ---- v3.15: mini ZQuick — espelho das cores ao vivo (todas as 14 chaves) ----
        $pv = @{}
        $mini = [System.Windows.Controls.Border]::new()
        $mini.BorderThickness = '1'; $mini.CornerRadius = '4'; $mini.Padding = '6'
        $mp = [System.Windows.Controls.StackPanel]::new(); $mini.Child = $mp
        # barra de titulo fake (panel) com bandeja em gradiente + ▢ ✕
        $tbar = [System.Windows.Controls.Border]::new(); $tbar.Padding = '6,3'; $tbar.CornerRadius = '3'
        $tdp = [System.Windows.Controls.DockPanel]::new(); $tbar.Child = $tdp
        $trayR = [System.Windows.Shapes.Rectangle]::new(); $trayR.Width = 14; $trayR.Height = 10
        $trayR.ToolTip = 'ícone da bandeja (trayA → trayB)'
        [System.Windows.Controls.DockPanel]::SetDock($trayR, 'Right')
        $trayBr = [System.Windows.Media.LinearGradientBrush]::new()
        $trayBr.StartPoint = [System.Windows.Point]::new(0, 0); $trayBr.EndPoint = [System.Windows.Point]::new(1, 0)
        $null = $trayBr.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Colors]::White, 0.0))
        $null = $trayBr.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Colors]::Black, 1.0))
        $trayR.Fill = $trayBr
        $xt = [System.Windows.Controls.TextBlock]::new(); $xt.Text = ' ▢ ✕'
        [System.Windows.Controls.DockPanel]::SetDock($xt, 'Right'); $xt.FontSize = (FSz 9)
        $tt = [System.Windows.Controls.TextBlock]::new(); $tt.Text = 'ZQuick — busca'
        $null = $tdp.Children.Add($trayR); $null = $tdp.Children.Add($xt); $null = $tdp.Children.Add($tt)
        $null = $mp.Children.Add($tbar)
        # pergunta (q)
        $qt = [System.Windows.Controls.TextBlock]::new(); $qt.Text = '❓ sua pergunta aparece aqui'
        $qt.TextWrapping = 'Wrap'; $qt.Margin = '0,6,0,4'
        $null = $mp.Children.Add($qt)
        # card de resposta (card) com texto (fg), codigo (code) e nota (dim)
        $cardB = [System.Windows.Controls.Border]::new(); $cardB.Padding = '6'; $cardB.CornerRadius = '3'
        $cardP = [System.Windows.Controls.StackPanel]::new(); $cardB.Child = $cardP
        $at = [System.Windows.Controls.TextBlock]::new(); $at.TextWrapping = 'Wrap'
        $at.Inlines.Add('Resposta do assistente — texto com ')
        $codeRun = [System.Windows.Documents.Run]::new('código')
        $at.Inlines.Add($codeRun); $at.Inlines.Add(' no meio.')
        $nt = [System.Windows.Controls.TextBlock]::new(); $nt.Text = 'nota secundária · respondido em 2s'
        $nt.Margin = '0,2,0,0'; $nt.FontSize = (FSz 10)
        $null = $cardP.Children.Add($at); $null = $cardP.Children.Add($nt)
        $null = $mp.Children.Add($cardB)
        # rodape: status + fontes (accent2)
        $srow = [System.Windows.Controls.DockPanel]::new(); $srow.Margin = '0,4,0,0'
        $src = [System.Windows.Controls.TextBlock]::new(); $src.Text = '🌐 [1] fontes'
        [System.Windows.Controls.DockPanel]::SetDock($src, 'Right')
        $stt = [System.Windows.Controls.TextBlock]::new(); $stt.Text = 'glm-5.3 • ctx 12%'
        $null = $srow.Children.Add($src); $null = $srow.Children.Add($stt)
        $null = $mp.Children.Add($srow)
        # composer: caixa (input+dim) + botao enviar (accent)
        $irow = [System.Windows.Controls.DockPanel]::new(); $irow.Margin = '0,6,0,0'
        $sendB = [System.Windows.Controls.Button]::new(); $sendB.Content = '➤'; $sendB.Padding = '8,2'
        [System.Windows.Controls.DockPanel]::SetDock($sendB, 'Right')
        $inB = [System.Windows.Controls.Border]::new(); $inB.Padding = '5,3'; $inB.CornerRadius = '2'
        $inT = [System.Windows.Controls.TextBlock]::new(); $inT.Text = 'digite aqui…'
        $inB.Child = $inT
        $null = $irow.Children.Add($sendB); $null = $irow.Children.Add($inB)
        $null = $mp.Children.Add($irow)

        $pv['bg'] = $mini; $pv['border'] = $mini; $pv['host'] = $g['SetPrevHost']
        $pv['panel'] = $tbar; $pv['status'] = @($stt, $tt); $pv['dim'] = @($nt, $xt, $inT)
        $pv['q'] = $qt; $pv['card'] = $cardB; $pv['fg'] = $at; $pv['code'] = $codeRun
        $pv['accent'] = $sendB; $pv['accent2'] = $src; $pv['input'] = $inB; $pv['tray'] = $trayBr
        $g['SetPrevHost'].Child = $mini
        $script:setPrev = $pv
        # repinta o mini a cada tecla no hex (valores parciais/invalidos sao ignorados)
        $script:setPrevUpd = {
            foreach ($k in $script:setColorKeys) {
                $hx = ([string]$script:setBoxes[$k].Text).Trim()
                if ($hx -notmatch '^#[0-9A-Fa-f]{6}$') { continue }
                try {
                    $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($hx))
                    switch ($k) {
                        'bg'      { $script:setPrev['bg'].Background = $b }
                        'card'    { $script:setPrev['card'].Background = $b }
                        'panel'   { $script:setPrev['panel'].Background = $b }
                        'input'   { $script:setPrev['input'].Background = $b }
                        'border'  { $script:setPrev['border'].BorderBrush = $b; $script:setPrev['host'].BorderBrush = $b }
                        'fg'      { $script:setPrev['fg'].Foreground = $b }
                        'dim'     { foreach ($d in $script:setPrev['dim']) { $d.Foreground = $b } }
                        'status'  { foreach ($s3 in $script:setPrev['status']) { $s3.Foreground = $b } }
                        'q'       { $script:setPrev['q'].Foreground = $b }
                        'code'    { $script:setPrev['code'].Foreground = $b }
                        'accent'  { $script:setPrev['accent'].Background = $b }
                        'accent2' { $script:setPrev['accent2'].Foreground = $b }
                        'trayA'   { $script:setPrev['tray'].GradientStops[0].Color = $b.Color }
                        'trayB'   { $script:setPrev['tray'].GradientStops[1].Color = $b.Color }
                    }
                } catch {}
            }
        }
        & $script:setPrevUpd   # pinta com as cores atuais na abertura

        $g['SetResetColors'].Add_Click({
            foreach ($k in $script:setColorKeys) { $script:setBoxes[$k].Text = $themeDefaults[$k] }
        })

        # ---- v3.16: temas salvos (nome -> 14 cores, no zquick.json) ----
        $script:setFillThemes = {
            $tn = @()
            try { if ($cfg.themes) { $tn = @($cfg.themes.PSObject.Properties.Name | Sort-Object) } } catch {}
            $all = @($builtinThemes.Keys) + $tn   # embutidos (padrão, matrix) primeiro
            $script:setG['SetThemeList'].ItemsSource = $all
            return $all
        }
        & $script:setFillThemes
        $g['SetThemeSave'].Add_Click({
            try {
                $nm = ([string]$script:setG['SetThemeName'].Text).Trim()
                if (-not $nm) { $script:setG['SetStatus'].Text = '✕ dê um nome ao tema'; return }
                if ($builtinThemes.Contains($nm)) { $script:setG['SetStatus'].Text = "✕ '$nm' é tema embutido — salve com outro nome"; return }
                $hexes = [ordered]@{}
                foreach ($k in $script:setColorKeys) {
                    $hx = ([string]$script:setBoxes[$k].Text).Trim()
                    if ($hx -notmatch '^#[0-9A-Fa-f]{6}$') { $script:setG['SetStatus'].Text = "✕ cor $k inválida ($hx)"; return }
                    $hexes[$k] = $hx
                }
                if (-not $cfg.themes) { $cfg.themes = [pscustomobject]@{} }
                Set-CfgProp $cfg.themes $nm ([pscustomobject]$hexes)
                Save-Config
                $null = & $script:setFillThemes
                $script:setG['SetThemeList'].SelectedItem = $nm
                $script:setG['SetThemeName'].Text = ''
                $script:setG['SetStatus'].Text = "✓ tema salvo: $nm (◀ aplicar quando quiser)"
                Log ('tema: salvo "' + $nm + '"')
            } catch { Log ('tema salvar erro: ' + $_); $script:setG['SetStatus'].Text = '✕ salvar tema: ' + $_ }
        })
        $g['SetThemeLoad'].Add_Click({
            try {
                $nm = [string]$script:setG['SetThemeList'].SelectedItem
                if (-not $nm) { $nm = ([string]$script:setG['SetThemeList'].Text).Trim() }
                $th = $null
                if ($builtinThemes.Contains($nm)) { $th = $builtinThemes[$nm] }
                else { try { if ($cfg.themes) { $th = $cfg.themes.$nm } } catch {} }
                if (-not $th) { $script:setG['SetStatus'].Text = '✕ escolha um tema na lista'; return }
                foreach ($k in $script:setColorKeys) {
                    $hx = [string](Get-CfgProp $th $k)
                    if ($hx -match '^#[0-9A-Fa-f]{6}$') { $script:setBoxes[$k].Text = $hx }
                }
                $script:setG['SetStatus'].Text = "✓ tema `"$nm`" nas caixas — ✔ Aplicar grava"
                Log ('tema: carregado "' + $nm + '"')
            } catch { Log ('tema carregar erro: ' + $_); $script:setG['SetStatus'].Text = '✕ aplicar tema: ' + $_ }
        })
        $g['SetThemeDel'].Add_Click({
            try {
                $nm = [string]$script:setG['SetThemeList'].SelectedItem
                if (-not $nm) { $nm = ([string]$script:setG['SetThemeList'].Text).Trim() }
                if ($builtinThemes.Contains($nm)) { $script:setG['SetStatus'].Text = "✕ '$nm' é tema embutido — não dá pra apagar"; return }
                if (-not $nm -or -not $cfg.themes) { $script:setG['SetStatus'].Text = '✕ escolha um tema para apagar'; return }
                try { $cfg.themes.PSObject.Properties.Remove($nm) } catch {}
                Save-Config
                $null = & $script:setFillThemes
                $script:setG['SetStatus'].Text = "✓ tema apagado: $nm"
                Log ('tema: apagado "' + $nm + '"')
            } catch { Log ('tema apagar erro: ' + $_); $script:setG['SetStatus'].Text = '✕ apagar tema: ' + $_ }
        })

        # ---- preview de opacidade ao vivo ----
        $g['SetOpacity'].Add_ValueChanged({ param($s2, $e2)
            $window.Opacity = $s2.Value
            $script:setSW.Opacity = $s2.Value
            $script:setG['SetOpVal'].Text = ('{0:P0}' -f $s2.Value)
        })

        $script:setSnap = (@($profNames | ForEach-Object {
            $p = $cfg.profiles.$_
            "$_=$([string](Get-CfgProp $p 'baseUrl'))|$([string](Get-CfgProp $p 'fastModel'))|$([string](Get-CfgProp $p 'bigModel'))|$([string](Get-CfgProp $p 'visionModel'))"
        }) -join ';') + "|$($cfg.searchEngine)|$($cfg.maxTokens)|$($cfg.systemPrompt)|$($cfg.promptCache)"

        Log ("config: dialogo (perfis {0})" -f $profNames.Count)

        $g['SetClose'].Add_Click({ try { $script:setSW.DialogResult = $false } catch { try { $script:setSW.Close() } catch {} } })
        $g['SetCancel'].Add_Click({ $window.Opacity = $script:baseOpacity; $script:setSW.Opacity = $script:baseOpacity })   # desfaz preview

        # v3.10: puxa a lista de modelos do provedor (GET /v1/models do padrao Anthropic) e enche a caixa do topo
        $g['SetListModels'].Add_Click({
            try {
                $script:setG['SetStatus'].Text = '🔎 listando modelos da API…'
                [void]$script:setSW.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
                $pn = [string]$script:setG['SetProfile'].SelectedItem
                $p = if ($pn -and $cfg.profiles.$pn) { $cfg.profiles.$pn } else { $cfg.profiles.($cfg.profile) }
                $auth = Resolve-ProfileAuth $p
                $nb = [string]$script:setG['SetBase'].Text.Trim()
                if ($nb) { $auth.base = $nb }
                $nk = [string]$script:setG['SetKey'].Password
                if ($nk) { $auth.key = $nk }
                $r = Invoke-RestMethod -Method Get -Uri ($auth.base.TrimEnd('/') + '/v1/models') `
                     -Headers @{ 'x-api-key' = $auth.key; 'anthropic-version' = '2023-06-01' } -TimeoutSec 25
                $ids = @($r.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
                if (-not $ids.Count) { throw 'resposta veio sem modelos' }
                # ⭐ recomendado = maior versão ENTRE os "cheios" (sem sufixo flash/turbo/air/mini/lite/preview), se existir
                $rec = @($ids | Where-Object { $_ -notmatch '(?i)flash|turbo|air|mini|lite|preview|thinking' } |
                    Sort-Object { $v = ($_ -replace '[^0-9.]','').Trim('.'); try { [version]$v } catch { [version]'0.0' } })[-1]
                $disp = @($ids | ForEach-Object { if ($rec -and $_ -eq $rec) { "$_ ⭐" } else { $_ } })
                $script:setG['SetModels'].Text = $disp -join ', '
                $script:setG['SetStatus'].Text = $(if ($rec) { "✔ $($ids.Count) modelos — ⭐ recomendado: $rec (Aplicar grava)" } else { "✔ $($ids.Count) modelos carregados — Aplicar grava" })
                Log ("config: {0} modelos listados da API ({1}){2}" -f $ids.Count, $auth.base, $(if ($rec) { " — ⭐ $rec" } else { '' }))
            } catch {
                $script:setG['SetStatus'].Text = '✕ listar: ' + $_.Exception.Message
                Log ("config: listar modelos falhou: {0}" -f $_.Exception.Message)
            }
        })

        $g['SetApply'].Add_Click({
            try {
                $bad = @()
                # perfil
                $pn = [string]$script:setG['SetProfile'].SelectedItem
                if ($pn -and $cfg.profiles.$pn) {
                    $p = $cfg.profiles.$pn
                    $nb = $script:setG['SetBase'].Text.Trim()
                    Set-CfgProp $p 'baseUrl' $(if ($nb) { $nb } else { $null })
                    foreach ($fld in @(@('SetFast','fastModel'), @('SetBig','bigModel'), @('SetVision','visionModel'))) {
                        $v = $script:setG[$fld[0]].Text.Trim()
                        if ($v) { Set-CfgProp $p $fld[1] $v }
                    }
                    $nk = $script:setG['SetKey'].Password.Trim()
                    if ($nk) { Set-CfgProp $p 'apiKey' $nk }
                    $ml = @($script:setG['SetModels'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($ml.Count -gt 0) { Set-CfgProp $p 'models' $ml }
                }
                # janela
                $wv = 0; $hv = 0
                if (-not [int]::TryParse($script:setG['SetW'].Text.Trim(), [ref]$wv) -or $wv -lt 520 -or $wv -gt 3840) { $bad += 'largura (520-3840)' }
                if (-not [int]::TryParse($script:setG['SetH'].Text.Trim(), [ref]$hv) -or $hv -lt 360 -or $hv -gt 2160) { $bad += 'altura (360-2160)' }
                if ($bad.Count -eq 0) { $cfg.window.width = $wv; $cfg.window.height = $hv }
                $cfg.window.center = [bool]$script:setG['SetCenter'].IsChecked
                $cfg.alwaysOnTop = [bool]$script:setG['SetTop'].IsChecked
                $opv = [double]$script:setG['SetOpacity'].Value
                $cfg.windowOpacity = $opv
                # aparencia
                $fsz = 0.0
                if (-not [double]::TryParse($script:setG['SetFontSize'].Text.Trim(), [ref]$fsz) -or $fsz -lt 10 -or $fsz -gt 22) { $bad += 'tamanho da fonte (10-22)'; $fsz = 0 }
                $fnt = $script:setG['SetFont'].Text.Trim()
                if ($bad.Count -eq 0) {
                    $cfg.answerFontSize = $fsz
                    $cfg.answerFont = $fnt
                }
                $newTheme = [ordered]@{}
                foreach ($k in $script:setColorKeys) {
                    $hx = $script:setBoxes[$k].Text.Trim()
                    if ($hx -match '^#[0-9A-Fa-f]{6}$') { $newTheme[$k] = $hx }
                    else { $bad += "cor $k"; $newTheme[$k] = $T[$k] }
                }
                $allDef = $true
                foreach ($k in $script:setColorKeys) { if ($newTheme[$k] -ne $themeDefaults[$k]) { $allDef = $false } }
                if ($bad.Count -eq 0) {
                    $cfg.theme = $(if ($allDef) { $null } else { [pscustomobject]$newTheme })
                    foreach ($k in $script:setColorKeys) { $T[$k] = $newTheme[$k] }
                }
                # geral
                $cfg.searchEngine = [string]$script:setG['SetSearch'].SelectedItem
                $mt = 0
                if ([int]::TryParse($script:setG['SetMaxTok'].Text.Trim(), [ref]$mt) -and $mt -ge 512 -and $mt -le 32768) { $cfg.maxTokens = $mt }
                else { $bad += 'maxTokens (512-32768)' }
                $cfg.promptCache = [bool]$script:setG['SetCache'].IsChecked
                $cfg.hideOnBlur  = [bool]$script:setG['SetHideBlur'].IsChecked
                $sp = $script:setG['SetSys'].Text.Trim()
                $cfg.systemPrompt = $(if ($sp) { $sp } else { $null })

                if ($bad.Count -gt 0) {
                    $script:setG['SetStatus'].Text = '✕ não aplicado: ' + ($bad -join ', ')
                    return
                }
                Save-Config

                # ---- aplica ao vivo o que dá ----
                $window.Width = $cfg.window.width; $window.Height = $cfg.window.height
                $script:baseOpacity = $cfg.windowOpacity; $window.Opacity = $script:baseOpacity; $script:setSW.Opacity = $script:baseOpacity
                $window.Topmost = [bool]$cfg.alwaysOnTop; Set-TopBtnVisual ([bool]$cfg.alwaysOnTop)
                # v3.8: fonte re-escala a janela principal TODA ao vivo (dialogos pegam na proxima abertura)
                try { Set-FontScale ([double]$cfg.answerFontSize / 13.0) } catch { Log "fontscale apply: $_" }
                try { $AnswerDoc.FontFamily = [System.Windows.Media.FontFamily]::new([string]$cfg.answerFont) } catch {}
                $window.Background = $T.bg
                $AnswerDoc.Foreground = $T.fg
                $StatusText.Foreground = $T.status; $ModelText.Foreground = $T.dim
                $InputBox.Background = $T.input; $InputBox.Foreground = $T.fg; $InputBox.CaretBrush = $T.fg
                if ($cfg.window.center) { Center-Window }
                # motor usa varios desses valores -> recria se mudou algo relevante
                $snapNow = (@($script:setProfNames | ForEach-Object {
                    $p2 = $cfg.profiles.$_
                    "$_=$([string](Get-CfgProp $p2 'baseUrl'))|$([string](Get-CfgProp $p2 'fastModel'))|$([string](Get-CfgProp $p2 'bigModel'))|$([string](Get-CfgProp $p2 'visionModel'))"
                }) -join ';') + "|$($cfg.searchEngine)|$($cfg.maxTokens)|$($cfg.systemPrompt)|$($cfg.promptCache)"
                $engNote = ''
                if ($snapNow -ne $script:setSnap -or $script:setG['SetKey'].Password.Trim()) {
                    if (-not $script:busy -and $script:engine) { $script:engine = $null; $engNote = ' • motor recriado no próximo envio' }
                }
                if ($pn -eq [string]$cfg.profile) { Update-ModelBox }
                Update-ProfileBox
                Log ("config: aplicado (janela {0}x{1}, opacidade {2:P0}, fonte {3}pt ({4:P0} da interface){5})" -f $cfg.window.width, $cfg.window.height, $cfg.windowOpacity, $cfg.answerFontSize, ($cfg.answerFontSize / 13.0), $engNote)
                $script:setG['SetStatus'].Text = '✓ aplicado — fonte na interface toda; cores completas ao reabrir' + $engNote
                $script:setG['SetKey'].Clear()
            } catch { Log "config erro: $_"; $script:setG['SetStatus'].Text = "✕ $_" }
        })

        $sw.Owner = $window
        try { $null = $sw.ShowDialog() } catch { try { $sw.Close() } catch {}; throw }
        $window.Opacity = $script:baseOpacity   # garante preview desfeito
    } catch { Log "settings: $_" }
}

# ---------- prompt de texto simples (v3.13: renomear conversa do historico) ----------
function Show-InputPrompt([string]$title, [string]$label, [string]$initial) {
    $w = [System.Windows.Window]::new()
    $w.Title = $title; $w.Width = 420; $w.SizeToContent = 'Height'
    $w.WindowStartupLocation = 'CenterOwner'; $w.ResizeMode = 'NoResize'
    $w.ShowInTaskbar = $false
    $w.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.panel))
    $w.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.fg))
    $w.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI'); $w.FontSize = 13
    $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Margin = '16'
    $w.Content = $sp
    $lb = [System.Windows.Controls.TextBlock]::new(); $lb.Text = $label; $lb.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.status))
    $null = $sp.Children.Add($lb)
    $tb = [System.Windows.Controls.TextBox]::new(); $tb.Margin = '0,10,0,0'; $tb.Padding = '8,6'
    $tb.Text = [string]$initial
    $tb.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.input))
    $tb.Foreground = $w.Foreground; $tb.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.border))
    $tb.CaretBrush = $w.Foreground
    $null = $sp.Children.Add($tb)
    $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,14,0,0'
    $okB = [System.Windows.Controls.Button]::new(); $okB.Content = 'OK'; $okB.Padding = '16,5'; $okB.IsDefault = $true
    $noB = [System.Windows.Controls.Button]::new(); $noB.Content = 'Cancelar'; $noB.Padding = '12,5'; $noB.Margin = '8,0,0,0'
    $null = $row.Children.Add($okB); $null = $row.Children.Add($noB)
    $null = $sp.Children.Add($row)
    $okB.Add_Click({ param($s2, $e2) try { $w.DialogResult = $true } catch { try { $w.Close() } catch {} } }.GetNewClosure())
    $noB.Add_Click({ param($s2, $e2) try { $w.DialogResult = $false } catch { try { $w.Close() } catch {} } }.GetNewClosure())
    $w.Add_PreviewKeyUp({ param($s2, $e2) if ($e2.Key -eq 'Escape') { try { $s2.DialogResult = $false } catch { try { $s2.Close() } catch {} }; $e2.Handled = $true } }.GetNewClosure())
    try { $w.Owner = $window } catch {}
    $w.Add_ContentRendered({ [void]$tb.Focus(); $tb.SelectAll() }.GetNewClosure())
    $dr = $false
    try { $dr = [bool]$w.ShowDialog() } catch { try { $w.Close() } catch {} }
    if ($dr) { return ([string]$tb.Text).Trim() }
    return $null
}

# ---------- color picker visual (v3.13): arco-iris clicavel no lugar de so' digitar hex ----------
function Get-HsvFromHex([string]$hex) {
    try {
        $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
        $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
        $mx = [Math]::Max($r, [Math]::Max($g, $b)); $mn = [Math]::Min($r, [Math]::Min($g, $b))
        if ($mx -le 0) { return @(0, 0, 0) }
        $d = $mx - $mn
        if ($d -eq 0) { return @(0, 0, $mx) }
        if ($mx -eq $r) { $h = ((($g - $b) / $d) % 6) * 60 } elseif ($mx -eq $g) { $h = ((($b - $r) / $d) + 2) * 60 } else { $h = ((($r - $g) / $d) + 4) * 60 }
        if ($h -lt 0) { $h += 360 }
        return @($h, $d / $mx, $mx)
    } catch { return @(0, 0, 1) }
}
function ConvertTo-HexColor([double]$h, [double]$s, [double]$v) {
    $h = $h % 360; if ($h -lt 0) { $h += 360 }
    $c = $v * $s
    $hp = $h / 60.0
    $x = $c * (1 - [Math]::Abs(($hp % 2) - 1))
    $r0 = 0.0; $g0 = 0.0; $b0 = 0.0
    if     ($hp -lt 1) { $r0 = $c; $g0 = $x }
    elseif ($hp -lt 2) { $r0 = $x; $g0 = $c }
    elseif ($hp -lt 3) { $g0 = $c; $b0 = $x }
    elseif ($hp -lt 4) { $g0 = $x; $b0 = $c }
    elseif ($hp -lt 5) { $r0 = $x; $b0 = $c }
    else               { $r0 = $c; $b0 = $x }
    $m = $v - $c
    # clamp 255: [int]255.5 arredonda p/ 256 (banker's) e '#100100100' e hex
    # invalido — era o "O token nao e valido" que derrubava o seletor (v3.14.1)
    '#{0:X2}{1:X2}{2:X2}' -f ([Math]::Min(255, [int](($r0 + $m) * 255 + 0.5))), ([Math]::Min(255, [int](($g0 + $m) * 255 + 0.5))), ([Math]::Min(255, [int](($b0 + $m) * 255 + 0.5)))
}
function Show-ColorPicker([string]$initialHex) {
    $st = @{ h = 0.0; s = 1.0; v = 1.0; skip = $false }
    $hv = Get-HsvFromHex $initialHex
    $st.h = [double]$hv[0]; $st.s = [double]$hv[1]; $st.v = [double]$hv[2]

    $w = [System.Windows.Window]::new()
    $w.Title = 'ZQuick — cor'; $w.Width = 420; $w.SizeToContent = 'Height'
    $w.WindowStartupLocation = 'CenterOwner'; $w.ResizeMode = 'NoResize'
    $w.ShowInTaskbar = $false
    $w.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.panel))
    $w.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.fg))
    $w.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI'); $w.FontSize = 12
    $root = [System.Windows.Controls.StackPanel]::new(); $root.Margin = '16'
    $w.Content = $root

    # espectro: gradiente de matiz (horizontal) + overlay branco->transparente (saturacao, vertical)
    $spec = [System.Windows.Controls.Grid]::new(); $spec.Height = 150
    $hue = [System.Windows.Media.LinearGradientBrush]::new()
    $hue.StartPoint = [System.Windows.Point]::new(0, 0); $hue.EndPoint = [System.Windows.Point]::new(1, 0)
    $stops = @('#FF0000','#FFFF00','#00FF00','#00FFFF','#0000FF','#FF00FF','#FF0000')
    for ($i = 0; $i -lt $stops.Count; $i++) {
        $null = $hue.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.ColorConverter]::ConvertFromString($stops[$i]), $i / 6.0))
    }
    $rHue = [System.Windows.Shapes.Rectangle]::new(); $rHue.Fill = $hue
    $white = [System.Windows.Media.LinearGradientBrush]::new()
    $white.StartPoint = [System.Windows.Point]::new(0, 0); $white.EndPoint = [System.Windows.Point]::new(0, 1)
    $null = $white.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(255,255,255,255), 0.0))
    $null = $white.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0,255,255,255), 1.0))
    $rWhite = [System.Windows.Shapes.Rectangle]::new(); $rWhite.Fill = $white
    $mark = [System.Windows.Shapes.Ellipse]::new(); $mark.Width = 14; $mark.Height = 14
    $mark.Stroke = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Colors]::White); $mark.StrokeThickness = 2
    $mark.Fill = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Colors]::Transparent)
    $mark.HorizontalAlignment = 'Left'; $mark.VerticalAlignment = 'Top'; $mark.IsHitTestVisible = $false
    $null = $spec.Children.Add($rHue); $null = $spec.Children.Add($rWhite); $null = $spec.Children.Add($mark)
    $null = $root.Children.Add($spec)

    # brilho + preview + hex
    $rowV = [System.Windows.Controls.StackPanel]::new(); $rowV.Orientation = 'Horizontal'; $rowV.Margin = '0,12,0,0'
    $lblV = [System.Windows.Controls.TextBlock]::new(); $lblV.Text = 'brilho'; $lblV.Width = 46; $lblV.VerticalAlignment = 'Center'
    $lblV.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.status))
    $sl = [System.Windows.Controls.Slider]::new(); $sl.Minimum = 5; $sl.Maximum = 100; $sl.Width = 180
    $sl.Value = [Math]::Round($st.v * 100); $sl.VerticalAlignment = 'Center'
    $prev = [System.Windows.Controls.Border]::new(); $prev.Width = 42; $prev.Height = 22; $prev.Margin = '14,0,0,0'
    $prev.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.border)); $prev.BorderThickness = '1'
    $hexTb = [System.Windows.Controls.TextBox]::new(); $hexTb.Width = 88; $hexTb.Margin = '14,0,0,0'; $hexTb.VerticalAlignment = 'Center'
    $hexTb.FontFamily = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas')
    $hexTb.Text = ([string]$initialHex).Trim()
    $hexTb.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($T.input))
    $hexTb.Foreground = $w.Foreground; $hexTb.CaretBrush = $w.Foreground
    $null = $rowV.Children.Add($lblV); $null = $rowV.Children.Add($sl); $null = $rowV.Children.Add($prev); $null = $rowV.Children.Add($hexTb)
    $null = $root.Children.Add($rowV)

    $rowB = [System.Windows.Controls.StackPanel]::new(); $rowB.Orientation = 'Horizontal'; $rowB.HorizontalAlignment = 'Right'; $rowB.Margin = '0,14,0,0'
    $okB = [System.Windows.Controls.Button]::new(); $okB.Content = 'OK'; $okB.Padding = '16,5'; $okB.IsDefault = $true
    $noB = [System.Windows.Controls.Button]::new(); $noB.Content = 'Cancelar'; $noB.Padding = '12,5'; $noB.Margin = '8,0,0,0'
    $null = $rowB.Children.Add($okB); $null = $rowB.Children.Add($noB)
    $null = $root.Children.Add($rowB)

    # atualizacao centralizada (hex, preview, marcador, slider) com guarda anti-loop
    $upd = {
        if ($st.skip) { return }
        $hex = ConvertTo-HexColor $st.h $st.s $st.v
        $st.skip = $true
        $hexTb.Text = $hex
        $sl.Value = [Math]::Round($st.v * 100)
        $st.skip = $false
        $prev.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
        $x = ($st.h / 360.0) * [Math]::Max(1.0, $spec.ActualWidth)
        $y = $st.s * [Math]::Max(1.0, $spec.ActualHeight)
        $mark.Margin = [System.Windows.Thickness]::new([Math]::Max(0, $x - 7), [Math]::Max(0, $y - 7), 0, 0)
    }.GetNewClosure()
    $pick = {
        param($s2, $e2)
        $p = $e2.GetPosition($s2)
        $st.h = [Math]::Min(359.9, [Math]::Max(0.0, ($p.X / [Math]::Max(1.0, $s2.ActualWidth)) * 360))
        $st.s = [Math]::Min(1.0, [Math]::Max(0.0, $p.Y / [Math]::Max(1.0, $s2.ActualHeight)))
        & $upd
    }.GetNewClosure()
    $spec.Add_MouseLeftButtonDown({ param($s2, $e2) $null = $s2.CaptureMouse(); & $pick $s2 $e2; $e2.Handled = $true }.GetNewClosure())
    $spec.Add_MouseMove({ param($s2, $e2) if ($s2.IsMouseCaptured) { & $pick $s2 $e2 } }.GetNewClosure())
    $spec.Add_MouseLeftButtonUp({ param($s2, $e2) $s2.ReleaseMouseCapture() }.GetNewClosure())
    $sl.Add_ValueChanged({ param($s2, $e2) if (-not $st.skip) { $st.v = $s2.Value / 100.0; & $upd } }.GetNewClosure())
    $hexTb.Add_TextChanged({ param($s2, $e2)
        if ($st.skip) { return }
        $t = ([string]$s2.Text).Trim()
        if ($t -match '^#[0-9A-Fa-f]{6}$') {
            $hv2 = Get-HsvFromHex $t
            $st.h = [double]$hv2[0]; $st.s = [double]$hv2[1]; $st.v = [double]$hv2[2]
            $st.skip = $true
            $sl.Value = [Math]::Round($st.v * 100)
            $st.skip = $false
            $prev.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($t.ToUpper()))
            $x = ($st.h / 360.0) * [Math]::Max(1.0, $spec.ActualWidth)
            $y = $st.s * [Math]::Max(1.0, $spec.ActualHeight)
            $mark.Margin = [System.Windows.Thickness]::new([Math]::Max(0, $x - 7), [Math]::Max(0, $y - 7), 0, 0)
        }
    }.GetNewClosure())
    $okB.Add_Click({ param($s2, $e2) try { $w.DialogResult = $true } catch { try { $w.Close() } catch {} } }.GetNewClosure())
    $noB.Add_Click({ param($s2, $e2) try { $w.DialogResult = $false } catch { try { $w.Close() } catch {} } }.GetNewClosure())
    $w.Add_PreviewKeyUp({ param($s2, $e2) if ($e2.Key -eq 'Escape') { try { $s2.DialogResult = $false } catch { try { $s2.Close() } catch {} }; $e2.Handled = $true } }.GetNewClosure())
    $w.Add_ContentRendered({ & $upd }.GetNewClosure())
    try { $w.Owner = $window } catch {}
    $dr = $false
    try { $dr = [bool]$w.ShowDialog() } catch { try { $w.Close() } catch {}; Log ('picker erro: ' + $_) }
    if ($dr) {
        $t = ([string]$hexTb.Text).Trim()
        if ($t -match '^#[0-9A-Fa-f]{6}$') { return $t.ToUpper() }
        return ConvertTo-HexColor $st.h $st.s $st.v
    }
    return $null
}

function Show-History {
    try {
        New-Item -ItemType Directory -Force $histDir | Out-Null
        $files = @(Get-ChildItem $histDir -Filter 'conv-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 120)
        if ($files.Count -eq 0) { $StatusText.Text = 'sem conversas salvas ainda'; return }
        $hxStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZQuick — histórico" Width="580" Height="500" WindowStartupLocation="CenterOwner"
        WindowStyle="None" ResizeMode="CanResize" AllowsTransparency="True"
        Background="#202024" ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="12">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="36" ResizeBorderThickness="6" GlassFrameThickness="1"
                  CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2A30"/>
      <Setter Property="Foreground" Value="#E8E8EC"/>
      <Setter Property="BorderBrush" Value="#3A3A44"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="ChromeBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E8E8EC"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="9,5"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#3A3A44"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Padding="14,8,4,6">
      <DockPanel>
        <Button DockPanel.Dock="Right" x:Name="HistClose" Content="✕" ToolTip="fechar (Esc)" Style="{StaticResource ChromeBtn}"/>
        <TextBlock Text="🕘 Histórico" FontSize="14" FontWeight="SemiBold" Foreground="#E8E8EC" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
    <Border DockPanel.Dock="Top" Padding="10,8,10,6">
      <TextBox x:Name="Search" Padding="8,8" FontSize="13" ToolTip="filtrar por pergunta ou resposta">
        <TextBox.Style>
          <Style TargetType="TextBox">
            <Setter Property="Background" Value="#16161A"/>
            <Setter Property="Foreground" Value="#E8E8EC"/>
            <Setter Property="BorderBrush" Value="#3A3A44"/>
            <Setter Property="CaretBrush" Value="#E8E8EC"/>
            <Style.Triggers>
              <Trigger Property="Text" Value="">
                <Setter Property="Background">
                  <Setter.Value>
                    <VisualBrush Stretch="None" AlignmentX="Left" AlignmentY="Center">
                      <VisualBrush.Visual>
                        <TextBlock Text="🔍  buscar por pergunta ou resposta…" Foreground="#6E6E7A" FontStyle="Italic" Margin="8,0,0,0"/>
                      </VisualBrush.Visual>
                    </VisualBrush>
                  </Setter.Value>
                </Setter>
              </Trigger>
            </Style.Triggers>
          </Style>
        </TextBox.Style>
      </TextBox>
    </Border>
    <Border DockPanel.Dock="Bottom" Padding="10,8">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <TextBlock x:Name="CountText" Foreground="#6E6E7A" FontSize="11" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="RenBtn" Content="✏" Margin="0,0,8,0" ToolTip="Renomear a conversa selecionada"/>
        <Button x:Name="FavBtn" Content="⭐" Margin="0,0,8,0" ToolTip="Favoritar/desfavoritar — favoritas ficam fixas no topo"/>
        <Button x:Name="DelBtn" Content="Apagar" Margin="0,0,8,0" ToolTip="Apaga a conversa selecionada"/>
        <Button x:Name="OkBtn" Content="Retomar" Padding="14,6" FontWeight="SemiBold" IsDefault="True"/>
      </StackPanel>
    </Border>
    <ListBox x:Name="List" Background="#16161A" Foreground="#E8E8EC" BorderThickness="0" Padding="6"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled"
             ToolTip="duplo clique retoma"/>
  </DockPanel>
</Window>
'@
        [xml]$hx = Theme-Xaml $hxStr
        $hw = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($hx))
        $hlist = $hw.FindName('List')
        $hsearch = $hw.FindName('Search')
        $countText = $hw.FindName('CountText')
        Add-OpacityWheel $hw   # Ctrl+roda funciona tambem com o dialogo aberto/em cima
        $hw.Opacity = $script:baseOpacity   # dialogo abre ja na opacidade da janela principal
        $entries = @()
        foreach ($f in $files) {
            try {
                $j = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                $entries += [pscustomobject]@{ file = $f.FullName; time = [string]$j.time; q = [string]$j.q; a = [string]$j.a; fav = [bool]$j.fav; title = [string]$j.title }
            } catch {}
        }
        # preenche a lista (com filtro por pergunta OU resposta); closure autocontida
        $fill = {
            $f = ([string]$hsearch.Text).Trim()
            $hlist.Items.Clear()
            # v3.13: favoritas fixas no topo; nome renomeado (title) ganha prioridade sobre a pergunta
            foreach ($en in ($entries | Sort-Object @{e = 'fav'; Descending = $true}, @{e = 'time'; Descending = $true})) {
                if ($f -eq '' -or $en.q -like "*$f*" -or $en.a -like "*$f*" -or $en.title -like "*$f*") {
                    $q = [string]$en.title
                    if (-not $q) { $q = [string]$en.q }
                    if (-not $q) { $q = '(imagem)' }
                    if ($q.Length -gt 80) { $q = $q.Substring(0, 80) + '…' }
                    if ($en.fav) { $q = '⭐ ' + $q }
                    $t = [System.Windows.Controls.TextBlock]::new()
                    $t.Text = "{0}  {1}" -f ([datetime]$en.time).ToString('dd/MM HH:mm'), $q
                    $t.TextWrapping = 'Wrap'
                    $t.Tag = $en.file
                    $tip = $en.a -replace '\s+', ' '
                    if ($tip.Length -gt 200) { $tip = $tip.Substring(0, 200) + '…' }
                    $t.ToolTip = $tip
                    $null = $hlist.Items.Add($t)
                }
            }
            if ($hlist.Items.Count -gt 0) { $hlist.SelectedIndex = 0 }
            $countText.Text = "$($hlist.Items.Count) de $($entries.Count) • duplo clique retoma"
        }.GetNewClosure()
        & $fill
        $hsearch.Add_TextChanged({ param($s, $e) & $fill }.GetNewClosure())
        $hw.Owner = $window
        $hw.Add_ContentRendered({ [void]$hsearch.Focus() }.GetNewClosure())
        Log ("historico: dialogo ({0} itens)" -f $entries.Count)

        $hw.FindName('HistClose').Add_Click({ param($s, $e) try { $hw.DialogResult = $false } catch { try { $hw.Close() } catch {} } }.GetNewClosure())
        $hw.FindName('OkBtn').Add_Click({ param($s, $e)
            $sel = $hlist.SelectedItem
            if ($sel) { try { Load-Conversation ([string]$sel.Tag) } catch { Log ('hist load: ' + $_) }; try { $hw.DialogResult = $true } catch { try { $hw.Close() } catch {} } }
        }.GetNewClosure())
        $hlist.Add_MouseDoubleClick({ param($s, $e)
            $sel = $hlist.SelectedItem
            if ($sel) { try { Load-Conversation ([string]$sel.Tag) } catch { Log ('hist load: ' + $_) }; try { $hw.DialogResult = $true } catch { try { $hw.Close() } catch {} } }
        }.GetNewClosure())
        $hw.FindName('DelBtn').Add_Click({
            $sel = $hlist.SelectedItem
            if ($sel) {
                try { Remove-Item ([string]$sel.Tag) -Force -ErrorAction Stop } catch {}
                $hlist.Items.Remove($sel) | Out-Null
                if ($hlist.Items.Count -eq 0) { try { $hw.DialogResult = $false } catch { try { $hw.Close() } catch {} } }
                elseif ($hlist.SelectedIndex -lt 0) { $hlist.SelectedIndex = 0 }
            }
        }.GetNewClosure())
        # v3.13: favoritar/desfavoritar (fica fixa no topo) e renomear a conversa selecionada
        $hw.FindName('FavBtn').Add_Click({
            $sel = $hlist.SelectedItem
            if ($sel) {
                try {
                    $fl = [string]$sel.Tag
                    $j = Get-Content -Path $fl -Raw -Encoding utf8 | ConvertFrom-Json
                    $nv = -not [bool]$j.fav
                    $j | Add-Member -Force NoteProperty fav $nv
                    $j | ConvertTo-Json -Depth 6 | Set-Content -Path $fl -Encoding utf8
                    foreach ($en in $entries) { if ($en.file -eq $fl) { $en.fav = $nv } }
                    & $fill
                    Log ("historico: fav {0} -> {1}" -f (Split-Path $fl -Leaf), $nv)
                } catch { Log "hist-fav: $_" }
            }
        }.GetNewClosure())
        $hw.FindName('RenBtn').Add_Click({
            $sel = $hlist.SelectedItem
            if ($sel) {
                try {
                    $fl = [string]$sel.Tag
                    $j = Get-Content -Path $fl -Raw -Encoding utf8 | ConvertFrom-Json
                    $cur = [string]$j.title
                    if (-not $cur) { $cur = [string]$j.q }
                    $nt = Show-InputPrompt 'Renomear conversa' 'Novo nome:' $cur
                    if ($null -ne $nt -and $nt -ne '') {
                        $j | Add-Member -Force NoteProperty title $nt
                        $j | ConvertTo-Json -Depth 6 | Set-Content -Path $fl -Encoding utf8
                        foreach ($en in $entries) { if ($en.file -eq $fl) { $en.title = $nt } }
                        & $fill
                        Log ("historico: renomeada {0} -> '{1}'" -f (Split-Path $fl -Leaf), $nt)
                    }
                } catch { Log "hist-ren: $_" }
            }
        }.GetNewClosure())
        $hw.Add_PreviewKeyUp({ param($s, $e) if ($e.Key -eq 'Escape') { try { $s.DialogResult = $false } catch { try { $s.Close() } catch {} }; $e.Handled = $true } })
        try { $null = $hw.ShowDialog() } catch { try { $hw.Close() } catch {}; throw }
        # apos fechar o dialogo o foco voltaria pro botao 🕘 (foi ele que abriu) —
        # devolve pro campo de digitar pra seguir a conversa retomada
        [void]$InputBox.Focus()
    } catch { Log "historico-ui: $_" }
}

# ---------- drain timer ----------
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(80)
$timer.Add_Tick({
    $m = $null
    while ($queue.TryDequeue([ref]$m)) {
        switch ($m.Type) {
            'delta'   { $script:curAnswer += $m.Text; Update-LiveAnswer }
            'status'  { $StatusText.Text = $m.Text; if ($m.Text -match '🔍|🌐|📄|↗|⚙|❓|🧭|🤖|⚠|🧹|pass:') { Log ('tool: ' + $m.Text) } }
            'sources' { Show-Sources $m.Text }
            'plan' {
                try { $c = $m.Text | ConvertFrom-Json } catch { $c = $null; Log ("plan-parse ERRO: " + $_.Exception.Message + " | payload: " + $m.Text) }
                if ($c -and $c.hide) { Hide-PlanBar }
                elseif ($c) { Show-PlanBar $c }
            }
            'confirm' {
                try { $c = $m.Text | ConvertFrom-Json } catch { $c = $null; Log ("confirm-parse ERRO: " + $_.Exception.Message + " | payload: " + $m.Text) }
                if ($c -and $c.hide) { $ConfirmBar.Visibility = 'Collapsed' }
                elseif ($c) {
                  try {
                    $script:confirmId = [int]$c.id
                    $ConfirmTitle.Text = [string]$c.title
                    $ConfirmDetail.Text = [string]$c.detail
                    # diff vermelho/verde (file_edit): linhas "- " / "+ " em mono
                    $ConfirmDiff.Children.Clear()
                    if ($c.diff) {
                        $ConfirmDiffScroll.Visibility = 'Visible'
                        foreach ($d in @($c.diff)) {
                            $tb = [System.Windows.Controls.TextBlock]::new()
                            $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas')
                            $tb.FontSize = (FSz 11); $tb.TextWrapping = 'NoWrap'
                            $s = [string]$d.s
                            $tb.Text = $s
                            if ($s.StartsWith('+')) { $tb.Foreground = '#7CC98A' }
                            elseif ($s.StartsWith('-')) { $tb.Foreground = '#E5716E' }
                            else { $tb.Foreground = $T.dim }
                            $null = $ConfirmDiff.Children.Add($tb)
                        }
                    } else { $ConfirmDiffScroll.Visibility = 'Collapsed' }
                    # "✔ Sempre" so' faz sentido p/ acao com regra gravavel (tool+subject);
                    # compactacao (v3.13) vira "🧹 Auto-compactar" (compacta + liga autocompact)
                    $script:confirmAuto = [bool]$c.auto
                    if ($c.auto) {
                        $ConfirmAlwaysBtn.Visibility = 'Visible'
                        $ConfirmAlwaysBtn.Content = '🧹 Auto-compactar'
                        $ConfirmAlwaysBtn.ToolTip = 'compactar automaticamente daqui pra frente, sem perguntar'
                    } else {
                        $ConfirmAlwaysBtn.Content = '✔ Sempre'
                        $ConfirmAlwaysBtn.ToolTip = 'aprovar e sempre permitir esta ação (grava regra no zquick.json)'
                        if ($c.tool) { $ConfirmAlwaysBtn.Visibility = 'Visible' } else { $ConfirmAlwaysBtn.Visibility = 'Collapsed' }
                    }
                    $ConfirmBar.Visibility = 'Visible'
                    Log ('confirma: ' + $c.title)
                  } catch { Log ("confirm-ui ERRO: " + $_.Exception.Message + " @ " + $_.ScriptStackTrace) }
                }
            }
            'allow' {
                # regra de "sempre permitir" aprovada na UI -> persiste no zquick.json
                try {
                    $r = $m.Text | ConvertFrom-Json
                    $a = @{ runPs = @(); paths = @() }
                    if ($cfg.allow) { $a = @{ runPs = @($cfg.allow.runPs); paths = @($cfg.allow.paths) } }
                    if ([string]$r.tool -eq 'run_ps') {
                        if ($a.runPs -notcontains [string]$r.subject) { $a.runPs += [string]$r.subject }
                    } else {
                        $pp = ([string]$r.subject).TrimEnd('\').ToLowerInvariant()
                        if ($a.paths -notcontains $pp) { $a.paths += $pp }
                    }
                    if ($a.runPs.Count -gt 50) { $a.runPs = @($a.runPs | Select-Object -Last 50) }
                    if ($a.paths.Count -gt 50) { $a.paths = @($a.paths | Select-Object -Last 50) }
                    $cfg.allow = $a; Save-Config
                    Log ('sempre permitir: ' + $r.tool + ' = ' + $r.subject)
                } catch { Log "allow: $_" }
            }
            'ask' {
                try { $c = $m.Text | ConvertFrom-Json } catch { $c = $null; Log ("ask-parse ERRO: " + $_.Exception.Message + " | payload: " + $m.Text) }
                if ($c -and $c.hide) { Hide-AskBar }
                elseif ($c) { Show-AskBar $c }
            }
            'stopped' { $script:stopped = $true }
            'done'    { Finish-Turn }
            'error'   { Log ("engine: " + $m.Text); $script:curAnswer += [Environment]::NewLine + "⚠ " + $m.Text; Update-LiveAnswer; Finish-Turn }
            'note'    { $StatusText.Text = $m.Text; Log ("note: " + $m.Text) }
        }
        $m = $null
    }
})

# ---------- janela: mostrar/ocultar/centro ----------
function Center-Window {
    try {
        $sp = [System.Windows.Forms.Cursor]::Position
        $wa = [System.Windows.Forms.Screen]::FromPoint($sp).WorkingArea
        $src = [System.Windows.PresentationSource]::FromVisual($window)
        $dip = if ($src) { 1.0 / $src.CompositionTarget.TransformToDevice.M11 } else { 1.0 }
        $window.Left = [Math]::Round($wa.Left * $dip + ($wa.Width * $dip - $window.Width) / 2)
        $window.Top = [Math]::Round($wa.Top * $dip + ($wa.Height * $dip - $window.Height) / 2)
    } catch { Log "center: $_" }
}

function Reset-Conversation {
    # janela reaberta = conversa NOVA (as anteriores ficam no historico 🕘; retome por la).
    # Se um stream estiver rolando, mantem — so nao zera no meio da resposta.
    if ($script:busy) { return }
    if ($script:engine) { $script:engine.Reset() }
    $script:stopped = $false
    $script:queued = $null
    $script:curAnswer = ''; $script:lastAnswer = ''; $script:pendSources = @(); $script:livePanel = $null
    $script:convFile = $null; $script:convResumed = $false
    $AnswerDoc.Blocks.Clear()
    $ConfirmBar.Visibility = 'Collapsed'
    $PlanBar.Visibility = 'Collapsed'
    if ($AskBar.Visibility -eq 'Visible') { $script:askCard = $null; Hide-AskBar }
    Add-Placeholder
    Log 'janela reaberta: conversa nova'
}

function Toggle-Window {
    try {
        Log 'toggle'
        if ($window.IsVisible) { $window.Hide() }
        else {
            if ($cfg.window.center) { Center-Window }
            $window.Show(); [void]$window.Activate()
            [void]$InputBox.Focus()
            Reset-Conversation
        }
    } catch { Log "toggle erro: $_" }   # nunca deixar vazar p/ dispatcher (dialogo JIT)
}

# ---------- hotkey global ----------
Add-Type -Namespace Native -Name Hotkey -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
'@
function Get-HotkeySpec([string]$s) {
    $mods = 0; $key = $null
    foreach ($p in ($s -split '\+')) {
        $t = $p.Trim().ToLower()
        switch ($t) {
            'win'   { $mods += 8 }
            'ctrl'  { $mods += 2 }
            'shift' { $mods += 4 }
            'alt'   { $mods += 1 }
            default { $key = $t }
        }
    }
    if (-not $key -or $key.Length -lt 1) { $key = 'c' }
    [pscustomobject]@{ Mods = [uint32]$mods; Vk = [uint32][int][char]::ToUpper($key[0]) }
}

$window.Add_SourceInitialized({
    $src = [System.Windows.Interop.HwndSource]::FromVisual($window)
    $src.AddHook({ param($hwnd, $msg, $w, $l, [ref]$handled)
        if ($msg -eq 0x0312) {
            if ($w -eq [IntPtr]1 -or $w -eq [IntPtr]2) { $null = Toggle-Window; $handled.Value = $true }
        }
        return [IntPtr]::Zero
    })
    $spec = Get-HotkeySpec ([string]$cfg.hotkey)
    $ok = [Native.Hotkey]::RegisterHotKey($src.Handle, 1, $spec.Mods, $spec.Vk)
    Log ("hotkey '{0}' -> {1}" -f $cfg.hotkey, $ok)
    # combinacoes com Win: o shell costuma ser dono (RegisterHotKey falha) — a saida
    # e o hook LL, que porem pode ser derrubado pelo Windows/cego com janela admin.
    # Por isso o padrao do config e alt+q; o hook so arma p/ atalho win-based.
    if (-not $ok -and ([string]$cfg.hotkey -match '(^|\+)win(\+|$)')) {
        $hookOk = [ZQuick.Hook]::Install([string]$cfg.hotkey, { Toggle-Window })
        Log ("LL hook '{0}' -> {1}" -f $cfg.hotkey, $hookOk)
        $ok = $hookOk
    }
    if (-not $ok) {
        $spec2 = Get-HotkeySpec 'alt+q'
        $ok2 = [Native.Hotkey]::RegisterHotKey($src.Handle, 2, $spec2.Mods, $spec2.Vk)
        Log ("fallback alt+q -> {0}" -f $ok2)
        $StatusText.Text = 'atalho ' + $cfg.hotkey + ' ocupado — usando Alt+Q'
    }
})

# ---------- eventos UI ----------
$SendBtn.Add_Click({
    if ($script:busy) {
        if ($script:engine) { $script:engine.Cancel() }
        $StatusText.Text = 'interrompendo…'
        Log 'parar: cancel solicitado'
    } else { Send-Current }
})
# Onda 6: botões da moldura própria — tudo SEM SAIR do app (bandeja)
$CloseBtn.Add_Click({ Log 'chrome: ocultado (✕)'; $window.Hide() })
$MinBtn.Add_Click({ Log 'chrome: ocultado (—)'; $window.Hide() })
$MaxBtn.Add_Click({
    if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal'; Log 'chrome: restaurado' }
    else { $window.WindowState = 'Maximized'; Log 'chrome: maximizado' }
})
$SettingsBtn.Add_Click({ Show-Settings })
$NewBtn.Add_Click({ New-Conversation })
$HistBtn.Add_Click({ Show-History })
$ConfirmYes.Add_Click({
    if ($script:engine) { $script:engine.Confirm([int]$script:confirmId, $true) }
    $ConfirmBar.Visibility = 'Collapsed'; $StatusText.Text = 'executando…'
})
$ConfirmNo.Add_Click({
    if ($script:engine) { $script:engine.Confirm([int]$script:confirmId, $false) }
    $ConfirmBar.Visibility = 'Collapsed'; $StatusText.Text = 'ação negada'
})
$ConfirmAlwaysBtn.Add_Click({
    if ($script:confirmAuto) {
        # v3.13: "🧹 Auto-compactar" — aprova a compactacao E liga autocompact permanente
        if ($script:engine) { $script:engine.ConfirmAuto([int]$script:confirmId) }
        $cfg.autoCompact = $true; Save-Config
        $StatusText.Text = '🧹 autocompact LIGADO — gravado no zquick.json'
    } else {
        if ($script:engine) { $script:engine.ConfirmAlways([int]$script:confirmId) }
        $StatusText.Text = 'sempre permitido — gravado no zquick.json'
    }
    $ConfirmBar.Visibility = 'Collapsed'
})

# ---------- modo plano (#13): aprovacao em lote (uma vez, acoes seguintes sem confirm) ----------
$script:planId = 0

function Show-PlanBar($c) {
    $script:planId = [int]$c.id
    $PlanTitle.Text = [string]$c.title
    $PlanSteps.Children.Clear()
    $i = 0
    foreach ($s in @($c.steps)) {
        $i++
        $tb = [System.Windows.Controls.TextBlock]::new()
        $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas')
        $tb.FontSize = (FSz 11); $tb.TextWrapping = 'Wrap'
        $tb.Text = "$i. $([string]$s)"
        $tb.Foreground = $(if ($i % 2 -eq 0) { $T.status } else { $T.fg })
        $null = $PlanSteps.Children.Add($tb)
    }
    $PlanBar.Visibility = 'Visible'
    if (-not $window.IsVisible) { if ($cfg.window.center) { Center-Window }; $window.Show() }
    [void]$window.Activate()
    [void]$PlanYes.Focus()
    # ecoa o plano na conversa (card proprio)
    $card = New-Card '🧭 Plano proposto'
    Add-MdLines $card.Blocks ('**' + [string]$c.title + '**') $false
    foreach ($s in @($c.steps)) {
        $p = [System.Windows.Documents.Paragraph]::new(); $p.Margin = '0,1'
        $b = [System.Windows.Documents.Run]::new('• '); $b.Foreground = $T.dim
        $null = $p.Inlines.Add($b)
        $null = $p.Inlines.Add([System.Windows.Documents.Run]::new([string]$s))
        $null = $card.Blocks.Add($p)
    }
    $AnswerDoc.Blocks.Add($card.Section) | Out-Null
    Scroll-AnswerToEnd
    Log ('plano: ' + [string]$c.title + ' (' + @($c.steps).Count + ' passos)')
}

function Hide-PlanBar { $PlanBar.Visibility = 'Collapsed' }

$PlanYes.Add_Click({
    if ($script:engine) { $script:engine.PlanDecide([int]$script:planId, $true) }
    Hide-PlanBar; $StatusText.Text = '✅ plano aprovado — executando sem confirmações…'
    Log 'plano: aprovado'
})
$PlanNo.Add_Click({
    if ($script:engine) { $script:engine.PlanDecide([int]$script:planId, $false) }
    Hide-PlanBar; $StatusText.Text = 'plano rejeitado'
    Log 'plano: rejeitado'
})

# ---------- ask_user: painel de decisao multipla-escolha (estilo Claude Code) ----------
$script:askId = 0; $script:askState = $null; $script:askCard = $null

function Hide-AskBar {
    $AskBar.Visibility = 'Collapsed'
    $AskPanel.Children.Clear()
    $script:askState = $null
}

function Get-AskPretty([string]$answer) {
    if ([string]::IsNullOrEmpty($answer)) { return '✕ cancelada' }
    if ($answer.StartsWith('[')) {   # multi-pergunta: array ["ESCOLHA: x | y","TEXTO: t",""]
        try {
            $arr = @($answer | ConvertFrom-Json)
            $outs = @()
            foreach ($a in $arr) {
                $s = [string]$a
                if ($s.StartsWith('ESCOLHA:')) { $outs += '✅ ' + (($s.Substring(8).Trim()) -replace ' \| ', ' + ') }
                elseif ($s.StartsWith('TEXTO:')) { $outs += '✎ ' + $s.Substring(6).Trim() }
                else { $outs += '—' }
            }
            return ($outs -join ' · ')
        } catch { return $answer }
    }
    if ($answer.StartsWith('TEXTO:')) { return '✎ ' + $answer.Substring(6).Trim() }
    return '✅ ' + (($answer -replace '^ESCOLHA:\s*', '') -replace ' \| ', ' + ')
}

function Send-AskAnswer([string]$answer) {
    # $null/$vazio = cancelado (o engine trata como "nao respondeu")
    if ($script:engine) { $script:engine.AnswerAsk([int]$script:askId, $answer) }
    if ($script:askCard) {
        try {
            $p = [System.Windows.Documents.Paragraph]::new(); $p.Margin = '0,4,0,0'
            $r = [System.Windows.Documents.Run]::new('Você: ' + (Get-AskPretty $answer))
            $r.Foreground = $T.q; $r.FontWeight = 'SemiBold'
            $null = $p.Inlines.Add($r)
            $script:askCard.Blocks.Add($p) | Out-Null
            Log ('ask resposta: ' + (Get-AskPretty $answer))
        } catch { Log "ask-eco: $_" }
    }
    $script:askCard = $null
    Hide-AskBar
    $StatusText.Text = '…'
}

function Show-AskBar($c) {
    $script:askId = [int]$c.id
    # estado do painel: hashtable unica — closures de botao capturam POR VALOR
    # (referencia compartilhada); $script: dentro de GetNewClosure resolve no
    # escopo do modulo da closure, NAO no do script — nao usar la.
    $qsArr = @($c.qs)
    $qs = @()
    foreach ($q in $qsArr) { $qs += @{ multi = [bool]$q.multi; sel = [System.Collections.ArrayList]::new(); freeBox = $null } }
    $st = @{ qs = $qs }
    $script:askState = $st
    $single = ($qs.Count -eq 1)
    $hdr = if ($single) { [string]$qsArr[0].h } else { "$($qs.Count) PERGUNTAS" }
    if (-not $hdr) { $hdr = 'decisão' }
    $AskHeader.Text = $hdr.ToUpperInvariant()
    $AskTitle.Text = $(if ($single) { [string]$qsArr[0].q } else { 'Responda as perguntas e confirme — ou use ✎ para texto livre.' })
    $AskPanel.Children.Clear()
    $needOk = -not $single
    $qi = 0
    foreach ($q in $qsArr) {
        $qi++
        $qst = $st.qs[$qi - 1]
        if ($qst.multi) { $needOk = $true }
        $immediate = ($single -and -not $qst.multi)   # 1 pergunta simples: clique envia direto (UX antiga)
        $qsp = [System.Windows.Controls.StackPanel]::new(); $qsp.Margin = '0,0,0,6'
        if (-not $single) {
            $ht = [System.Windows.Controls.TextBlock]::new()
            $ht.Text = "$qi · " + ([string]$q.h).ToUpperInvariant()
            $ht.Foreground = $T.status; $ht.FontSize = (FSz 10); $ht.FontWeight = 'SemiBold'; $ht.Margin = '0,4,0,2'
            $null = $qsp.Children.Add($ht)
            $qt = [System.Windows.Controls.TextBlock]::new()
            $qt.Text = [string]$q.q; $qt.Foreground = $T.fg; $qt.TextWrapping = 'Wrap'; $qt.FontSize = (FSz 12); $qt.FontWeight = 'SemiBold'
            $null = $qsp.Children.Add($qt)
        }
        $oi = 0
        foreach ($o in @($q.opts)) {
            $oi++
            $lbl = [string]$o.label; $desc = [string]$o.desc; $prev = [string]$o.preview
            $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'
            $btn = [System.Windows.Controls.Button]::new()
            [System.Windows.Automation.AutomationProperties]::SetAutomationId($btn, $(if ($single) { "AskOpt$oi" } else { "AskQ${qi}Opt$oi" }))
            $btn.Tag = $lbl
            $btn.HorizontalContentAlignment = 'Left'
            $btn.Padding = '10,6'; $btn.Margin = '0,2'
            $sp = [System.Windows.Controls.StackPanel]::new()
            $t1 = [System.Windows.Controls.TextBlock]::new(); $t1.Text = $lbl; $t1.FontWeight = 'SemiBold'; $t1.FontSize = (FSz 12)
            $null = $sp.Children.Add($t1)
            if ($desc) {
                $t2 = [System.Windows.Controls.TextBlock]::new(); $t2.Text = $desc
                $t2.Foreground = $T.status; $t2.FontSize = (FSz 11); $t2.TextWrapping = 'Wrap'
                $null = $sp.Children.Add($t2)
            }
            $btn.Content = $sp
            $btn.Add_Click({
                param($s, $e)
                $lb = [string]$s.Tag
                if ($immediate) {
                    Send-AskAnswer ('ESCOLHA: ' + $lb)
                } else {
                    if ($qst.sel -contains $lb) {
                        $null = $qst.sel.Remove($lb)
                        $t1.Text = $lb
                    } else {
                        $null = $qst.sel.Add($lb)
                        $t1.Text = [string][char]0x2714 + ' ' + $lb
                    }
                    $AskOkBtn.IsEnabled = $true
                }
            }.GetNewClosure())
            $row.Children.Add($btn) | Out-Null
            if ($prev) {
                # preview mono (codigo/mockup/config) — botao 👁 expande/colapsa
                $pvBtn = [System.Windows.Controls.Button]::new()
                $pvBtn.Content = '👁'; $pvBtn.Padding = '4,2'; $pvBtn.Margin = '4,0,0,2'; $pvBtn.FontSize = (FSz 11)
                $pvTb = [System.Windows.Controls.TextBlock]::new()
                $pvTb.Text = $prev
                $pvTb.FontFamily = [System.Windows.Media.FontFamily]::new('Cascadia Mono, Consolas')
                $pvTb.FontSize = (FSz 11); $pvTb.TextWrapping = 'Wrap'; $pvTb.Foreground = $T.code
                $pvBox = [System.Windows.Controls.Border]::new()
                $pvBox.Background = $T.input; $pvBox.BorderBrush = $T.border; $pvBox.BorderThickness = '1'
                $pvBox.CornerRadius = '4'; $pvBox.Padding = '6,4'; $pvBox.Margin = '0,2,0,4'
                $pvBox.MaxHeight = 150; $pvBox.Visibility = 'Collapsed'
                $pvBox.Child = $pvTb
                $pvBtn.Add_Click({
                    param($s2, $e2)
                    $pvBox.Visibility = $(if ($pvBox.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' })
                    $e2.Handled = $true
                }.GetNewClosure())
                $row.Children.Add($pvBtn) | Out-Null
                $qsp.Children.Add($row) | Out-Null
                $qsp.Children.Add($pvBox) | Out-Null
            } else {
                $qsp.Children.Add($row) | Out-Null
            }
        }
        # texto livre desta pergunta (aparece com o ✎)
        $fb = [System.Windows.Controls.TextBox]::new()
        $fb.Height = 28; $fb.Margin = '0,4,0,0'; $fb.FontSize = (FSz 12)
        $fb.Background = $T.input; $fb.Foreground = $T.fg; $fb.BorderBrush = $T.border
        $fb.CaretBrush = $T.fg; $fb.Padding = '6,4'; $fb.Visibility = 'Collapsed'
        [System.Windows.Automation.AutomationProperties]::SetAutomationId($fb, "AskQ${qi}Free")
        $qst.freeBox = $fb
        $fb.Add_KeyDown({
            param($s3, $e3)
            if ($e3.Key -eq 'Enter' -and $s3.Text.Trim()) {
                $e3.Handled = $true
                if ($single) { Send-AskAnswer ('TEXTO: ' + $s3.Text.Trim()) }
                else { $AskOkBtn.IsEnabled = $true }
            }
        }.GetNewClosure())
        $qsp.Children.Add($fb) | Out-Null
        $AskPanel.Children.Add($qsp) | Out-Null
    }
    $AskOkBtn.Visibility = $(if ($needOk) { 'Visible' } else { 'Collapsed' })
    $AskOkBtn.IsEnabled = $true
    $AskFreeRow.Visibility = 'Collapsed'; $AskInput.Text = ''
    $AskBar.Visibility = 'Visible'
    # pergunta exige o usuario: janela oculta precisa aparecer
    if (-not $window.IsVisible) { if ($cfg.window.center) { Center-Window }; $window.Show() }
    [void]$window.Activate()
    try { [void]@($AskPanel.Children)[0].Focus() } catch {}
    # ecoa as perguntas na conversa (fica no card junto da resposta dada)
    $card = New-Card ('❓ ' + $hdr)
    foreach ($q in $qsArr) {
        Add-MdLines $card.Blocks ([string]$q.q) $true
        foreach ($o in @($q.opts)) {
            $p = [System.Windows.Documents.Paragraph]::new(); $p.Margin = '0,1'
            $b = [System.Windows.Documents.Run]::new('• '); $b.Foreground = $T.dim
            $null = $p.Inlines.Add($b)
            $l = [System.Windows.Documents.Run]::new([string]$o.label); $l.FontWeight = 'SemiBold'
            $null = $p.Inlines.Add($l)
            if ([string]$o.desc) {
                $d = [System.Windows.Documents.Run]::new(' — ' + [string]$o.desc); $d.Foreground = $T.status
                $null = $p.Inlines.Add($d)
            }
            $null = $card.Blocks.Add($p)
        }
    }
    $AnswerDoc.Blocks.Add($card.Section) | Out-Null
    Scroll-AnswerToEnd
    $script:askCard = $card.Section
    Log ('ask: ' + $(if ($single) { [string]$qsArr[0].q } else { $qs.Count.ToString() + ' perguntas' }) + $(if ($needOk) { ' [confirma]' } else { '' }))
}

$AskOkBtn.Add_Click({
    if (-not $script:askState) { return }
    # coleta por pergunta: texto livre > seleção > vazio ("")
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($q in @($script:askState.qs)) {
        $ft = ''
        if ($q.freeBox) { $ft = ([string]$q.freeBox.Text).Trim() }
        if ($ft) { $parts.Add('TEXTO: ' + $ft) }
        elseif (@($q.sel).Count -gt 0) { $parts.Add('ESCOLHA: ' + (@($q.sel) -join ' | ')) }
        else { $parts.Add('') }
    }
    if ($parts.Count -eq 1) { Send-AskAnswer ([string]$parts[0]) }
    else { Send-AskAnswer ('[' + (($parts | ForEach-Object { ConvertTo-Json -InputObject $_ }) -join ',') + ']') }
})
$AskOtherBtn.Add_Click({
    if (-not $script:askState) { return }
    foreach ($q in @($script:askState.qs)) { if ($q.freeBox) { $q.freeBox.Visibility = 'Visible' } }
    $f = @($script:askState.qs | Where-Object { $_.freeBox })[0]
    if ($f) { [void]$f.freeBox.Focus() }
})
$AskCancelBtn.Add_Click({ Log 'ask: cancelada (botão)'; Send-AskAnswer $null })

function Update-ModelBox {
    $p = Get-ActiveProfile
    $items = @()
    foreach ($m in @($p.models)) { $items += $(if ([string]$m -eq 'auto') { 'auto (rápida⇄forte)' } else { [string]$m }) }
    if ($items.Count -eq 0) { $items = @('auto (rápida⇄forte)') }
    $ModelBox.ItemsSource = $items
    $cur = [string]$cfg.model; if (-not $cur) { $cur = 'auto' }
    $sel = if ($cur -eq 'auto') { 'auto (rápida⇄forte)' } else { $cur }
    if ($items -notcontains $sel) {
        # pode estar guardado com a estrela de recomendado — casa pelo id limpo
        $st = @($items | Where-Object { (Clean-ModelId $_) -eq $cur })
        if ($st.Count) { $sel = $st[0] } else { $sel = $items[0] }
    }
    $ModelBox.SelectedItem = $sel
    $script:modelLabel = $sel
    Update-CtxMeter
}
$ModelBox.Add_SelectionChanged({
    $sel = [string]$ModelBox.SelectedItem
    $m = if ($sel -eq 'auto (rápida⇄forte)') { 'auto' } else { (Clean-ModelId $sel) }
    $cfg.model = $m; Save-Config
    if ($null -ne $script:engine) { $script:engine.SetModel($m) }
    $script:modelLabel = $sel
    Update-CtxMeter
    $StatusText.Text = "modelo: $sel"
})

function Update-ProfileBox {
    $labels = @()
    foreach ($n in (Get-ProfileNames)) {
        $p = $cfg.profiles.$n
        $labels += $(if ($p.label) { [string]$p.label } else { $n })
    }
    $ProfileBox.ItemsSource = $labels
    $pNames = @(Get-ProfileNames)
    $i = [array]::IndexOf($pNames, [string]$cfg.profile)
    if ($i -lt 0) { $i = 0 }
    $ProfileBox.SelectedIndex = $i
}
$ProfileBox.Add_SelectionChanged({
    if ($ProfileBox.SelectedItem -eq $null) { return }
    $pNames = @(Get-ProfileNames)
    $i = $ProfileBox.SelectedIndex
    if ($i -lt 0 -or $i -ge $pNames.Count) { return }
    $n = [string]$pNames[$i]
    if ($n -eq [string]$cfg.profile -and $null -ne $script:engine) { return }
    $cfg.profile = $n; Save-Config
    if ($null -ne $script:engine) { $script:engine.Reset(); try { $script:engine.ShutdownMcp() } catch {} }
    try {
        $script:engine = New-EngineFromProfile
        New-Conversation
        Update-ModelBox
        $StatusText.Text = "perfil: $n"
    } catch {
        $StatusText.Text = "erro no perfil: $_"
        Log "profile: $_"
    }
})

$InputBox.Add_PreviewKeyDown({
    param($s, $e)
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    if ($e.Key -eq 'Enter' -and -not ($mods -band [System.Windows.Input.ModifierKeys]::Shift)) {
        $e.Handled = $true; Send-Current
    }
    elseif ($e.Key -eq 'V' -and ($mods -band [System.Windows.Input.ModifierKeys]::Control)) {
        if ([System.Windows.Clipboard]::ContainsImage()) { $e.Handled = $true; Add-ClipboardImage }
        elseif ([System.Windows.Clipboard]::ContainsFileDropList()) {
            $any = $false
            foreach ($f in [System.Windows.Clipboard]::GetFileDropList()) {
                Add-AnyFile ([string]$f); $any = $true
            }
            if ($any) { $e.Handled = $true }
        }
    }
    elseif ($e.Key -eq 'N' -and ($mods -band [System.Windows.Input.ModifierKeys]::Control)) {
        $e.Handled = $true; New-Conversation
    }
})

# ---------- @menção a arquivos (#11): '@' no comeco de palavra abre dialogo ----------
function Open-MentionDialog {
    # retorna $true quando um arquivo foi escolhido (quem chamou engole o '@');
    # cancelado retorna $false e o '@' cai no campo como texto comum
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title = 'Mencionar arquivo (@)'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('UserProfile')
    $dlg.Filter = 'Todos os arquivos|*.*'
    try { $dlg.Owner = $window } catch {}   # WPF .NET Core (pwsh7) nao tem Owner setavel — sem dono, segue modal na thread (13/10)
    if ($dlg.ShowDialog()) {
        $p = $dlg.FileName
        $ins = if ($p -match '\s') { '"' + $p + '"' } else { $p }
        $pos2 = [Math]::Max(0, $InputBox.CaretIndex)
        $InputBox.Text = $InputBox.Text.Insert($pos2, $ins)
        $InputBox.CaretIndex = $pos2 + $ins.Length
        [void]$InputBox.Focus()
        Log ('menção: ' + $p)
        return $true
    }
    return $false
}

$InputBox.Add_PreviewTextInput({
    param($s, $e)
    if ($e.Text -ne '@') { return }
    # so' no comeco de palavra: inicio do campo, ou depois de espaco/[/( —
    # email, redes (@user) e texto no meio nao abrem o dialogo
    $pos = [Math]::Max(0, $InputBox.CaretIndex)
    $before = ''
    if ($pos -gt 0 -and $pos -le $InputBox.Text.Length) { $before = $InputBox.Text.Substring($pos - 1, 1) }
    if ($before -ne '' -and $before -notmatch '[\s\[(]') { return }
    if (Open-MentionDialog) { $e.Handled = $true }   # o '@' em si nao entra
})

$window.AllowDrop = $true
$window.Add_PreviewDragOver({ param($s, $e) $e.Effects = [System.Windows.DragDropEffects]::Copy; $e.Handled = $true })
$window.Add_Drop({
    param($s, $e)
    try {
        if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            foreach ($f in [string[]]$e.Data.GetData([System.Windows.DataFormats]::FileDrop)) {
                Add-AnyFile ([string]$f)
            }
        } elseif ($e.Data.GetDataPresent([System.Windows.DataFormats]::Bitmap)) {
            $o = $e.Data.GetData([System.Windows.DataFormats]::Bitmap)
            if ($o -is [System.Windows.Media.Imaging.BitmapSource]) { Add-ImageAttachment $o }
        }
    } catch { Log "drop: $_" }
})

# Esc = FECHAR a conversa: zera como o botao Nova (engine + cartoes + anexos; rascunho fica)
# e esconde a janela. Alt+Q continua sendo so' mostrar/ocultar.
# Excecao: com pergunta aberta, Esc so' cancela a pergunta (o modelo segue).
$window.Add_PreviewKeyUp({ param($s, $e) if ($e.Key -eq 'Escape') {
    if ($PlanBar.Visibility -eq 'Visible') { Log 'esc: plano rejeitado'; if ($script:engine) { $script:engine.PlanDecide([int]$script:planId, $false) }; Hide-PlanBar; $StatusText.Text = 'plano rejeitado' }
    elseif ($AskBar.Visibility -eq 'Visible') { Log 'esc: pergunta cancelada'; Send-AskAnswer $null }
    else { Log 'esc: conversa fechada'; New-Conversation; $window.Hide() }
    $e.Handled = $true
} })
if ($cfg.hideOnBlur) { $window.Add_Deactivated({ $window.Hide() }) }

# X nativo / Alt+F4: janela WPF fechada nao pode ser reexibida (Show() lancaria
# InvalidOperationException no proximo clique no tray). App de bandeja so' esconde;
# sair de verdade e' pelo menu do tray, que marca $script:exiting antes do Shutdown.
$window.Add_Closing({ param($s, $e)
    if (-not $script:exiting) {
        Log 'X/Alt+F4: ocultando (tray) em vez de fechar'
        $e.Cancel = $true
        $s.Hide()
    }
})

# ---------- tray icon ----------
$bmp = [System.Drawing.Bitmap]::new(16, 16)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)
$lgBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Rectangle]::new(0, 0, 16, 16), (HexTo-DrawColor $T.trayA), (HexTo-DrawColor $T.trayB), [single]45)
$g.FillRectangle($lgBrush, 0, 0, 16, 16)
$lgBrush.Dispose()
$wBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
$g.DrawString('Z', [System.Drawing.Font]::new('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold), $wBrush, [single]3, [single]1)
$wBrush.Dispose()
$g.Dispose()
$hIcon = $bmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hIcon)

$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$miShow = [System.Windows.Forms.ToolStripMenuItem]::new('Mostrar')
$miShow.Add_Click({ Toggle-Window })
$miExit = [System.Windows.Forms.ToolStripMenuItem]::new('Sair')
$miExit.Add_Click({
    $script:exiting = $true
    try { if ($script:engine) { $script:engine.ShutdownMcp() } } catch {}   # mata servidores MCP filhos
    try { $notify.Visible = $false; $notify.Dispose() } catch {}
    [System.Windows.Application]::Current.Shutdown()
})
$menu.Items.AddRange([System.Windows.Forms.ToolStripMenuItem[]]@($miShow, $miExit))

$notify = [System.Windows.Forms.NotifyIcon]::new()
$notify.Icon = $icon; $notify.Text = 'ZQuick'
$notify.ContextMenuStrip = $menu; $notify.Visible = $true
$notify.Add_DoubleClick({ Toggle-Window })

# ---------- app ----------
Add-Placeholder
Update-ProfileBox
Update-ModelBox
$timer.Start()

$app = [System.Windows.Application]::new()
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

if ($Hidden) {
    $window.Opacity = 0
    $null = $window.Show()   # cria handle p/ hotkey…
    $window.Hide()
    $window.Opacity = $script:baseOpacity
    [void]$app.Run()
} else {
    Center-Window
    [void]$InputBox.Focus()
    [void]$app.Run($window)
}
} catch {
    Log "FATAL: $_"
    Log ($_.ScriptStackTrace -join "`n")
    try {
        [System.Windows.MessageBox]::Show("ZQuick falhou ao iniciar: $_`n`nDetalhes em $env:TEMP\zquick.log", 'ZQuick') | Out-Null
    } catch {}
    throw
}
