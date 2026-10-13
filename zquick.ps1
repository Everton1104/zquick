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
function Log($s) { try { Add-Content -Path $script:LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $s) } catch {} }

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
    maxTokens     = 2048
    searchEngine  = 'bing'
    hideOnBlur    = $false
    systemPrompt  = $null
    windowOpacity = 1.0
    theme         = $null
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
        foreach ($k in @('profile','model','hotkey','maxTokens','searchEngine','hideOnBlur','systemPrompt','windowOpacity')) {
            if ($null -ne $j.$k) { $cfg[$k] = $j.$k }
        }
        if ($j.theme) { $cfg.theme = $j.theme }
        if ($j.profiles) { $cfg.profiles = $j.profiles }
    } catch { Log "config invalido, usando defaults: $_" }
}
Reload-Config
# ---------- tema (cores) — defaults = visual ZQuick escuro; secao "theme" do json sobrescreve ----------
$T = @{
    bg     = '#202024'; card = '#26262B'; panel = '#2A2A30'; input = '#16161A'; border = '#3A3A44'
    fg     = '#E8E8EC'; dim  = '#6E6E7A'; status = '#9A9AA5'
    q      = '#C9C2FF'   # pergunta do usuario
    accent = '#8B9CF6'   # links
    accent2 = '#8B7CF6'  # cursor/streaming
    code   = '#A9DCFC'; trayA = '#8B7CF6'; trayB = '#6358C8'
}
if ($cfg.theme) {
    foreach ($k in @($cfg.theme.PSObject.Properties.Name)) { if ($T.ContainsKey($k)) { $T[$k] = [string]$cfg.theme.$k } }
}
# aplica cores do tema sobre os literais dos XAML (janela + dialogos) antes do parse
function Theme-Xaml([string]$x) {
    foreach ($pair in @(
        @('#202024', $T.bg), @('#2A2A30', $T.panel), @('#16161A', $T.input), @('#3A3A44', $T.border),
        @('#E8E8EC', $T.fg), @('#9A9AA5', $T.status), @('#6E6E7A', $T.dim)
    )) { $x = $x.Replace($pair[0], $pair[1]) }
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
            searchEngine = $cfg.searchEngine; hideOnBlur = $cfg.hideOnBlur
            systemPrompt = $cfg.systemPrompt; windowOpacity = $cfg.windowOpacity
            theme = $cfg.theme; profiles = $cfg.profiles
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
    public string Type;   // delta | status | sources | done | error | note
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
    int _confirmId; readonly ManualResetEventSlim _confEv = new ManualResetEventSlim(false); bool _confOk;
    int _askId; readonly ManualResetEventSlim _askEv = new ManualResetEventSlim(false); string _askAnswer;
    bool _compactAsked;   // pergunta de compactacao da conversa: 1x por conversa
    readonly int _maxTokens; readonly string _search;
    readonly List<string> _history = new List<string>();
    readonly object _sync = new object();
    volatile int _busy = 0;
    CancellationTokenSource _cts;
    Timer _prewarm;

    const string UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

    static readonly Regex RxAlgo = new Regex("<li class=\"b_algo\".*?<h2><a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a></h2>(.*?)</li>", RegexOptions.Singleline | RegexOptions.Compiled);
    static readonly Regex RxH2   = new Regex("<h2><a[^>]+href=\"(http[^\"]+)\"[^>]*>(.*?)</a>", RegexOptions.Singleline | RegexOptions.Compiled);
    static readonly Regex RxP    = new Regex("<p[^>]*>(.*?)</p>", RegexOptions.Singleline | RegexOptions.Compiled);
    static readonly Regex RxItem = new Regex("<item>.*?<title>(.*?)</title>.*?<link>(.*?)</link>.*?<description>(.*?)</description>", RegexOptions.Singleline | RegexOptions.Compiled);

    public bool Busy { get { lock (_sync) { return _busy == 1; } } }

    public Engine(string baseUrl, string apiKey, string model, string fastModel, string bigModel, int maxTokens, string searchEngine, ConcurrentQueue<UiMsg> q) {
        _base = baseUrl.TrimEnd('/'); _key = apiKey; _fast = fastModel; _big = bigModel;
        _maxTokens = maxTokens; _search = searchEngine; _q = q;
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

    public void Reset() { lock (_sync) { _history.Clear(); _compactAsked = false; try { _cts.Cancel(); } catch {} } }
    public void Cancel() { lock (_sync) { try { _cts.Cancel(); } catch {} } }

    // historico de conversa (snapshots brutos do _history) p/ salvar/retomar
    public List<string> GetHistory() { lock (_sync) { return new List<string>(_history); } }
    public void SetHistory(List<string> msgs) { lock (_sync) { if (_busy == 1) return; _history.Clear(); _compactAsked = false; if (msgs != null) _history.AddRange(msgs); } }

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

    bool GateConfirm(string title, string detail, CancellationToken ct) {
        int id;
        lock (_sync) { _confirmId++; id = _confirmId; _confOk = false; _confEv.Reset(); }
        Emit("confirm", "{\"id\":" + id + ",\"title\":" + J(title) + ",\"detail\":" + J(detail) + "}");
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

    // ---------- pergunta de multipla escolha ao usuario (decisao, estilo AskUserQuestion do Claude Code) ----------
    public void AnswerAsk(int id, string answer) {
        lock (_sync) { if (id != _askId) return; _askAnswer = answer; _askEv.Set(); }
    }

    string GateAsk(string question, string header, bool multi, List<string[]> options, CancellationToken ct) {
        int id;
        lock (_sync) { _askId++; id = _askId; _askAnswer = null; _askEv.Reset(); }
        var sb = new StringBuilder();
        sb.Append("{\"id\":").Append(id)
          .Append(",\"question\":").Append(J(question))
          .Append(",\"header\":").Append(J(string.IsNullOrEmpty(header) ? "decisão" : header))
          .Append(",\"multi\":").Append(multi ? "true" : "false")
          .Append(",\"options\":[");
        for (int i = 0; i < options.Count; i++) {
            if (i > 0) sb.Append(",");
            sb.Append("{\"label\":").Append(J(options[i][0])).Append(",\"desc\":").Append(J(options[i][1])).Append("}");
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

    string DoAskUser(Dictionary<string, object> inp, CancellationToken ct) {
        string question = H.S(inp, "question");
        string header = H.S(inp, "header");
        bool multi = false; object mv;
        if (inp != null && inp.TryGetValue("multiSelect", out mv)) multi = mv is bool && (bool)mv;
        var opts = new List<string[]>();
        object ov;
        if (inp != null && inp.TryGetValue("options", out ov) && ov is List<object>) {
            foreach (object it in (List<object>)ov) {
                var od = it as Dictionary<string, object>;
                if (od == null) continue;
                string lb = H.S(od, "label"); if (string.IsNullOrEmpty(lb)) continue;
                string de = H.S(od, "description"); if (de == null) de = "";
                opts.Add(new string[] { lb, de });
                if (opts.Count >= 4) break;
            }
        }
        if (string.IsNullOrEmpty(question)) return "ERRO: preencha 'question' (a pergunta completa, terminando em ?).";
        if (opts.Count < 2) return "ERRO: ofereça de 2 a 4 opções em 'options' (cada uma {label, description}).";
        string ans = GateAsk(question, header, multi, opts, ct);
        if (ans == null) return "O usuário cancelou ou não respondeu à pergunta. NÃO pergunte de novo: tome a decisão mais conservadora (ou nenhuma) e informe o que decidiu.";
        if (ans.StartsWith("TEXTO:")) return "O usuário respondeu com texto livre: \"" + ans.Substring(6).Trim() + "\"";
        if (ans.StartsWith("ESCOLHA:")) return "O usuário escolheu: " + ans.Substring(8).Trim().Replace(" | ", " e ") + ".";
        return "O usuário respondeu: " + ans;
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
            nh.Add("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":" + J("[RESUMO da conversa anterior, gerado automaticamente]") + "}");
            nh.Add("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":" + J(summary) + "}");
            nh.AddRange(recent);
            lock (_sync) { _history.Clear(); _history.AddRange(nh); }
            Emit("note", "conversa compactada: " + msgs.Count + " → " + nh.Count + " mensagens");
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

    string NonStreamOnce(string body, CancellationToken ct) {
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

    class Blk { public string Kind; public StringBuilder Text = new StringBuilder(); public string Id; public string Name; public StringBuilder Input = new StringBuilder(); }

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

    void Run(object arg) {
        object[] a = (object[])arg;
        string userText = (string)a[0]; List<string> imgB64 = (List<string>)a[1]; string sys = (string)a[2];
        List<string[]> txtFiles = a.Length > 3 ? (List<string[]>)a[3] : null;
        List<string[]> pdfFiles = a.Length > 4 ? (List<string[]>)a[4] : null;
        var ct = _cts.Token;
        try {
            lock (_sync) {
                _useBig = false;
                _useVision = _auto && imgB64 != null && imgB64.Count > 0;   // imagem em auto -> modelo com visao
                // anexo de TEXTO sem imagem -> modelo grande: o flash ignora o conteudo
                // inline e sai "procurando" o arquivo no disco (10x file_list, resposta
                // vazia). PDF fica no flash — document block provado la (E2E fase 4).
                if (_auto && !_useVision && txtFiles != null && txtFiles.Count > 0) _useBig = true;
            }
            // conversa crescendo: PERGUNTA se compacta (resumo) antes de bater no teto duro
            bool askCompact = false; int msgN = 0; double kb = 0;
            lock (_sync) {
                double chars = 0; foreach (string h in _history) chars += h.Length;
                if (_history.Count > 40 || chars > 300000) { _history.Clear(); _compactAsked = false; Emit("note", "contexto antigo descartado"); }
                else if (!_compactAsked && (_history.Count > 28 || chars > 150000)) {
                    _compactAsked = true; askCompact = true; msgN = _history.Count; kb = chars / 1024;
                }
            }
            if (askCompact && GateConfirm("Compactar conversa",
                string.Format("{0} mensagens • {1:0} KB. Posso resumir as trocas antigas (mantendo as últimas intactas) para a conversa continuar leve?", msgN, kb), ct))
                CompactHistory(ct);
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
            lock (_sync) {
                _history.Add("{\"role\":\"user\",\"content\":[" + ub + "]}");
                _pdfFallback = (pdfFiles != null && pdfFiles.Count > 0) ? "{\"role\":\"user\",\"content\":[" + ubNoPdf + "]}" : null;
            }

            // ----- pre-busca especulativa -----
            // Pergunta com cara de "fato atual": dispara a busca em paralelo ANTES da 1a
            // ida ao modelo e injeta os resultados no system do round 0 — o modelo pode
            // responder em 1 ida (~6s de fila) em vez de 3 (decidir->buscar->responder).
            string sys0 = sys;
            bool noImg = imgB64 == null || imgB64.Count == 0;
            if (noImg && LooksFresh(userText)) {
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

            string stop = "";
            for (int round = 0; round < 6; round++) {
                if (ct.IsCancellationRequested) { Emit("error", "Cancelado."); return; }
                string body;
                lock (_sync) { body = BuildBody(round == 0 ? sys0 : sys); }
                List<Blk> blocks;
                try { blocks = StreamOnce(body, ct, out stop); }
                catch (Exception ex) {
                    // endpoint rejeitou os document blocks de PDF -> reenvia sem (1x)
                    if (_pdfFallback != null && ex.Message.StartsWith("HTTP 400")) {
                        lock (_sync) { if (_history.Count > 0) _history[_history.Count - 1] = _pdfFallback; _pdfFallback = null; }
                        Emit("note", "PDF rejeitado pelo endpoint — reenviando sem o PDF");
                        round--; continue;
                    }
                    throw;
                }
                if (ct.IsCancellationRequested) { Emit("error", "Cancelado."); return; }
                List<string> bj = new List<string>();
                foreach (Blk b in blocks) bj.Add(BlkJson(b));
                lock (_sync) { _history.Add("{\"role\":\"assistant\",\"content\":[" + string.Join(",", bj) + "]}"); }
                if (stop != "tool_use" || ct.IsCancellationRequested) { Emit("done", ""); return; }
                // executa tools
                var resJson = new StringBuilder();
                var sources = new List<string>();
                foreach (Blk b in blocks) {
                    if (b.Kind != "tool_use") continue;
                    if (ct.IsCancellationRequested) break;
                    string outp = ""; string q = null; string u = null;
                    Dictionary<string, object> inp = MJ.Parse(b.Input.Length > 0 ? b.Input.ToString() : "{}") as Dictionary<string, object>;
                    if (inp != null) { q = H.S(inp, "query"); u = H.S(inp, "url"); }
                    if (b.Name == "file_list" || b.Name == "file_read" || b.Name == "file_write" || b.Name == "file_move" ||
                        b.Name == "file_delete" || b.Name == "note_add" || b.Name == "run_ps") {
                        Emit("status", "⚙ " + b.Name + "…");
                        outp = LocalTool(b.Name, inp, ct);
                    }
                    else if (b.Name == "web_search") { Emit("status", "\U0001F50D " + (q ?? "?")); outp = DoSearch(q, ct, sources); }
                    else if (b.Name == "fetch_page") { Emit("status", "\U0001F4C4 " + (u ?? "?")); outp = DoFetch(u, ct); }
                    else if (b.Name == "ask_user") { Emit("status", "❓ esperando sua escolha…"); outp = DoAskUser(inp, ct); }
                    else if (b.Name == "escalate") {
                        _useBig = true;
                        Emit("status", "↗ encaminhando ao " + _big + "…");
                        outp = "OK — escalated. The larger model will now answer the user directly.";
                    }
                    else outp = "unknown tool";
                    if (resJson.Length > 0) resJson.Append(",");
                    resJson.Append("{\"type\":\"tool_result\",\"tool_use_id\":").Append(J(b.Id)).Append(",\"content\":").Append(J(outp)).Append("}");
                }
                if (sources.Count > 0) Emit("sources", "[" + string.Join(",", sources) + "]");
                lock (_sync) { _history.Add("{\"role\":\"user\",\"content\":[" + resJson + "]}"); }
            }
            Emit("done", "");
        } catch (Exception ex) {
            Emit("error", ct.IsCancellationRequested ? "Cancelado." : ex.Message);
        } finally { lock (_sync) { _busy = 0; } }
    }

    string BuildBody(string sys) {
        var b = new StringBuilder();
        string vm = !_auto ? _model : (_useBig ? _big : (_useVision ? (_vision ?? _big) : _model));
        b.Append("{\"model\":\"").Append(vm)
         .Append("\",\"max_tokens\":").Append(_maxTokens)
         .Append(",\"stream\":true,\"system\":").Append(J(sys))
         .Append(",\"tools\":[")
         .Append("{\"name\":\"web_search\",\"description\":\"Search the web for current information (news, prices, scores, versions, facts that may have changed). Returns numbered results with title, URL and snippet.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"the search query, in the same language as the question\"}},\"required\":[\"query\"]}},")
         .Append("{\"name\":\"fetch_page\",\"description\":\"Fetch one web page by absolute http(s) URL and return its readable text (truncated). Use to read details of a promising search result.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"absolute http or https URL\"}},\"required\":[\"url\"]}}")
         .Append(",{\"name\":\"file_list\",\"description\":\"List files and folders of a directory on the user's Windows.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute directory path (empty = user home)\"}}}}")
         .Append(",{\"name\":\"file_read\",\"description\":\"Read a text file from the user's Windows (first 8000 chars).\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute file path\"}},\"required\":[\"path\"]}}")
         .Append(",{\"name\":\"file_write\",\"description\":\"Create or overwrite a text file (any extension). Requires the user's approval in the app window.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute file path\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}")
         .Append(",{\"name\":\"file_move\",\"description\":\"Move or RENAME a file or folder. Requires the user's approval in the app window.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"src\":{\"type\":\"string\",\"description\":\"absolute source path\"},\"dest\":{\"type\":\"string\",\"description\":\"absolute destination path (full new name)\"}},\"required\":[\"src\",\"dest\"]}}")
         .Append(",{\"name\":\"file_delete\",\"description\":\"Send a file or folder to the Recycle Bin. Requires the user's approval in the app window.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"]}}")
         .Append(",{\"name\":\"note_add\",\"description\":\"Save a markdown note to the user's notes folder (Documents/ZQuick-Notas). Runs without approval.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"content\":{\"type\":\"string\",\"description\":\"markdown body\"}},\"required\":[\"title\",\"content\"]}}")
         .Append(",{\"name\":\"run_ps\",\"description\":\"Run ANY PowerShell command on the user's Windows (open apps, system settings, processes, checks...). ALWAYS shown to the user for approval before running. Do NOT delete user files with this (use file_delete). Keep commands short and idempotent.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"PowerShell command line\"}},\"required\":[\"command\"]}}")
         .Append(",{\"name\":\"ask_user\",\"description\":\"Ask the user ONE multiple-choice question and wait for their pick. Use when the task has ambiguity or a decision the user should make (which approach, which file, scope, taste, a risky trade-off). Do NOT use it for anything you can decide yourself or verify with file_list/web_search, and never ask the same question twice. 2-4 options, each with a short label (1-5 words) and a description of what it implies; the user can always answer free text instead.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"the complete question in Portuguese, specific, ending with ?\"},\"header\":{\"type\":\"string\",\"description\":\"short chip label, max ~12 chars\"},\"multiSelect\":{\"type\":\"boolean\",\"description\":\"true = the user may pick several options\"},\"options\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"label\":{\"type\":\"string\",\"description\":\"concise option, 1-5 words\"},\"description\":{\"type\":\"string\",\"description\":\"what choosing this implies\"}},\"required\":[\"label\"]}}},\"required\":[\"question\",\"options\"]}}");
        if (_auto && !_useBig && !_useVision) // vision-routed nao oferece escalate: o big nao enxerga
            b.Append(",{\"name\":\"escalate\",\"description\":\"Hand the question over to the larger, smarter model. Call this when the user's question needs deep reasoning, careful multi-step analysis, long code, or when you feel your answer would be noticeably better from a stronger model. Do NOT call it for quick factual questions, simple lookups, translations or chit-chat.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"reason\":{\"type\":\"string\",\"description\":\"short reason in Portuguese\"}}}}");
        b.Append("],\"messages\":[");
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

    List<Blk> StreamOnce(string body, CancellationToken ct, out string stop) {
        stop = "end_turn";
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
                while ((line = sr.ReadLine()) != null) {
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
                        if (k == "tool_use") { blk.Id = H.S(cb, "id"); blk.Name = H.S(cb, "name"); }
                        blocks[idx] = blk;
                    } else if (typ == "content_block_delta") {
                        int idx = (int)H.N(root, "index");
                        Blk blk;
                        if (!blocks.TryGetValue(idx, out blk)) continue;
                        Dictionary<string, object> del = H.O(root, "delta");
                        string dk = H.S(del, "type");
                        if (dk == "text_delta") {
                            string tx = H.S(del, "text"); if (tx == null) tx = "";
                            if (ttft < 0) { ttft = swt.Elapsed.TotalSeconds; Emit("note", string.Format("1º token em {0:0.0}s", ttft)); }
                            blk.Text.Append(tx); Emit("delta", tx);
                        } else if (dk == "input_json_delta") {
                            string pj = H.S(del, "partial_json"); if (pj != null) blk.Input.Append(pj);
                        }
                    } else if (typ == "message_delta") {
                        Dictionary<string, object> md = H.O(root, "delta");
                        string srn = md == null ? null : H.S(md, "stop_reason");
                        if (srn != null) stop = srn;
                    }
                }
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
        if (b.Kind == "text") return "{\"type\":\"text\",\"text\":" + J(b.Text.ToString()) + "}";
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
    string LocalTool(string name, Dictionary<string, object> inp, CancellationToken ct) {
        string p = H.S(inp, "path");
        try {
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
            if (name == "file_write") {
                string path = H.S(inp, "path"); string content = H.S(inp, "content") ?? "";
                if (string.IsNullOrEmpty(path)) return "ERRO: path obrigatório";
                if (!GateConfirm("Gravar arquivo", path + "\n(" + content.Length + " caracteres)", ct)) return "NEGADO pelo usuário.";
                string full = Path.GetFullPath(path);
                string d = Path.GetDirectoryName(full);
                if (!Directory.Exists(d)) Directory.CreateDirectory(d);
                File.WriteAllText(full, content, new UTF8Encoding(false));
                return "OK — gravado: " + full;
            }
            if (name == "file_move") {
                string src = H.S(inp, "src"), dest = H.S(inp, "dest");
                if (string.IsNullOrEmpty(src) || string.IsNullOrEmpty(dest)) return "ERRO: src e dest obrigatórios";
                if (!File.Exists(src) && !Directory.Exists(src)) return "ERRO: não encontrado: " + src;
                if (File.Exists(dest) || Directory.Exists(dest)) return "ERRO: destino já existe: " + dest;
                if (!GateConfirm("Mover / renomear", src + "\n→ " + dest, ct)) return "NEGADO pelo usuário.";
                if (Directory.Exists(src)) Directory.Move(src, dest); else File.Move(src, dest);
                return "OK — movido/renomeado para " + dest;
            }
            if (name == "file_delete") {
                if (string.IsNullOrEmpty(p) || (!File.Exists(p) && !Directory.Exists(p))) return "ERRO: não encontrado: " + p;
                if (!GateConfirm("Apagar (vai para a Lixeira)", p, ct)) return "NEGADO pelo usuário.";
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
            if (name == "run_ps") {
                string cmd = H.S(inp, "command");
                if (string.IsNullOrEmpty(cmd)) return "ERRO: command obrigatório";
                if (!GateConfirm("Comando PowerShell", cmd, ct)) return "NEGADO pelo usuário.";
                return RunPs(cmd);
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
function New-EngineFromProfile {
    $p = Get-ActiveProfile
    $auth = Resolve-ProfileAuth $p
    $model = [string]$cfg.model
    if (-not $model) { $model = 'auto' }
    $models = @(); foreach ($m in @($p.models)) { $models += [string]$m }
    if ($models -notcontains $model) { $model = 'auto'; if ($models -notcontains 'auto' -and $models.Count -gt 0) { $model = $models[0] } }
    $eng = [ZQuick.Engine]::new($auth.base, $auth.key, $model,
        [string]$p.fastModel, [string]$p.bigModel,
        [int]$cfg.maxTokens, [string]$cfg.searchEngine, $queue)
    if ($p.visionModel) { $eng.SetVisionModel([string]$p.visionModel) }
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
     "file_write/file_move/file_delete (alteram algo — o usuário autoriza cada uma na janela; apagar vai para a Lixeira), " +
     "note_add (grava nota em Documentos\\ZQuick-Notas, sem confirmação) e run_ps (QUALQUER comando PowerShell — sempre autorizado pelo usuário; " +
     "NUNCA apague arquivos do usuário com run_ps, use file_delete). Se o usuário negar, informe e não repita a mesma ação. " +
     "Quando a tarefa tiver ambiguidade ou decisão que cabe ao usuário (qual abordagem, qual arquivo, escopo, preferência), pergunte UMA vez com ask_user: " +
     "2-4 opções de label curto + descrição do que a escolha implica; o usuário pode responder texto livre ou cancelar. " +
     "Se ele cancelar/não responder, decida sozinho a opção mais conservadora e informe — não repita a pergunta. " +
     "Ao mexer com arquivos, confirme os caminhos com file_list antes. " +
     "Formatação leve: negrito e listas simples quando ajudar, nada de títulos grandes.")
}

# ---------- XAML ----------
$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZQuick — busca rápida" Width="860" Height="600" MinWidth="520" MinHeight="360"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="False"
        Background="#202024" UseLayoutRounding="True" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2A30"/>
      <Setter Property="Foreground" Value="#E8E8EC"/>
      <Setter Property="BorderBrush" Value="#3A3A44"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Padding="14,10,14,8">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <ComboBox x:Name="ProfileBox" Width="110" FontSize="12" VerticalContentAlignment="Center" ToolTip="Perfil / provedor LLM"/>
          <ComboBox x:Name="ModelBox" Width="135" FontSize="12" Margin="8,0,0,0" VerticalContentAlignment="Center" ToolTip="Modelo"/>
          <Button x:Name="CopyBtn" Content="Copiar" Margin="8,0,0,0"/>
          <Button x:Name="NewBtn" Content="Nova" Margin="8,0,0,0"/>
          <Button x:Name="HistBtn" Content="🕘" Margin="8,0,0,0" ToolTip="Histórico — retomar conversa salva"/>
          <Button x:Name="CloseBtn" Content="✕" Margin="8,0,0,0"/>
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
            <StackPanel Orientation="Horizontal">
              <Button x:Name="ConfirmYes" Content="✅ Executar" FontWeight="SemiBold"/>
              <Button x:Name="ConfirmNo" Content="✕ Negar" Margin="8,0,0,0"/>
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
foreach ($n in 'ProfileBox','ModelBox','CopyBtn','NewBtn','HistBtn','CloseBtn','AttachScroll','AttachPanel','ConfirmBar','ConfirmTitle','ConfirmDetail','ConfirmYes','ConfirmNo','AskBar','AskHeader','AskTitle','AskPanel','AskInput','AskSendBtn','AskOkBtn','AskOtherBtn','AskCancelBtn','AskFreeRow','SendBtn','InputBox','StatusText','ModelText','AnswerView','AnswerDoc') {
    Set-Variable -Name $n -Scope Script -Value $window.FindName($n)
}
$script:baseOpacity = 1.0
if ($cfg.windowOpacity -and [double]$cfg.windowOpacity -gt 0 -and [double]$cfg.windowOpacity -lt 1) {
    $script:baseOpacity = [double]$cfg.windowOpacity
    $window.Opacity = $script:baseOpacity
}

# ---------- estado ----------
$script:busy = $false
$script:exiting = $false
$script:curAnswer = ''
$script:lastAnswer = ''
$script:pendSources = @()
$script:livePanel = $null
# anexos: {Kind: img|txt|pdf, Name, B64, Text}
$script:attachments = [System.Collections.Generic.List[object]]::new()
$script:confirmId = 0
$script:sendTime = [datetime]::MinValue
$script:convFile = $null
$script:convResumed = $false
$script:curQuestion = ''

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
        if ($line -match '^(#{1,4})\s+(.*)$') { $line = $Matches[2]; $para.FontWeight = 'SemiBold'; $para.FontSize = 14 }
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
        $t.FontSize = 10; $t.Foreground = '#6E6E7A'; $t.Margin = '0,0,0,4'
        $sec.Blocks.Add($t) | Out-Null
    }
    @{ Section = $sec; Blocks = $sec.Blocks }
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
    try {
        $arr = @(ConvertFrom-Json $json)
        if ($arr.Count -eq 0 -or $null -eq $script:livePanel) { return }
        $script:pendSources = $arr
        # Paragraph (FlowDocument) nao tem TextWrapping — quebra de linha e' nativa; so' margem
        $tb = [System.Windows.Documents.Paragraph]::new(); $tb.Margin = '0,6,0,0'
        $lbl = [System.Windows.Documents.Run]::new('Fontes: '); $lbl.Foreground = $T.dim; $tb.Inlines.Add($lbl) | Out-Null
        $i = 0
        foreach ($s in $arr) {
            $i++
            if ($i -gt 1) { $sep = [System.Windows.Documents.Run]::new(' · '); $sep.Foreground = $T.dim; $tb.Inlines.Add($sep) | Out-Null }
            $h = [System.Windows.Documents.Hyperlink]::new()
            $h.NavigateUri = [Uri]::new([string]$s.url); $h.Foreground = $T.accent
            $h.Inlines.Add([System.Windows.Documents.Run]::new("[$i] $($s.title)")) | Out-Null
            $h.Add_RequestNavigate({ param($s2, $e) Open-Url $e.Uri.ToString(); $e.Handled = $true }.GetNewClosure())
            $tb.Inlines.Add($h) | Out-Null
        }
        $script:livePanel.Add($tb) | Out-Null
    } catch { Log "sources: $_" }
}

function Set-Busy([bool]$b) {
    $script:busy = $b
    $SendBtn.IsEnabled = -not $b
    $SendBtn.Content = if ($b) { '…' } else { 'Enviar' }
}

function Finish-Turn {
    if (-not $script:busy) { return }
    Set-Busy $false
    $ConfirmBar.Visibility = 'Collapsed'
    $script:lastAnswer = $script:curAnswer
    $el = if ($script:sendTime -gt [datetime]::MinValue) { [int]((Get-Date) - $script:sendTime).TotalSeconds } else { 0 }
    $StatusText.Text = "Pronto • ${el}s"
    $prev = ($script:lastAnswer -replace '\s+', ' ').Trim()
    if ($prev.Length -gt 100) { $prev = $prev.Substring(0, 100) + '…' }
    Log ("respondido: {0} chars em {1}s | {2}" -f $script:lastAnswer.Length, $el, $prev)
    Update-LiveAnswer
    Save-History
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
        $xb = [System.Windows.Controls.Button]::new(); $xb.Content = '✕'; $xb.Padding = '4,2'; $xb.Margin = '2'; $xb.FontSize = 10
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
    $tb.Text = "📄 $name"; $tb.Foreground = $T.fg; $tb.FontSize = 11
    $tb.MaxWidth = 180; $tb.TextTrimming = 'CharacterEllipsis'; $tb.Margin = '4,0,0,0'; $tb.VerticalAlignment = 'Center'
    $sp.Children.Add($tb) | Out-Null
    $idx = $script:attachments.Count - 1
    $xb = [System.Windows.Controls.Button]::new(); $xb.Content = '✕'; $xb.Padding = '4,2'; $xb.Margin = '2'; $xb.FontSize = 10
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
    $imgs = [System.Collections.Generic.List[string]]::new()
    $txtFiles = [System.Collections.Generic.List[string[]]]::new()
    $pdfs = [System.Collections.Generic.List[string[]]]::new()
    foreach ($at in @($script:attachments)) {
        if ($at.Kind -eq 'img') { $imgs.Add([string]$at.B64) }
        elseif ($at.Kind -eq 'txt') { $txtFiles.Add(@([string]$at.Name, [string]$at.Text)) }
        elseif ($at.Kind -eq 'pdf') { $pdfs.Add(@([string]$at.Name, [string]$at.B64)) }
    }
    if (-not $text -and $imgs.Count -eq 0 -and $txtFiles.Count -eq 0 -and $pdfs.Count -eq 0) { return }
    if ($script:busy) { $StatusText.Text = 'aguarde a resposta atual…'; return }

    $q = New-Card $null
    $qtxt = "❯ $text"
    if ($imgs.Count -gt 0) { $qtxt += [Environment]::NewLine + "📎 $($imgs.Count) imagem(ns)" }
    $fnames = @($script:attachments | Where-Object { $_.Kind -ne 'img' } | ForEach-Object { [string]$_.Name })
    if ($fnames.Count -gt 0) { $qtxt += [Environment]::NewLine + "📎 " + ($fnames -join ', ') }
    Add-MdLines $q.Blocks $qtxt $true
    $AnswerDoc.Blocks.Add($q.Section) | Out-Null
    $a = New-Card $null
    $AnswerDoc.Blocks.Add($a.Section) | Out-Null
    $script:livePanel = $a.Blocks
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
    $script:engine.Ask($text, $imgs, $txtFiles, $pdfs, $sysPrompt)
}

function New-Conversation {
    $script:engine.Reset()
    $script:busy = $false
    $script:curAnswer = ''; $script:lastAnswer = ''; $script:pendSources = @(); $script:livePanel = $null
    $script:convFile = $null
    $script:convResumed = $false
    $AnswerDoc.Blocks.Clear()
    $script:attachments.Clear(); $AttachPanel.Children.Clear(); $AttachScroll.Visibility = 'Collapsed'
    $ConfirmBar.Visibility = 'Collapsed'
    if ($AskBar.Visibility -eq 'Visible') { $script:askCard = $null; Hide-AskBar }
    Set-Busy $false
    $StatusText.Text = 'nova conversa'
    Add-Placeholder
    [void]$InputBox.Focus()
}

function Add-Placeholder {
    $c = New-Card $null
    Add-MdLines $c.Blocks "Pergunte qualquer coisa — ou cole arquivos com **Ctrl+V** (print, PDF, documento, código)." $false
    $hint = [System.Windows.Documents.Paragraph]::new()
    $null = $hint.Inlines.Add([System.Windows.Documents.Run]::new(("$([string]$cfg.hotkey) mostra/oculta • Enter envia • Shift+Enter quebra linha • Esc fecha a conversa")))
    $hint.Foreground = $T.dim; $hint.FontSize = 11; $hint.Margin = '0,4,0,0'
    $c.Blocks.Add($hint) | Out-Null
    $AnswerDoc.Blocks.Add($c.Section) | Out-Null
}

# ---------- historico de conversas (salvar / retomar) ----------
$histDir = Join-Path $appDir 'history'
$script:convFile = $null

function Save-History {
    try {
        if ($null -eq $script:engine -or -not $script:convFile) { return }
        $msgs = @($script:engine.GetHistory())
        if ($msgs.Count -lt 2) { return }
        # salva TUDO, inclusive imagens (base64) — retomar devolve os pixels ao modelo
        $q = [string]$script:curQuestion
        if (-not $q) { $q = '(imagem)' }
        $obj = [ordered]@{
            time = (Get-Date).ToString('s'); profile = [string]$cfg.profile; model = [string]$cfg.model
            q = $q; a = $script:lastAnswer; msgs = @($msgs)
        }
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

function Load-Conversation([string]$file) {
    try {
        if ($script:busy) { $StatusText.Text = 'aguarde a resposta atual…'; return }
        $j = Get-Content -Path $file -Raw -Encoding utf8 | ConvertFrom-Json
        $msgs = @($j.msgs)
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
            $any = $false
            foreach ($b in @($o.content)) {
                if ([string]$b.type -eq 'text') {
                    $txt = [string]$b.text
                    if (-not $txt) { continue }
                    $any = $true
                    if ($isUser) { Add-MdLines $c.Blocks ("❯ " + $txt) $true }
                    else { Add-MdLines $c.Blocks $txt $false; $script:lastAnswer = $txt }
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
            if ($any) { $AnswerDoc.Blocks.Add($c.Section) | Out-Null }
        }
        Scroll-AnswerToEnd
        # conversa retomada CONTINUA no mesmo arquivo (proximo envio atualiza ele)
        $script:convFile = $file
        $script:convResumed = $true
        $StatusText.Text = 'conversa retomada'
        Log ("historico: retomou {0} msgs de {1}" -f $msgs.Count, (Split-Path $file -Leaf))
        [void]$InputBox.Focus()
    } catch { Log "load-history: $_"; $StatusText.Text = "erro ao retomar: $_" }
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
        Background="#202024" ShowInTaskbar="False" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2A30"/>
      <Setter Property="Foreground" Value="#E8E8EC"/>
      <Setter Property="BorderBrush" Value="#3A3A44"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>
  <DockPanel>
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
        $entries = @()
        foreach ($f in $files) {
            try {
                $j = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                $entries += [pscustomobject]@{ file = $f.FullName; time = [string]$j.time; q = [string]$j.q; a = [string]$j.a }
            } catch {}
        }
        # preenche a lista (com filtro por pergunta OU resposta); closure autocontida
        $fill = {
            $f = ([string]$hsearch.Text).Trim()
            $hlist.Items.Clear()
            foreach ($en in $entries) {
                if ($f -eq '' -or $en.q -like "*$f*" -or $en.a -like "*$f*") {
                    $q = $en.q
                    if (-not $q) { $q = '(imagem)' }
                    if ($q.Length -gt 80) { $q = $q.Substring(0, 80) + '…' }
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

        $hw.FindName('OkBtn').Add_Click({ param($s, $e)
            $sel = $hlist.SelectedItem
            if ($sel) { Load-Conversation ([string]$sel.Tag); $hw.DialogResult = $true }
        }.GetNewClosure())
        $hlist.Add_MouseDoubleClick({ param($s, $e)
            $sel = $hlist.SelectedItem
            if ($sel) { Load-Conversation ([string]$sel.Tag); $hw.DialogResult = $true }
        }.GetNewClosure())
        $hw.FindName('DelBtn').Add_Click({
            $sel = $hlist.SelectedItem
            if ($sel) {
                try { Remove-Item ([string]$sel.Tag) -Force -ErrorAction Stop } catch {}
                $hlist.Items.Remove($sel) | Out-Null
                if ($hlist.Items.Count -eq 0) { $hw.DialogResult = $false }
                elseif ($hlist.SelectedIndex -lt 0) { $hlist.SelectedIndex = 0 }
            }
        }.GetNewClosure())
        $hw.Add_PreviewKeyUp({ param($s, $e) if ($e.Key -eq 'Escape') { $s.DialogResult = $false; $e.Handled = $true } })
        $null = $hw.ShowDialog()
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
            'status'  { $StatusText.Text = $m.Text; if ($m.Text -match '🔍|📄|↗|⚙|❓') { Log ('tool: ' + $m.Text) } }
            'sources' { Show-Sources $m.Text }
            'confirm' {
                try { $c = $m.Text | ConvertFrom-Json } catch { $c = $null }
                if ($c -and $c.hide) { $ConfirmBar.Visibility = 'Collapsed' }
                elseif ($c) {
                    $script:confirmId = [int]$c.id
                    $ConfirmTitle.Text = [string]$c.title
                    $ConfirmDetail.Text = [string]$c.detail
                    $ConfirmBar.Visibility = 'Visible'
                    Log ('confirma: ' + $c.title)
                }
            }
            'ask' {
                try { $c = $m.Text | ConvertFrom-Json } catch { $c = $null }
                if ($c -and $c.hide) { Hide-AskBar }
                elseif ($c) { Show-AskBar $c }
            }
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
    $script:curAnswer = ''; $script:lastAnswer = ''; $script:pendSources = @(); $script:livePanel = $null
    $script:convFile = $null; $script:convResumed = $false
    $AnswerDoc.Blocks.Clear()
    $ConfirmBar.Visibility = 'Collapsed'
    if ($AskBar.Visibility -eq 'Visible') { $script:askCard = $null; Hide-AskBar }
    Add-Placeholder
    Log 'janela reaberta: conversa nova'
}

function Toggle-Window {
    try {
        Log 'toggle'
        if ($window.IsVisible) { $window.Hide() }
        else {
            Center-Window
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
$SendBtn.Add_Click({ Send-Current })
$CloseBtn.Add_Click({ $window.Hide() })
$NewBtn.Add_Click({ New-Conversation })
$HistBtn.Add_Click({ Show-History })
$CopyBtn.Add_Click({ if ($script:lastAnswer) { Set-Clipboard -Value $script:lastAnswer; $StatusText.Text = 'resposta copiada' } })
$ConfirmYes.Add_Click({
    if ($script:engine) { $script:engine.Confirm([int]$script:confirmId, $true) }
    $ConfirmBar.Visibility = 'Collapsed'; $StatusText.Text = 'executando…'
})
$ConfirmNo.Add_Click({
    if ($script:engine) { $script:engine.Confirm([int]$script:confirmId, $false) }
    $ConfirmBar.Visibility = 'Collapsed'; $StatusText.Text = 'ação negada'
})

# ---------- ask_user: painel de decisao multipla-escolha (estilo Claude Code) ----------
$script:askId = 0; $script:askState = $null; $script:askCard = $null

function Hide-AskBar {
    $AskBar.Visibility = 'Collapsed'
    $AskPanel.Children.Clear()
    $script:askState = $null
}

function Send-AskAnswer([string]$answer) {
    # $null/$vazio = cancelado (o engine trata como "nao respondeu")
    if ($script:engine) { $script:engine.AnswerAsk([int]$script:askId, $answer) }
    if ($script:askCard) {
        try {
            $p = [System.Windows.Documents.Paragraph]::new(); $p.Margin = '0,4,0,0'
            $what = if ([string]::IsNullOrEmpty($answer)) { '✕ cancelada' }
                    elseif ($answer.StartsWith('TEXTO:')) { '✎ ' + $answer.Substring(6).Trim() }
                    else { '✅ ' + ($answer -replace '^ESCOLHA:\s*', '' -replace ' \| ', ' + ') }
            $r = [System.Windows.Documents.Run]::new('Você: ' + $what)
            $r.Foreground = $T.q; $r.FontWeight = 'SemiBold'
            $null = $p.Inlines.Add($r)
            $script:askCard.Blocks.Add($p) | Out-Null
            Log ('ask resposta: ' + $what)
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
    $st = @{ multi = [bool]$c.multi; sel = [System.Collections.ArrayList]::new() }
    $script:askState = $st
    $hdr = [string]$c.header; if (-not $hdr) { $hdr = 'decisão' }
    $AskHeader.Text = $hdr.ToUpperInvariant()
    $AskTitle.Text = [string]$c.question
    $AskPanel.Children.Clear()
    $i = 0
    foreach ($o in @($c.options)) {
        $i++
        $lbl = [string]$o.label; $desc = [string]$o.desc
        $btn = [System.Windows.Controls.Button]::new()
        [System.Windows.Automation.AutomationProperties]::SetAutomationId($btn, "AskOpt$i")
        $btn.Tag = $lbl
        $btn.HorizontalContentAlignment = 'Left'
        $btn.Padding = '10,6'; $btn.Margin = '0,2'
        $sp = [System.Windows.Controls.StackPanel]::new()
        $t1 = [System.Windows.Controls.TextBlock]::new(); $t1.Text = $lbl; $t1.FontWeight = 'SemiBold'; $t1.FontSize = 12
        $null = $sp.Children.Add($t1)
        if ($desc) {
            $t2 = [System.Windows.Controls.TextBlock]::new(); $t2.Text = $desc
            $t2.Foreground = $T.status; $t2.FontSize = 11; $t2.TextWrapping = 'Wrap'
            $null = $sp.Children.Add($t2)
        }
        $btn.Content = $sp
        $btn.Add_Click({
            param($s, $e)
            $lb = [string]$s.Tag
            if ($st.multi) {
                if ($st.sel -contains $lb) {
                    $null = $st.sel.Remove($lb)
                    $t1.Text = $lb
                } else {
                    $null = $st.sel.Add($lb)
                    $t1.Text = [string][char]0x2714 + ' ' + $lb
                }
                $AskOkBtn.IsEnabled = ($st.sel.Count -gt 0)
            } else {
                Send-AskAnswer ('ESCOLHA: ' + $lb)
            }
        }.GetNewClosure())
        $null = $AskPanel.Children.Add($btn)
    }
    $AskOkBtn.Visibility = $(if ($st.multi) { 'Visible' } else { 'Collapsed' })
    $AskOkBtn.IsEnabled = $false
    $AskFreeRow.Visibility = 'Collapsed'; $AskInput.Text = ''
    $AskBar.Visibility = 'Visible'
    # pergunta exige o usuario: janela oculta precisa aparecer
    if (-not $window.IsVisible) { Center-Window; $window.Show() }
    [void]$window.Activate()
    if (@($AskPanel.Children).Count -gt 0) { [void]@($AskPanel.Children)[0].Focus() }
    # ecoa a pergunta na conversa (fica no card junto da resposta dada)
    $card = New-Card ('❓ ' + $hdr)
    Add-MdLines $card.Blocks ([string]$c.question) $true
    foreach ($o in @($c.options)) {
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
    $AnswerDoc.Blocks.Add($card.Section) | Out-Null
    Scroll-AnswerToEnd
    $script:askCard = $card.Section
    Log ('ask: ' + $c.question + $(if ($st.multi) { ' [multi]' } else { '' }))
}

$AskOkBtn.Add_Click({ if ($script:askState) { Send-AskAnswer ('ESCOLHA: ' + ($script:askState.sel -join ' | ')) } })
$AskOtherBtn.Add_Click({ $AskFreeRow.Visibility = 'Visible'; [void]$AskInput.Focus() })
$AskCancelBtn.Add_Click({ Log 'ask: cancelada (botão)'; Send-AskAnswer $null })
$AskSendBtn.Add_Click({ if ($AskInput.Text.Trim()) { Send-AskAnswer ('TEXTO: ' + $AskInput.Text.Trim()) } })
$AskInput.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Enter' -and $AskInput.Text.Trim()) { $e.Handled = $true; Send-AskAnswer ('TEXTO: ' + $AskInput.Text.Trim()) }
})

function Update-ModelBox {
    $p = Get-ActiveProfile
    $items = @()
    foreach ($m in @($p.models)) { $items += $(if ([string]$m -eq 'auto') { 'auto (rápida⇄forte)' } else { [string]$m }) }
    if ($items.Count -eq 0) { $items = @('auto (rápida⇄forte)') }
    $ModelBox.ItemsSource = $items
    $cur = [string]$cfg.model; if (-not $cur) { $cur = 'auto' }
    $sel = if ($cur -eq 'auto') { 'auto (rápida⇄forte)' } else { $cur }
    if ($items -notcontains $sel) { $sel = $items[0] }
    $ModelBox.SelectedItem = $sel
    $ModelText.Text = $sel
}
$ModelBox.Add_SelectionChanged({
    $sel = [string]$ModelBox.SelectedItem
    $m = if ($sel -eq 'auto (rápida⇄forte)') { 'auto' } else { $sel }
    $cfg.model = $m; Save-Config
    if ($null -ne $script:engine) { $script:engine.SetModel($m) }
    $ModelText.Text = $sel
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
    if ($null -ne $script:engine) { $script:engine.Reset() }
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
    if ($AskBar.Visibility -eq 'Visible') { Log 'esc: pergunta cancelada'; Send-AskAnswer $null }
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
