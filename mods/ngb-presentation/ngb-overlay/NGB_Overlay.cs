// =============================================================================
//  NEXT-GEN FOOTBALL BROADCAST PRESENTATION  -  overlay  (NGB_Overlay.cs)
//  MOONFROS PRESENTS  -  created by MoonFros
//
//  Transparent, click-through, always-on-top broadcast graphics for
//  Football Life 2025 / PES 2021 (FL_2025.exe, Sider 7).
//
//  Reads  ..\content\ngb-presentation\state.json  (written by the Sider Lua
//  module modules\NGB_Presentation.lua) and paints, with per-pixel alpha:
//
//     1. GOAL      spotlight card + shot analysis (mini pitch, animated
//                  trajectory, distance / angle / speed / xG)
//     2. SHOT      player spotlight for a shot, save or miss
//     3. MOTM      full-time Man of the Match reveal (gold treatment)
//     4. TOAST     milestone / assist / hotkey notifications
//     5. SCOREBUG  optional slim scoreline (off by default)
//
//  Three presentation styles are supported (full / compact / minimal); the
//  Lua module switches them with the in-game [7] key.
//
//  Build (no SDK required, .NET Framework 4.x ships with Windows 10/11):
//     %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
//         /target:winexe /optimize+ /platform:x64
//         /out:NGB_Overlay.exe NGB_Overlay.cs
//         /reference:System.dll /reference:System.Drawing.dll
//         /reference:System.Windows.Forms.dll
//         /win32manifest:app.manifest
//
//  Overlay-only hotkeys (never F7 / F8 / F9):
//     F10 = cycle demo card    F11 = diagnostics    F12 = quit
//  The presentation itself is controlled in game with [7] [8] [9].
// =============================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace Ngbfc.Presentation
{
    // =========================================================================
    //  Win32
    // =========================================================================
    internal static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }

        [StructLayout(LayoutKind.Sequential)]
        public struct SIZE { public int CX, CY; public SIZE(int x, int y) { CX = x; CY = y; } }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct BLENDFUNCTION
        {
            public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct BITMAPINFOHEADER
        {
            public int biSize, biWidth, biHeight;
            public short biPlanes, biBitCount;
            public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter;
            public int biClrUsed, biClrImportant;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct BITMAPINFO
        {
            public BITMAPINFOHEADER bmiHeader;
            public int bmiColors;
        }

        public const int WS_EX_LAYERED = 0x00080000;
        public const int WS_EX_TRANSPARENT = 0x00000020;
        public const int WS_EX_TOPMOST = 0x00000008;
        public const int WS_EX_NOACTIVATE = 0x08000000;
        public const int WS_EX_TOOLWINDOW = 0x00000080;

        public const int ULW_ALPHA = 0x00000002;
        public const byte AC_SRC_OVER = 0x00;
        public const byte AC_SRC_ALPHA = 0x01;

        public const int WM_HOTKEY = 0x0312;
        public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);

        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bmi,
            uint usage, out IntPtr bits, IntPtr section, uint offset);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst,
            ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc,
            int crKey, ref BLENDFUNCTION pblend, int dwFlags);

        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(string id);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);
    }

    // =========================================================================
    //  Tiny JSON reader (objects / arrays / strings / numbers / bool / null)
    // =========================================================================
    internal sealed class Json
    {
        private readonly string _s;
        private int _i;

        private Json(string s) { _s = s; }

        public static object Parse(string text)
        {
            if (text == null) return null;
            var p = new Json(text);
            p.SkipWs();
            object v = p.Value();
            return v;
        }

        private void SkipWs()
        {
            while (_i < _s.Length)
            {
                char c = _s[_i];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') _i++;
                else break;
            }
        }

        private object Value()
        {
            if (_i >= _s.Length) return null;
            char c = _s[_i];
            if (c == '{') return Obj();
            if (c == '[') return Arr();
            if (c == '"') return Str();
            if (c == 't' || c == 'f') return Bool();
            if (c == 'n') { _i += 4; return null; }
            return Num();
        }

        private Dictionary<string, object> Obj()
        {
            var d = new Dictionary<string, object>(StringComparer.Ordinal);
            _i++; // {
            while (true)
            {
                SkipWs();
                if (_i >= _s.Length) break;
                if (_s[_i] == '}') { _i++; break; }
                if (_s[_i] == ',') { _i++; continue; }
                string k = Str();
                SkipWs();
                if (_i < _s.Length && _s[_i] == ':') _i++;
                SkipWs();
                d[k] = Value();
            }
            return d;
        }

        private List<object> Arr()
        {
            var a = new List<object>();
            _i++; // [
            while (true)
            {
                SkipWs();
                if (_i >= _s.Length) break;
                if (_s[_i] == ']') { _i++; break; }
                if (_s[_i] == ',') { _i++; continue; }
                a.Add(Value());
            }
            return a;
        }

        private string Str()
        {
            SkipWs();
            if (_i >= _s.Length || _s[_i] != '"') return "";
            _i++;
            var sb = new StringBuilder();
            while (_i < _s.Length)
            {
                char c = _s[_i++];
                if (c == '"') break;
                if (c == '\\' && _i < _s.Length)
                {
                    char e = _s[_i++];
                    switch (e)
                    {
                        case 'n': sb.Append('\n'); break;
                        case 't': sb.Append('\t'); break;
                        case 'r': sb.Append('\r'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'u':
                            if (_i + 4 <= _s.Length)
                            {
                                int code;
                                if (int.TryParse(_s.Substring(_i, 4), NumberStyles.HexNumber,
                                                 CultureInfo.InvariantCulture, out code))
                                    sb.Append((char)code);
                                _i += 4;
                            }
                            break;
                        default: sb.Append(e); break;
                    }
                }
                else sb.Append(c);
            }
            return sb.ToString();
        }

        private bool Bool()
        {
            if (_s[_i] == 't') { _i += 4; return true; }
            _i += 5;
            return false;
        }

        private double Num()
        {
            int start = _i;
            while (_i < _s.Length)
            {
                char c = _s[_i];
                if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' ||
                    c == 'e' || c == 'E') _i++;
                else break;
            }
            double v;
            double.TryParse(_s.Substring(start, _i - start), NumberStyles.Float,
                            CultureInfo.InvariantCulture, out v);
            return v;
        }
    }

    // =========================================================================
    //  State model (mirrors content\ngb-presentation\state.json)
    // =========================================================================
    internal sealed class TeamState
    {
        public string Name = "", Abbr = "", Color = "#4FC3F7";
        public int Score;
    }

    internal sealed class ShotState
    {
        public double SpeedMph, SpeedKmh, DistanceYd, DistanceM, AngleDeg, ElevationDeg;
        public double ApexFt, ApexM, HangS, Xg, TargetX, TargetY, OriginX, OriginY;
        public string Outcome = "", Body = "", Source = "", SpeedSource = "", DistanceSource = "";
        public List<double[]> Traj = new List<double[]>();
    }

    internal sealed class MilestoneState
    {
        public string Key = "", Label = "", Tone = "accent";
    }

    internal sealed class AssistState
    {
        public string Name = "";
        public int Shirt;
    }

    internal sealed class MotmStats
    {
        public double Goals, Assists, Ga, Shots, OnTarget, Passes, PassesOk, PassPct;
        public double Tackles, TacklesOk, DribblesOk, Touches, Saves, Interceptions;
        public double PeakMph, Xg;
    }

    internal sealed class HudEvent
    {
        public int Id;
        public string Kind = "";
        public double Remaining, Duration;
        public string Side = "";

        public string PlayerName = "", Pos = "";
        public int Shirt;
        public double Rating, Minutes;
        public bool MinutesExact;

        public string TeamName = "", TeamAbbr = "", TeamColor = "#D8F26B";

        public double Shots, OnTarget, Goals, Assists, Ga, Passes, PassPct;
        public double TacklesOk, DribblesOk, Touches, Saves, Interceptions;

        public ShotState Shot;
        public MotmStats Motm;
        public MilestoneState Milestone;
        public AssistState Assist;
        public string ScoreLine = "";
    }

    internal sealed class ToastState
    {
        public string Text = "", Kind = "info";
        public int Seq;
        public double Hold = 4.0;
    }

    internal sealed class HudState
    {
        public int Seq;
        public string Units = "metric";
        public bool ScoreBug;
        public bool Master = true;
        public int Style;
        public bool Analysis = true;
        public string Credit = "", Author = "", Tagline = "";

        public bool Ffi, StatsRegion, PitchRegion, CameraOk, PlayerDb, OverlayVisible;
        public string NamesSource = "";
        public int EventCount;
        public string Clock = "";
        public TeamState Home = new TeamState(), Away = new TeamState();
        public HudEvent Event;
        public ToastState Toast;
        public double ReceivedAt;

        private static string S(Dictionary<string, object> d, string k, string def)
        {
            if (d == null || !d.ContainsKey(k)) return def;
            object v = d[k];
            if (v == null) return def;
            string s = v as string;
            return s ?? def;
        }

        private static double N(Dictionary<string, object> d, string k, double def)
        {
            if (d == null || !d.ContainsKey(k)) return def;
            object v = d[k];
            if (v is double) return (double)v;
            return def;
        }

        private static int I(Dictionary<string, object> d, string k, int def)
        {
            return (int)N(d, k, def);
        }

        private static bool B(Dictionary<string, object> d, string k, bool def)
        {
            if (d == null || !d.ContainsKey(k)) return def;
            object v = d[k];
            if (v is bool) return (bool)v;
            return def;
        }

        private static Dictionary<string, object> D(Dictionary<string, object> d, string k)
        {
            if (d == null || !d.ContainsKey(k)) return null;
            return d[k] as Dictionary<string, object>;
        }

        public static HudState FromJson(string text)
        {
            var root = Json.Parse(text) as Dictionary<string, object>;
            if (root == null) return null;
            var st = new HudState();
            st.Seq = I(root, "seq", 0);

            var hud = D(root, "hud");
            st.Units = S(hud, "units", "metric");
            st.ScoreBug = B(hud, "scorebug", false);
            st.Master = B(hud, "master", true);
            st.Style = I(hud, "style", 0);
            if (st.Style < 0) st.Style = 0;
            if (st.Style > 2) st.Style = 2;
            st.Analysis = B(hud, "analysis", true);
            st.Credit = S(hud, "credit", "MOONFROS PRESENTS");
            st.Author = S(hud, "author", "MoonFros");
            st.Tagline = S(hud, "tagline", "Next-Gen Football Broadcast Presentation");

            var toast = D(hud, "toast");
            if (toast != null)
            {
                var t = new ToastState();
                t.Text = S(toast, "text", "");
                t.Kind = S(toast, "kind", "info");
                t.Seq = I(toast, "seq", 0);
                t.Hold = N(toast, "hold", 4.0);
                if (!string.IsNullOrEmpty(t.Text)) st.Toast = t;
            }

            var status = D(root, "status");
            st.Ffi = B(status, "ffi", false);
            st.StatsRegion = B(status, "stats_region", false);
            st.PitchRegion = B(status, "pitch_region", false);
            st.CameraOk = B(status, "camera", false);
            st.PlayerDb = B(status, "player_db", false);
            st.NamesSource = S(status, "names", "");
            st.EventCount = I(status, "events", 0);
            st.OverlayVisible = B(status, "overlay_visible", false);

            var match = D(root, "match");
            st.Clock = S(match, "clock", "");
            st.Home = ReadTeam(D(match, "home"));
            st.Away = ReadTeam(D(match, "away"));

            var ev = D(root, "event");
            if (ev != null)
            {
                var e = new HudEvent();
                e.Id = I(ev, "id", 0);
                e.Kind = S(ev, "kind", "");
                e.Remaining = N(ev, "remaining", 0);
                e.Duration = N(ev, "duration", 0);
                e.Side = S(ev, "side", "home");

                var p = D(ev, "player");
                e.PlayerName = S(p, "name", "");
                e.Shirt = I(p, "shirt", 0);
                e.Pos = S(p, "pos", "");
                e.Rating = N(p, "rating", 0);
                e.Minutes = N(p, "minutes", 0);
                e.MinutesExact = B(p, "minutes_exact", false);

                var t = D(ev, "team");
                e.TeamName = S(t, "name", "");
                e.TeamAbbr = S(t, "abbr", "");
                e.TeamColor = S(t, "color", "#D8F26B");

                var s = D(ev, "stats");
                e.Shots = N(s, "shots", 0);
                e.OnTarget = N(s, "on_target", 0);
                e.Goals = N(s, "goals", 0);
                e.Assists = N(s, "assists", 0);
                e.Ga = N(s, "ga", 0);
                e.Passes = N(s, "passes", 0);
                e.PassPct = N(s, "pass_pct", 0);
                e.TacklesOk = N(s, "tackles_ok", 0);
                e.DribblesOk = N(s, "dribbles_ok", 0);
                e.Touches = N(s, "touches", 0);
                e.Saves = N(s, "saves", 0);
                e.Interceptions = N(s, "interceptions", 0);

                var ms = D(ev, "milestone");
                if (ms != null)
                {
                    e.Milestone = new MilestoneState();
                    e.Milestone.Key = S(ms, "key", "");
                    e.Milestone.Label = S(ms, "label", "");
                    e.Milestone.Tone = S(ms, "tone", "accent");
                }

                var asst = D(ev, "assist");
                if (asst != null)
                {
                    e.Assist = new AssistState();
                    e.Assist.Name = S(asst, "name", "");
                    e.Assist.Shirt = I(asst, "shirt", 0);
                }

                var sh = D(ev, "shot");
                if (sh != null)
                {
                    var ss = new ShotState();
                    ss.SpeedMph = N(sh, "speed_mph", 0);
                    ss.SpeedKmh = N(sh, "speed_kmh", 0);
                    ss.DistanceYd = N(sh, "distance_yd", 0);
                    ss.DistanceM = N(sh, "distance_m", 0);
                    ss.AngleDeg = N(sh, "angle_deg", 0);
                    ss.ElevationDeg = N(sh, "elevation_deg", 0);
                    ss.ApexFt = N(sh, "apex_ft", 0);
                    ss.ApexM = N(sh, "apex_m", 0);
                    ss.HangS = N(sh, "hang_s", 0);
                    ss.Xg = N(sh, "xg", 0);
                    ss.TargetX = N(sh, "target_x", 0);
                    ss.TargetY = N(sh, "target_y", 0);
                    ss.OriginX = N(sh, "origin_x", 0);
                    ss.OriginY = N(sh, "origin_y", 0);
                    ss.Outcome = S(sh, "outcome", "");
                    ss.Body = S(sh, "body", "");
                    ss.Source = S(sh, "source", "");
                    ss.SpeedSource = S(sh, "speed_source", "modelled");
                    ss.DistanceSource = S(sh, "distance_source", "measured");
                    var traj = (sh.ContainsKey("traj") ? sh["traj"] : null) as List<object>;
                    if (traj != null)
                    {
                        foreach (object pt in traj)
                        {
                            var arr = pt as List<object>;
                            if (arr != null && arr.Count >= 3)
                                ss.Traj.Add(new double[]
                                {
                                    (double)arr[0], (double)arr[1], (double)arr[2]
                                });
                        }
                    }
                    e.Shot = ss;
                }

                var motm = D(ev, "motm");
                if (motm != null)
                {
                    e.ScoreLine = S(motm, "score_line", "");
                    var mst = D(motm, "stats");
                    var mm = new MotmStats();
                    mm.Goals = N(mst, "goals", 0);
                    mm.Assists = N(mst, "assists", 0);
                    mm.Ga = N(mst, "ga", 0);
                    mm.Shots = N(mst, "shots", 0);
                    mm.OnTarget = N(mst, "on_target", 0);
                    mm.Passes = N(mst, "passes", 0);
                    mm.PassesOk = N(mst, "passes_ok", 0);
                    mm.PassPct = N(mst, "pass_pct", 0);
                    mm.Tackles = N(mst, "tackles", 0);
                    mm.TacklesOk = N(mst, "tackles_ok", 0);
                    mm.DribblesOk = N(mst, "dribbles_ok", 0);
                    mm.Touches = N(mst, "touches", 0);
                    mm.Saves = N(mst, "saves", 0);
                    mm.Interceptions = N(mst, "interceptions", 0);
                    mm.PeakMph = N(mst, "peak_mph", 0);
                    mm.Xg = N(mst, "xg", 0);
                    e.Motm = mm;
                }
                st.Event = e;
            }
            return st;
        }

        private static TeamState ReadTeam(Dictionary<string, object> d)
        {
            var t = new TeamState();
            if (d == null) return t;
            t.Name = S(d, "name", "");
            t.Abbr = S(d, "abbr", "");
            t.Color = S(d, "color", "#4FC3F7");
            t.Score = I(d, "score", 0);
            return t;
        }
    }

    // =========================================================================
    //  Palette + fonts
    //
    //  Restrained broadcast look: graphite glass, white type, one soft accent
    //  and a gold treatment reserved for milestones and Man of the Match.
    // =========================================================================
    internal sealed class Theme
    {
        public static readonly Color Accent = Color.FromArgb(255, 216, 242, 107);
        public static readonly Color AccentDim = Color.FromArgb(120, 216, 242, 107);
        public static readonly Color Gold = Color.FromArgb(255, 233, 200, 122);
        public static readonly Color GoldDim = Color.FromArgb(120, 233, 200, 122);
        public static readonly Color Ink = Color.FromArgb(255, 6, 8, 11);
        public static readonly Color Glass1 = Color.FromArgb(238, 13, 16, 21);
        public static readonly Color Glass2 = Color.FromArgb(226, 22, 26, 33);
        public static readonly Color White = Color.FromArgb(255, 255, 255, 255);
        public static readonly Color Muted = Color.FromArgb(205, 158, 168, 178);
        public static readonly Color Red = Color.FromArgb(255, 255, 90, 78);
        public static readonly Color Green = Color.FromArgb(255, 116, 214, 148);

        public string UnitSpeed = "KM/H";
        public string UnitDist = "M";
        public string UnitHeight = "M";

        public Font Big, Huge, Name, NameSmall, Label, Value, ValueBig, Tiny, Mid, Title, Micro;

        public void ApplyUnits(HudState st)
        {
            bool metric = st == null || !string.Equals(st.Units, "imperial", StringComparison.OrdinalIgnoreCase);
            UnitSpeed = metric ? "KM/H" : "MPH";
            UnitDist = metric ? "M" : "YD";
            UnitHeight = metric ? "M" : "FT";
        }

        public void Build(float s)
        {
            Dispose();
            string famBig = PickFamily("Bahnschrift SemiCondensed", "Bahnschrift", "Segoe UI Semibold", "Arial");
            string famText = PickFamily("Segoe UI Semibold", "Segoe UI", "Arial");
            Big = new Font(famBig, 74f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Huge = new Font(famBig, 104f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Name = new Font(famBig, 50f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            NameSmall = new Font(famBig, 38f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Mid = new Font(famBig, 30f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Title = new Font(famText, 19f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Label = new Font(famText, 14f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Value = new Font(famBig, 28f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            ValueBig = new Font(famBig, 42f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Tiny = new Font(famText, 12.5f * s, FontStyle.Regular, GraphicsUnit.Pixel);
            Micro = new Font(famText, 10.5f * s, FontStyle.Regular, GraphicsUnit.Pixel);
        }

        private static string PickFamily(params string[] names)
        {
            var installed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (var f in FontFamily.Families) installed.Add(f.Name);
            }
            catch { }
            foreach (var n in names) if (installed.Contains(n)) return n;
            return "Arial";
        }

        public void Dispose()
        {
            Font[] all = { Big, Huge, Name, NameSmall, Label, Value, ValueBig, Tiny, Mid, Title, Micro };
            foreach (var f in all) if (f != null) f.Dispose();
            Big = Huge = Name = NameSmall = Label = Value = ValueBig = Tiny = Mid = Title = Micro = null;
        }
    }

    // =========================================================================
    //  Draw helpers
    // =========================================================================
    internal static class Draw
    {
        public static Color ParseColor(string hex, Color fallback)
        {
            if (string.IsNullOrEmpty(hex)) return fallback;
            string h = hex.TrimStart('#');
            if (h.Length != 6) return fallback;
            try
            {
                int r = int.Parse(h.Substring(0, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                int g = int.Parse(h.Substring(2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                int b = int.Parse(h.Substring(4, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                return Color.FromArgb(255, r, g, b);
            }
            catch { return fallback; }
        }

        public static Color Mix(Color a, Color b, float t)
        {
            t = Math.Max(0f, Math.Min(1f, t));
            return Color.FromArgb(
                (int)(a.A + (b.A - a.A) * t),
                (int)(a.R + (b.R - a.R) * t),
                (int)(a.G + (b.G - a.G) * t),
                (int)(a.B + (b.B - a.B) * t));
        }

        public static GraphicsPath Skew(RectangleF r, float skew)
        {
            var p = new GraphicsPath();
            p.AddPolygon(new[]
            {
                new PointF(r.Left + skew, r.Top),
                new PointF(r.Right + skew, r.Top),
                new PointF(r.Right - skew, r.Bottom),
                new PointF(r.Left - skew, r.Bottom)
            });
            return p;
        }

        // Broadcast glass panel: soft vertical gradient, 1px light edge, team
        // colour accent bar on the left, faint top highlight.
        public static void GlassPanel(Graphics g, RectangleF r, float skew, Color teamColor)
        {
            using (var path = Skew(r, skew))
            using (var b = new LinearGradientBrush(
                new RectangleF(r.X, r.Y, r.Width, r.Height + 1),
                Theme.Glass1, Theme.Glass2, LinearGradientMode.Vertical))
            {
                g.FillPath(b, path);
                using (var edge = new Pen(Color.FromArgb(38, 255, 255, 255), Math.Max(1f, r.Height * 0.0035f)))
                    g.DrawPath(edge, path);
            }
            var bar = new RectangleF(r.Left, r.Top, Math.Max(4f, r.Height * 0.022f), r.Height);
            using (var b2 = new LinearGradientBrush(bar, Theme.Accent, teamColor, LinearGradientMode.Vertical))
            using (var path2 = new GraphicsPath())
            {
                path2.AddPolygon(new[]
                {
                    new PointF(bar.Left + skew, bar.Top),
                    new PointF(bar.Right + skew, bar.Top),
                    new PointF(bar.Right - skew, bar.Bottom),
                    new PointF(bar.Left - skew, bar.Bottom)
                });
                g.FillPath(b2, path2);
            }
            using (var hl = new Pen(Color.FromArgb(26, 255, 255, 255), 1f))
                g.DrawLine(hl, r.Left + skew, r.Top + 0.5f, r.Right + skew, r.Top + 0.5f);
        }

        public static void GoldFrame(Graphics g, RectangleF r, float s)
        {
            using (var pen = new Pen(Color.FromArgb(150, Theme.Gold), Math.Max(1f, 1.6f * s)))
            using (var p = new GraphicsPath())
            {
                float sk = 10 * s;
                p.AddPolygon(new[]
                {
                    new PointF(r.Left + sk, r.Top),
                    new PointF(r.Right + sk, r.Top),
                    new PointF(r.Right - sk, r.Bottom),
                    new PointF(r.Left - sk, r.Bottom)
                });
                g.DrawPath(pen, p);
            }
        }

        public static void Text(Graphics g, string s, Font f, Brush b, float x, float y)
        {
            if (string.IsNullOrEmpty(s)) return;
            g.DrawString(s, f, b, x, y, StringFormat.GenericTypographic);
        }

        public static void TextRight(Graphics g, string s, Font f, Brush b, float right, float y)
        {
            if (string.IsNullOrEmpty(s)) return;
            var sz = g.MeasureString(s, f, PointF.Empty, StringFormat.GenericTypographic);
            g.DrawString(s, f, b, right - sz.Width, y, StringFormat.GenericTypographic);
        }

        public static void TextCentre(Graphics g, string s, Font f, Brush b, float centre, float y)
        {
            if (string.IsNullOrEmpty(s)) return;
            var sz = g.MeasureString(s, f, PointF.Empty, StringFormat.GenericTypographic);
            g.DrawString(s, f, b, centre - sz.Width / 2f, y, StringFormat.GenericTypographic);
        }

        public static void TextClipped(Graphics g, string s, Font f, Brush b,
                                       float x, float y, float maxWidth)
        {
            if (string.IsNullOrEmpty(s)) return;
            if (maxWidth <= 8f) return;
            var lay = new RectangleF(x, y, maxWidth, f.Size * 1.35f);
            using (var fmt = new StringFormat(StringFormat.GenericTypographic))
            {
                fmt.Trimming = StringTrimming.EllipsisCharacter;
                fmt.FormatFlags |= StringFormatFlags.NoWrap;
                g.DrawString(s, f, b, lay, fmt);
            }
        }

        public static float Width(Graphics g, string s, Font f)
        {
            if (string.IsNullOrEmpty(s)) return 0f;
            return g.MeasureString(s, f, PointF.Empty, StringFormat.GenericTypographic).Width;
        }

        public static void Spaced(Graphics g, string s, Font f, Brush b, float x, float y, float spacing)
        {
            if (string.IsNullOrEmpty(s)) return;
            float cx = x;
            for (int i = 0; i < s.Length; i++)
            {
                string ch = s.Substring(i, 1);
                g.DrawString(ch, f, b, cx, y, StringFormat.GenericTypographic);
                cx += Width(g, ch, f) + spacing;
            }
        }

        public static float SpacedWidth(Graphics g, string s, Font f, float spacing)
        {
            if (string.IsNullOrEmpty(s)) return 0f;
            float w = 0f;
            for (int i = 0; i < s.Length; i++) w += Width(g, s.Substring(i, 1), f) + spacing;
            return w;
        }

        public static void Pill(Graphics g, RectangleF r, Color fill, string text, Font f, Color txt,
                                float tracking)
        {
            using (var path = new GraphicsPath())
            {
                float d = Math.Min(r.Height, r.Height * 0.9f);
                path.AddArc(r.Left, r.Top, d, r.Height, 90, 180);
                path.AddArc(r.Right - d, r.Top, d, r.Height, 270, 180);
                path.CloseFigure();
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
            }
            using (var tb = new SolidBrush(txt))
            {
                float tw = tracking > 0 ? SpacedWidth(g, text, f, tracking) : Width(g, text, f);
                float tx = r.Left + (r.Width - tw) / 2f;
                float ty = r.Top + (r.Height - f.Size) * 0.44f;
                if (tracking > 0) Spaced(g, text, f, tb, tx, ty, tracking);
                else Text(g, text, f, tb, tx, ty);
            }
        }

        public static void Hairline(Graphics g, float x, float y, float w, float alpha)
        {
            using (var b = new SolidBrush(Color.FromArgb((int)alpha, 255, 255, 255)))
                g.FillRectangle(b, x, y, w, 1f);
        }

        // One statistic cell: spaced uppercase label over a large value.
        public static void Cell(Graphics g, Theme th, float x, float y, float w,
                                string label, string value, Color accent, float s,
                                float tracking, float slide)
        {
            using (var muted = new SolidBrush(Theme.Muted))
            using (var white = new SolidBrush(Theme.White))
            using (var acc = new SolidBrush(accent))
            {
                float lx = x - (1f - slide) * 14 * s;
                Spaced(g, label, th.Label, muted, lx, y, tracking);
                Text(g, value, th.ValueBig, white, lx, y + 20 * s);
                using (var bar = new SolidBrush(Color.FromArgb(160, accent)))
                    g.FillRectangle(bar, lx, y + 74 * s, Math.Min(w - 6 * s, 30 * s), 2 * s);
            }
        }

        // Vertical progress ring (used for the MOTM rating).
        public static void Ring(Graphics g, RectangleF box, float pct, Color accent, float s,
                                string caption, Font valueFont)
        {
            pct = Math.Max(0f, Math.Min(1f, pct));
            using (var track = new Pen(Color.FromArgb(48, 255, 255, 255), 5 * s))
                g.DrawEllipse(track, box);
            using (var pen = new Pen(accent, 5 * s))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                if (pct > 0.001f) g.DrawArc(pen, box, -90f, 360f * pct);
            }
            if (!string.IsNullOrEmpty(caption) && valueFont != null)
            {
                using (var b = new SolidBrush(Theme.White))
                {
                    float cy = box.Top + (box.Height - valueFont.Size) / 2f;
                    TextCentre(g, caption, valueFont, b, box.Left + box.Width / 2f, cy);
                }
            }
        }
    }

    // =========================================================================
    //  Render target: 32bpp DIB + UpdateLayeredWindow (per-pixel alpha)
    // =========================================================================
    internal sealed class RenderTarget : IDisposable
    {
        private IntPtr _memDc, _bmp, _old, _bits, _screenDc;
        private Graphics _g;
        private int _w, _h;

        public Graphics Graphics { get { return _g; } }
        public int Width { get { return _w; } }
        public int Height { get { return _h; } }

        public void Resize(int w, int h)
        {
            if (w <= 0 || h <= 0) return;
            if (w == _w && h == _h && _g != null) return;
            Release();
            _w = w; _h = h;
            _screenDc = Native.GetDC(IntPtr.Zero);
            _memDc = Native.CreateCompatibleDC(_screenDc);
            var bmi = new Native.BITMAPINFO();
            bmi.bmiHeader.biSize = Marshal.SizeOf(typeof(Native.BITMAPINFOHEADER));
            bmi.bmiHeader.biWidth = w;
            bmi.bmiHeader.biHeight = -h;   // top-down
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = 0; // BI_RGB
            _bmp = Native.CreateDIBSection(_screenDc, ref bmi, 0, out _bits, IntPtr.Zero, 0);
            _old = Native.SelectObject(_memDc, _bmp);
            _g = Graphics.FromHdc(_memDc);
            _g.SmoothingMode = SmoothingMode.AntiAlias;
            _g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            _g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            _g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        }

        public void Begin()
        {
            if (_g == null) return;
            _g.Clear(Color.FromArgb(0, 0, 0, 0));
        }

        public void Present(IntPtr hwnd, int x, int y)
        {
            if (_g == null || hwnd == IntPtr.Zero) return;
            _g.Flush();
            var dst = new Native.POINT(x, y);
            var size = new Native.SIZE(_w, _h);
            var src = new Native.POINT(0, 0);
            var blend = new Native.BLENDFUNCTION();
            blend.BlendOp = Native.AC_SRC_OVER;
            blend.SourceConstantAlpha = 255;
            blend.AlphaFormat = Native.AC_SRC_ALPHA;
            Native.UpdateLayeredWindow(hwnd, _screenDc, ref dst, ref size, _memDc, ref src,
                                       0, ref blend, Native.ULW_ALPHA);
        }

        private void Release()
        {
            try { if (_g != null) { _g.Dispose(); _g = null; } } catch { }
            if (_old != IntPtr.Zero) { Native.SelectObject(_memDc, _old); _old = IntPtr.Zero; }
            if (_bmp != IntPtr.Zero) { Native.DeleteObject(_bmp); _bmp = IntPtr.Zero; }
            if (_memDc != IntPtr.Zero) { Native.DeleteDC(_memDc); _memDc = IntPtr.Zero; }
            if (_screenDc != IntPtr.Zero) { Native.ReleaseDC(IntPtr.Zero, _screenDc); _screenDc = IntPtr.Zero; }
        }

        public void Dispose() { Release(); }
    }

    // =========================================================================
    //  The overlay window
    // =========================================================================
    internal sealed class OverlayForm : Form
    {
        private const int HOTKEY_DEMO = 0xB001;   // F10
        private const int HOTKEY_DIAG = 0xB002;   // F11
        private const int HOTKEY_QUIT = 0xB003;   // F12

        private readonly RenderTarget _rt = new RenderTarget();
        private readonly Theme _theme = new Theme();
        private readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer();
        private readonly Stopwatch _clock = Stopwatch.StartNew();

        private string _statePath;
        private HudState _state;
        private double _lastRead;
        private long _lastEventKey = -1;
        private double _eventFirstSeen;

        private IntPtr _gameHwnd = IntPtr.Zero;
        private int _gamePid;
        private double _lastProbe;
        private int _winX, _winY, _winW, _winH;

        private bool _diag;
        private int _demoPhase;
        private double _demoStart;
        private string _logPath;
        private int _readErrors;

        private int _lastToastSeq = -1;
        private double _toastStart;
        private ToastState _toast;

        public OverlayForm(string statePath)
        {
            _statePath = statePath;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            Bounds = new Rectangle(0, 0, 1, 1);
            BackColor = Color.Black;
            Name = "NGBOverlay";

            _timer.Interval = 16;
            _timer.Tick += OnTick;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TRANSPARENT |
                              Native.WS_EX_TOPMOST | Native.WS_EX_NOACTIVATE |
                              Native.WS_EX_TOOLWINDOW;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.RegisterHotKey(Handle, HOTKEY_DEMO, 0, (uint)Keys.F10);
            Native.RegisterHotKey(Handle, HOTKEY_DIAG, 0, (uint)Keys.F11);
            Native.RegisterHotKey(Handle, HOTKEY_QUIT, 0, (uint)Keys.F12);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            Native.UnregisterHotKey(Handle, HOTKEY_DEMO);
            Native.UnregisterHotKey(Handle, HOTKEY_DIAG);
            Native.UnregisterHotKey(Handle, HOTKEY_QUIT);
            _timer.Stop();
            _rt.Dispose();
            _theme.Dispose();
            base.OnFormClosing(e);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY)
            {
                int id = m.WParam.ToInt32();
                if (id == HOTKEY_DEMO)
                {
                    _demoPhase = (_demoPhase + 1) % 4;
                    _demoStart = _clock.Elapsed.TotalSeconds;
                }
                else if (id == HOTKEY_DIAG) { _diag = !_diag; }
                else if (id == HOTKEY_QUIT) { Close(); return; }
            }
            base.WndProc(ref m);
        }

        // ---------------------------------------------------------------------
        public void Start()
        {
            _logPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "NGB_Overlay.log");
            Log("overlay starting; state = " + _statePath);
            TryReadState(true);
            _timer.Start();
        }

        private void Log(string s)
        {
            try
            {
                var fi = new FileInfo(_logPath ?? "NGB_Overlay.log");
                if (fi.Exists && fi.Length > 512 * 1024) File.Delete(_logPath);
                File.AppendAllText(_logPath,
                    DateTime.Now.ToString("HH:mm:ss") + "  " + s + Environment.NewLine);
            }
            catch { }
        }

        // ---------------------------------------------------------------------
        //  State file + game window probing
        // ---------------------------------------------------------------------
        private void TryReadState(bool force)
        {
            double now = _clock.Elapsed.TotalSeconds;
            if (!force && (now - _lastRead) < 0.05) return;
            _lastRead = now;
            try
            {
                if (!File.Exists(_statePath)) return;
                string text;
                using (var fs = new FileStream(_statePath, FileMode.Open, FileAccess.Read,
                                               FileShare.ReadWrite | FileShare.Delete))
                using (var sr = new StreamReader(fs, Encoding.UTF8))
                {
                    text = sr.ReadToEnd();
                }
                if (text.Length < 8) return;
                var st = HudState.FromJson(text);
                if (st != null)
                {
                    st.ReceivedAt = now;
                    _state = st;
                    _theme.ApplyUnits(st);
                    if (st.Toast != null && st.Toast.Seq != _lastToastSeq)
                    {
                        _lastToastSeq = st.Toast.Seq;
                        _toast = st.Toast;
                        _toastStart = now;
                    }
                }
            }
            catch (Exception)
            {
                _readErrors++;
                if (_readErrors == 1 || (_readErrors % 200) == 0)
                    Log("state read error #" + _readErrors + " (game still writing?)");
            }
        }

        private void ProbeGameWindow()
        {
            double now = _clock.Elapsed.TotalSeconds;
            if (_gameHwnd != IntPtr.Zero && Native.IsWindow(_gameHwnd) &&
                Native.IsWindowVisible(_gameHwnd) && (now - _lastProbe) < 1.0)
                return;
            if ((now - _lastProbe) < 1.0 && _gameHwnd != IntPtr.Zero) return;
            _lastProbe = now;

            _gameHwnd = IntPtr.Zero;
            string[] wanted = { "FL_2025", "FL2025", "PES2021" };
            Process[] procs;
            try { procs = Process.GetProcesses(); }
            catch { return; }
            foreach (var w in wanted)
            {
                foreach (var p in procs)
                {
                    try
                    {
                        if (string.Equals(p.ProcessName, w, StringComparison.OrdinalIgnoreCase) &&
                            p.MainWindowHandle != IntPtr.Zero)
                        {
                            _gameHwnd = p.MainWindowHandle;
                            _gamePid = p.Id;
                            break;
                        }
                    }
                    catch { }
                }
                if (_gameHwnd != IntPtr.Zero) break;
            }
        }

        private bool ComputeGameRect()
        {
            if (_gameHwnd == IntPtr.Zero) return false;
            if (Native.IsIconic(_gameHwnd) || !Native.IsWindowVisible(_gameHwnd)) return false;

            IntPtr fg = Native.GetForegroundWindow();
            if (fg != IntPtr.Zero && _gamePid != 0)
            {
                int fgPid;
                Native.GetWindowThreadProcessId(fg, out fgPid);
                if (fgPid != _gamePid) return false;
            }

            Native.RECT cr;
            if (!Native.GetClientRect(_gameHwnd, out cr)) return false;
            var tl = new Native.POINT(0, 0);
            if (!Native.ClientToScreen(_gameHwnd, ref tl)) return false;

            int w = cr.Right - cr.Left;
            int h = cr.Bottom - cr.Top;
            if (w < 320 || h < 200) return false;

            _winX = tl.X; _winY = tl.Y; _winW = w; _winH = h;
            return true;
        }

        // ---------------------------------------------------------------------
        //  Frame
        // ---------------------------------------------------------------------
        private void OnTick(object sender, EventArgs e)
        {
            try { Tick(); }
            catch (Exception ex) { Log("tick error: " + ex.Message); }
        }

        private void Tick()
        {
            ProbeGameWindow();
            TryReadState(false);

            HudState st = _state;
            bool toastOn = _toast != null &&
                (_clock.Elapsed.TotalSeconds - _toastStart) < Math.Max(1.0, _toast.Hold);

            if (st == null && _demoPhase == 0 && !_diag && !toastOn)
            {
                if (Visible) Hide();
                return;
            }
            if (!ComputeGameRect()) { if (Visible) Hide(); return; }

            float s = Math.Max(0.35f, Math.Min(2.6f, _winH / 1080f));
            if (_theme.Big == null || Math.Abs(_theme.Big.Size - 74f * s) > 0.5f)
                _theme.Build(s);

            if (Location.X != _winX || Location.Y != _winY ||
                _rt.Width != _winW || _rt.Height != _winH)
                Bounds = new Rectangle(_winX, _winY, _winW, _winH);
            _rt.Resize(_winW, _winH);

            // ---- which card is on screen right now? ----
            HudEvent ev = null;
            double elapsed = 0, remaining = 0;

            if (_demoPhase != 0)
            {
                const double cycle = 20.0;
                double since = _clock.Elapsed.TotalSeconds - _demoStart;
                double tt = since % cycle;
                ev = BuildDemoEvent(st, s);
                ev.Duration = cycle;
                ev.Remaining = cycle - tt;
                elapsed = tt;
                remaining = ev.Remaining;
            }
            else if (st != null && st.Event != null && st.Event.Remaining > 0 && st.Master)
            {
                ev = st.Event;
                remaining = ev.Remaining;
                long key = (long)ev.Id * 31 + ev.Kind.GetHashCode();
                if (key != _lastEventKey)
                {
                    _lastEventKey = key;
                    _eventFirstSeen = _clock.Elapsed.TotalSeconds;
                }
                elapsed = Math.Max(0, _clock.Elapsed.TotalSeconds - _eventFirstSeen);
            }

            bool anything = ev != null || toastOn || (st != null && st.ScoreBug) || _diag;
            if (!anything)
            {
                if (Visible) { _rt.Begin(); _rt.Present(Handle, _winX, _winY); Hide(); }
                return;
            }
            if (!Visible) Show();

            _rt.Begin();
            var g = _rt.Graphics;
            if (g == null) return;

            if (st != null && st.ScoreBug) DrawScoreBug(g, st, _winW, _winH, s);
            if (ev != null && remaining > 0)
            {
                switch (ev.Kind)
                {
                    case "goal": DrawGoalCard(g, ev, st, _winW, _winH, s, elapsed, remaining); break;
                    case "shot": DrawShotCard(g, ev, st, _winW, _winH, s, elapsed, remaining); break;
                    case "motm": DrawMotmCard(g, ev, st, _winW, _winH, s, elapsed, remaining); break;
                }
            }
            if (toastOn && _toast != null)
                DrawToast(g, _toast, _clock.Elapsed.TotalSeconds - _toastStart, _winW, s);
            if (_diag) DrawDiagnostics(g, st, _winW, _winH, s);

            _rt.Present(Handle, _winX, _winY);
        }

        // ---------------------------------------------------------------------
        //  1. GOAL card - spotlight + shot analysis
        // ---------------------------------------------------------------------
        private void DrawGoalCard(Graphics g, HudEvent ev, HudState st, int w, int h, float s,
                                  double elapsed, double remaining)
        {
            double t = Anim(elapsed, remaining);
            if (t <= 0.001) return;
            Color team = Draw.ParseColor(ev.TeamColor, Theme.Accent);
            int style = st != null ? st.Style : 0;
            bool analysis = (st == null || st.Analysis) && style == 0;

            if (style >= 2) { DrawMinimalBar(g, ev, st, w, h, s, t, team); return; }

            float k = style == 1 ? 0.84f : 1f;
            float pw = (analysis ? 1180f : 760f) * s * k;
            float ph = (analysis ? 320f : 214f) * s * k;
            float px = 56 * s;
            float py = h - 56 * s - ph;
            if (py < 24 * s) py = 24 * s;
            float slide = (float)((1.0 - Ease(t)) * 44 * s);
            var r = new RectangleF(px, py + slide, pw, ph);

            Draw.GlassPanel(g, r, 10 * s, team);
            float cx = r.Left + 34 * s;
            float cy = r.Top + 22 * s;
            float textW = analysis ? 560f * s * k : pw - 68 * s;

            DrawKicker(g, ev, r, team, s, true);
            DrawPlayerBlock(g, ev, cx, cy + 30 * s, textW, s, team, t);
            DrawShotCells(g, ev, cx, r.Bottom - 84 * s, analysis ? 4 : 5, s, team, t, analysis ? 128 * s : 130 * s);
            DrawFooter(g, st, ev, r, s, analysis);

            if (analysis)
            {
                var box = new RectangleF(r.Right - 34 * s - 500 * s, r.Top + 22 * s,
                                         500 * s, ph - 76 * s);
                DrawAnalysisPanel(g, box, ev, team, s, elapsed, t);
            }
        }

        // ---------------------------------------------------------------------
        //  2. SHOT / reaction card - player spotlight only
        // ---------------------------------------------------------------------
        private void DrawShotCard(Graphics g, HudEvent ev, HudState st, int w, int h, float s,
                                  double elapsed, double remaining)
        {
            double t = Anim(elapsed, remaining);
            if (t <= 0.001) return;
            Color team = Draw.ParseColor(ev.TeamColor, Theme.Accent);
            int style = st != null ? st.Style : 0;

            if (style >= 2) { DrawMinimalBar(g, ev, st, w, h, s, t, team); return; }

            float k = style == 1 ? 0.86f : 1f;
            float pw = 800f * s * k;
            float ph = 218f * s * k;
            float px = 56 * s;
            float py = h - 56 * s - ph;
            if (py < 24 * s) py = 24 * s;
            float slide = (float)((1.0 - Ease(t)) * 44 * s);
            var r = new RectangleF(px, py + slide, pw, ph);

            Draw.GlassPanel(g, r, 9 * s, team);
            float cx = r.Left + 32 * s;
            DrawKicker(g, ev, r, team, s, false);
            DrawPlayerBlock(g, ev, cx, r.Top + 52 * s, pw - 64 * s, s, team, t);
            DrawShotCells(g, ev, cx, r.Bottom - 76 * s, 4, s, team, t, 132 * s);
            DrawFooter(g, st, ev, r, s, false);
        }

        // ---------------------------------------------------------------------
        //  3. MOTM reveal - gold treatment
        // ---------------------------------------------------------------------
        private void DrawMotmCard(Graphics g, HudEvent ev, HudState st, int w, int h, float s,
                                  double elapsed, double remaining)
        {
            double t = Anim(elapsed, remaining);
            if (t <= 0.001) return;
            Color team = Draw.ParseColor(ev.TeamColor, Theme.Accent);
            int style = st != null ? st.Style : 0;
            if (style >= 2) { DrawMinimalBar(g, ev, st, w, h, s, t, team); return; }

            float k = style == 1 ? 0.86f : 1f;
            float pw = 900f * s * k;
            float ph = 545f * s * k;
            float px = w - pw - 56 * s;
            float py = (h - ph) / 2f;
            if (px < 24 * s) px = 24 * s;
            float slideIn = (float)((1.0 - Ease(t)) * 54 * s);

            var r = new RectangleF(px + slideIn, py, pw, ph);
            Draw.GlassPanel(g, r, 12 * s, Theme.Gold);
            Draw.GoldFrame(g, r, s);

            using (var gold = new SolidBrush(Theme.Gold))
            using (var white = new SolidBrush(Theme.White))
            using (var muted = new SolidBrush(Theme.Muted))
            {
                Draw.Spaced(g, "MAN OF THE MATCH", _theme.Label, gold,
                            r.Left + 36 * s, r.Top + 26 * s, 2.4f * s);
                Draw.Text(g, ev.TeamAbbr, _theme.Mid, white, r.Left + 36 * s, r.Top + 50 * s);
                Draw.Text(g, ev.ScoreLine, _theme.Tiny, muted, r.Left + 36 * s, r.Top + 92 * s);

                // name + identity
                Draw.TextClipped(g, ev.PlayerName, _theme.Name, white,
                                 r.Left + 36 * s, r.Top + 124 * s, pw - 240 * s);
                string sub = "#" + ev.Shirt;
                if (!string.IsNullOrEmpty(ev.Pos)) sub += "   " + ev.Pos;
                sub += "   " + MinutesText(ev);
                Draw.Spaced(g, sub, _theme.Label, muted, r.Left + 36 * s, r.Top + 186 * s, 1.2f * s);

                // rating ring
                var ring = new RectangleF(r.Right - 190 * s, r.Top + 40 * s, 130 * s, 130 * s);
                float pct = (float)Math.Max(0, Math.Min(1, (ev.Rating - 5.0) / 5.0));
                Draw.Ring(g, ring, pct * (float)Math.Min(1, t * 1.6), Theme.Gold, s,
                          ev.Rating > 0 ? Fmt(ev.Rating, 1) : "", _theme.ValueBig);
                Draw.Spaced(g, "RATING", _theme.Micro, muted,
                            ring.Left + 30 * s, ring.Bottom + 8 * s, 1.6f * s);

                // statistic grid 4 x 2
                var ms = ev.Motm;
                string[][] grid = ms == null
                    ? new[]
                      {
                          new[] { "GOALS", Fmt0(ev.Goals) }, new[] { "ASSISTS", Fmt0(ev.Assists) },
                          new[] { "SHOTS", Fmt0(ev.Shots) }, new[] { "ON TARGET", Fmt0(ev.OnTarget) },
                          new[] { "PASSES", Fmt0(ev.Passes) }, new[] { "PASS %", Fmt0(ev.PassPct) },
                          new[] { "TOUCHES", Fmt0(ev.Touches) }, new[] { "MINUTES", MinutesRaw(ev) },
                      }
                    : new[]
                      {
                          new[] { "GOALS", Fmt0(ms.Goals) }, new[] { "ASSISTS", Fmt0(ms.Assists) },
                          new[] { "SHOTS", Fmt0(ms.Shots) }, new[] { "ON TARGET", Fmt0(ms.OnTarget) },
                          new[] { "PASSES", Fmt0(ms.Passes) }, new[] { "PASS %", Fmt0(ms.PassPct) },
                          new[] { "TOUCHES", Fmt0(ms.Touches) }, new[] { "MINUTES", MinutesRaw(ev) },
                      };

                float gx = r.Left + 36 * s;
                float gy = r.Top + 248 * s;
                float cellW = (pw - 72 * s) / 4f;
                float cellH = 108 * s;
                for (int i = 0; i < grid.Length; i++)
                {
                    float x = gx + (i % 4) * cellW;
                    float y = gy + (i / 4) * cellH;
                    Draw.Cell(g, _theme, x, y, cellW, grid[i][0], grid[i][1],
                              Theme.Gold, s, 1.4f * s, (float)Math.Min(1, t * 1.2));
                }

                Draw.Hairline(g, gx, gy + 2 * cellH - 18 * s, pw - 72 * s, 34);
                if (st != null && !string.IsNullOrEmpty(st.Credit))
                    Draw.Spaced(g, st.Credit, _theme.Micro, gold,
                                gx, r.Bottom - 30 * s, 1.8f * s);
                Draw.TextRight(g, "CREATED BY " + (st != null ? st.Author : "MOONFROS"),
                               _theme.Micro, muted, r.Right - 36 * s, r.Bottom - 30 * s);
            }
        }

        // ---------------------------------------------------------------------
        //  4. Minimal presentation style (style 2)
        // ---------------------------------------------------------------------
        private void DrawMinimalBar(Graphics g, HudEvent ev, HudState st, int w, int h, float s,
                                    double t, Color team)
        {
            float pw = 780 * s;
            float ph = 78 * s;
            float px = 56 * s;
            float py = h - 56 * s - ph;
            float slide = (float)((1.0 - Ease(t)) * 30 * s);
            var r = new RectangleF(px, py + slide, pw, ph);

            using (var back = new SolidBrush(Color.FromArgb(214, 12, 15, 20)))
                g.FillRectangle(back, r);
            using (var bar = new SolidBrush(team))
                g.FillRectangle(bar, r.Left, r.Top, 5 * s, r.Height);
            using (var white = new SolidBrush(Theme.White))
            using (var muted = new SolidBrush(Theme.Muted))
            using (var acc = new SolidBrush(Theme.Accent))
            {
                string title = ev.Kind == "motm" ? "MOTM" : (ev.Kind == "goal" ? "GOAL" : "SHOT");
                Draw.Spaced(g, title, _theme.Label, acc, r.Left + 22 * s, r.Top + 12 * s, 1.6f * s);
                Draw.Text(g, "#" + ev.Shirt + "  " + ev.PlayerName, _theme.Value, white,
                          r.Left + 22 * s, r.Top + 32 * s);
                string line = "G " + Fmt0(ev.Goals) + "   A " + Fmt0(ev.Assists) +
                              "   S " + Fmt0(ev.Shots) + "   OT " + Fmt0(ev.OnTarget);
                Draw.TextRight(g, line, _theme.Label, white, r.Right - 22 * s, r.Top + 32 * s);
                Draw.TextRight(g, ev.TeamAbbr + "  " + MinutesText(ev), _theme.Micro, muted,
                               r.Right - 22 * s, r.Top + 54 * s);
            }
        }

        // ---------------------------------------------------------------------
        //  Shared card pieces
        // ---------------------------------------------------------------------
        private void DrawKicker(Graphics g, HudEvent ev, RectangleF r, Color team, float s,
                                bool allowPill)
        {
            using (var acc = new SolidBrush(team))
            using (var white = new SolidBrush(Theme.White))
            using (var gold = new SolidBrush(Theme.Gold))
            {
                float x = r.Left + 34 * s;
                Draw.Spaced(g, ev.TeamAbbr, _theme.Label, acc, x, r.Top + 24 * s, 2.0f * s);
                float off = Draw.SpacedWidth(g, ev.TeamAbbr, _theme.Label, 2.0f * s);
                string label;
                if (ev.Kind == "goal")
                {
                    label = ev.Shot != null && ev.Shot.Outcome == "own_goal" ? "OWN GOAL" : "GOAL";
                }
                else
                {
                    label = "SHOT";
                    if (ev.Shot != null)
                    {
                        if (ev.Shot.Outcome == "on_target") label = "ON TARGET";
                        else if (ev.Shot.Outcome == "off_target") label = "OFF TARGET";
                        else if (ev.Shot.Outcome == "blocked") label = "BLOCKED";
                        else if (ev.Shot.Outcome == "saved") label = "SAVED";
                    }
                }
                Draw.Spaced(g, "   " + label, _theme.Label, white, x + off, r.Top + 24 * s, 2.0f * s);

                if (allowPill && ev.Milestone != null && !string.IsNullOrEmpty(ev.Milestone.Label))
                {
                    bool isGold = ev.Milestone.Tone == "gold";
                    float tw = Draw.SpacedWidth(g, ev.Milestone.Label, _theme.Micro, 1.6f * s);
                    float pw2 = tw + 32 * s;
                    var pill = new RectangleF(r.Right - 34 * s - pw2, r.Top + 18 * s, pw2, 26 * s);
                    using (var fill = new SolidBrush(isGold
                        ? Color.FromArgb(36, Theme.Gold.R, Theme.Gold.G, Theme.Gold.B)
                        : Color.FromArgb(32, Theme.Accent.R, Theme.Accent.G, Theme.Accent.B)))
                        g.FillRectangle(fill, pill);
                    using (var edge = new Pen(isGold ? Theme.Gold : Theme.Accent, 1f))
                        g.DrawRectangle(edge, pill.X, pill.Y, pill.Width, pill.Height);
                    using (var tb = new SolidBrush(isGold ? Theme.Gold : Theme.Accent))
                        Draw.Spaced(g, ev.Milestone.Label, _theme.Micro, tb,
                                    pill.Left + 16 * s, pill.Top + 7 * s, 1.6f * s);
                }
            }
        }

        private void DrawPlayerBlock(Graphics g, HudEvent ev, float x, float y, float maxW,
                                     float s, Color team, double t)
        {
            using (var white = new SolidBrush(Theme.White))
            using (var muted = new SolidBrush(Theme.Muted))
            {
                using (var teamBrush = new SolidBrush(team))
                    Draw.Text(g, "#" + ev.Shirt, _theme.Mid, teamBrush, x, y);
                float numW = Draw.Width(g, "#" + ev.Shirt, _theme.Mid) + 14 * s;
                Draw.TextClipped(g, ev.PlayerName, _theme.Name, white, x + numW, y - 16 * s,
                                 maxW - numW);

                string sub = MinutesText(ev);
                if (!string.IsNullOrEmpty(ev.Pos)) sub = ev.Pos + "   " + sub;
                if (ev.Assist != null && !string.IsNullOrEmpty(ev.Assist.Name))
                    sub += "   ASSIST " + ev.Assist.Name;
                Draw.Spaced(g, sub, _theme.Label, muted, x + numW, y + 46 * s, 1.1f * s);

                if (ev.Rating > 0)
                {
                    string rt = "RATING " + Fmt(ev.Rating, 1);
                    Draw.TextRight(g, rt, _theme.Label, muted, x + maxW, y + 46 * s);
                }
            }
        }

        private void DrawShotCells(Graphics g, HudEvent ev, float x, float y, int count,
                                   float s, Color team, double t, float cellW)
        {
            string[][] cells = count >= 5
                ? new[]
                  {
                      new[] { "GOALS", Fmt0(ev.Goals) }, new[] { "ASSISTS", Fmt0(ev.Assists) },
                      new[] { "SHOTS", Fmt0(ev.Shots) }, new[] { "ON TARGET", Fmt0(ev.OnTarget) },
                      new[] { "MINUTES", MinutesRaw(ev) },
                  }
                : new[]
                  {
                      new[] { "GOALS", Fmt0(ev.Goals) }, new[] { "ASSISTS", Fmt0(ev.Assists) },
                      new[] { "SHOTS", Fmt0(ev.Shots) }, new[] { "ON TARGET", Fmt0(ev.OnTarget) },
                  };

            float slide = (float)Math.Min(1, t * 1.25);
            for (int i = 0; i < cells.Length && i < count; i++)
            {
                Draw.Cell(g, _theme, x + i * cellW, y, cellW - 8 * s,
                          cells[i][0], cells[i][1], i == 0 ? team : Theme.White, s,
                          1.5f * s, slide);
            }
        }

        private void DrawFooter(Graphics g, HudState st, HudEvent ev, RectangleF r, float s, bool analysis)
        {
            using (var muted = new SolidBrush(Color.FromArgb(150, Theme.Muted)))
            using (var gold = new SolidBrush(Theme.Gold))
            {
                if (st != null && !string.IsNullOrEmpty(st.Credit))
                    Draw.Spaced(g, st.Credit, _theme.Micro, gold, r.Left + 34 * s,
                                r.Bottom - 24 * s, 1.6f * s);
                if (analysis && ev.Shot != null)
                {
                    string note = ev.Shot.DistanceSource == "measured"
                        ? "DISTANCE / ANGLE MEASURED" : "DISTANCE ESTIMATED";
                    note += "   -   SPEED MODELLED";
                    Draw.TextRight(g, note, _theme.Micro, muted, r.Right - 34 * s, r.Bottom - 24 * s);
                }
            }
        }

        // ---------------------------------------------------------------------
        //  Shot analysis: mini pitch, trajectory, impact
        // ---------------------------------------------------------------------
        private void DrawAnalysisPanel(Graphics g, RectangleF box, HudEvent ev, Color team,
                                       float s, double elapsed, double t)
        {
            var sh = ev.Shot;
            using (var back = new SolidBrush(Color.FromArgb(96, 4, 6, 9)))
                g.FillRectangle(back, box);
            using (var edge = new Pen(Color.FromArgb(30, 255, 255, 255), 1f))
                g.DrawRectangle(edge, box.X, box.Y, box.Width, box.Height);

            if (sh == null || (sh.OriginX == 0 && sh.OriginY == 0 && sh.Traj.Count == 0))
            {
                using (var muted = new SolidBrush(Theme.Muted))
                    Draw.Spaced(g, "SHOT DATA UNAVAILABLE", _theme.Label, muted,
                                box.Left + 20 * s, box.Top + 20 * s, 1.6f * s);
                return;
            }

            // ---- pitch geometry (attacking third, goal on the right) ----
            float pad = 18 * s;
            var pitch = new RectangleF(box.Left + pad, box.Top + pad,
                                       box.Width - pad * 2, box.Height - pad * 2 - 44 * s);
            double dir = sh.OriginX >= 0 ? 1.0 : -1.0;
            double goalX = 52.5 * dir;
            const double span = 40.0;      // metres of pitch shown behind the goal line
            const double halfW = 24.0;     // metres either side of the goal centre

            Func<double, float> FX = delegate(double xm)
            {
                double u = (goalX - xm) / span * dir;
                if (u < 0) u = 0;
                if (u > 1) u = 1;
                return pitch.Right - (float)u * pitch.Width;
            };
            Func<double, float> FY = delegate(double ym)
            {
                double u = 0.5 + ym / (2 * halfW);
                if (u < 0) u = 0;
                if (u > 1) u = 1;
                return pitch.Top + (float)u * pitch.Height;
            };

            using (var line = new Pen(Color.FromArgb(58, 255, 255, 255), Math.Max(1f, 1.4f * s)))
            {
                g.DrawRectangle(line, pitch.X, pitch.Y, pitch.Width, pitch.Height);
                // penalty box 16.5 m deep, 40.32 m wide
                float px = FX(goalX - 16.5 * dir);
                g.DrawRectangle(line, px, FY(-20.16), pitch.Right - px, FY(20.16) - FY(-20.16));
                // six yard box
                float sx = FX(goalX - 5.5 * dir);
                g.DrawRectangle(line, sx, FY(-9.16), pitch.Right - sx, FY(9.16) - FY(-9.16));
                // penalty spot
                float spotX = FX(goalX - 11 * dir);
                using (var dot = new SolidBrush(Color.FromArgb(90, 255, 255, 255)))
                    g.FillEllipse(dot, spotX - 2 * s, FY(0) - 2 * s, 4 * s, 4 * s);
            }

            // goal mouth + net
            float gy1 = FY(-3.66), gy2 = FY(3.66);
            using (var net = new Pen(Color.FromArgb(46, 255, 255, 255), 1f))
            {
                for (int i = 0; i <= 8; i++)
                {
                    float yy = gy1 + (gy2 - gy1) * i / 8f;
                    g.DrawLine(net, pitch.Right, yy, pitch.Right + 14 * s, yy - 6 * s);
                }
                for (int i = 0; i <= 4; i++)
                {
                    float xx = pitch.Right + 14 * s * i / 4f;
                    g.DrawLine(net, xx, gy1 - 6 * s * i / 4f, xx, gy2 - 6 * s * i / 4f);
                }
            }
            using (var post = new Pen(Theme.White, Math.Max(1.5f, 2.4f * s)))
            {
                g.DrawLine(post, pitch.Right, gy1, pitch.Right, gy2);
            }

            // ---- trajectory ----
            var pts = new List<PointF>();
            if (sh.Traj.Count >= 2)
            {
                foreach (var p in sh.Traj) pts.Add(new PointF(FX(p[0]), FY(p[1])));
            }
            else
            {
                pts.Add(new PointF(FX(sh.OriginX), FY(sh.OriginY)));
                pts.Add(new PointF(pitch.Right, FY(sh.TargetX)));
            }

            double flight = Math.Max(0.0, Math.Min(1.0, (elapsed - 0.35) / 1.9));
            flight = flight * flight * (3 - 2 * flight);

            using (var ghost = new Pen(Color.FromArgb(70, 255, 255, 255), Math.Max(1f, 1.6f * s)))
            {
                for (int i = 1; i < pts.Count; i++) g.DrawLine(ghost, pts[i - 1], pts[i]);
            }
            DrawPolyline(g, pts, flight, team, s);

            // impact marker
            if (flight > 0.02)
            {
                float ix = pitch.Right;
                float iy = FY(sh.TargetX);
                float pulse = (float)Math.Min(1.0, flight * 1.2);
                using (var ring = new Pen(Color.FromArgb((int)(200 * pulse), team), Math.Max(1.4f, 2 * s)))
                    g.DrawEllipse(ring, ix - 9 * s * pulse, iy - 9 * s * pulse,
                                  18 * s * pulse, 18 * s * pulse);
            }

            // ball marker
            PointF ball = PointAlong(pts, flight);
            using (var fill = new SolidBrush(Theme.White))
                g.FillEllipse(fill, ball.X - 4.2f * s, ball.Y - 4.2f * s, 8.4f * s, 8.4f * s);
            using (var glow = new SolidBrush(Color.FromArgb(70, team)))
                g.FillEllipse(glow, ball.X - 9 * s, ball.Y - 9 * s, 18 * s, 18 * s);

            // ---- numbers ----
            float ny = box.Bottom - 40 * s;
            float nw = box.Width / 4f;
            string[][] chips =
            {
                new[] { "DISTANCE", DistText(sh) },
                new[] { "ANGLE", Fmt0(sh.AngleDeg) + " DEG" },
                new[] { "SPEED", "~ " + SpeedText(sh) },
                new[] { "xG", Fmt(sh.Xg, 2) },
            };
            using (var muted = new SolidBrush(Theme.Muted))
            using (var white = new SolidBrush(Theme.White))
            {
                for (int i = 0; i < chips.Length; i++)
                {
                    float x = box.Left + 20 * s + i * (nw - 6 * s);
                    Draw.Spaced(g, chips[i][0], _theme.Micro, muted, x, ny, 1.2f * s);
                    Draw.Text(g, chips[i][1], _theme.Title, white, x, ny + 14 * s);
                }
            }
            using (var acc = new SolidBrush(Color.FromArgb(120, team)))
            {
                float oy = FY(sh.OriginY);
                float ox = FX(sh.OriginX);
                g.FillEllipse(acc, ox - 5 * s, oy - 5 * s, 10 * s, 10 * s);
            }
        }

        private static void DrawPolyline(Graphics g, List<PointF> pts, double progress,
                                         Color team, float s)
        {
            if (pts.Count < 2 || progress <= 0) return;
            float total = 0f;
            for (int i = 1; i < pts.Count; i++) total += Dist(pts[i - 1], pts[i]);
            if (total <= 0) return;

            float want = (float)progress * total;
            float run = 0f;
            using (var pen = new Pen(Theme.Accent, Math.Max(1.6f, 2.4f * s)))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                for (int i = 1; i < pts.Count; i++)
                {
                    float seg = Dist(pts[i - 1], pts[i]);
                    if (run + seg <= want)
                    {
                        g.DrawLine(pen, pts[i - 1], pts[i]);
                        run += seg;
                    }
                    else
                    {
                        float f = seg > 0 ? (want - run) / seg : 1f;
                        var p = new PointF(pts[i - 1].X + (pts[i].X - pts[i - 1].X) * f,
                                           pts[i - 1].Y + (pts[i].Y - pts[i - 1].Y) * f);
                        g.DrawLine(pen, pts[i - 1], p);
                        break;
                    }
                }
            }
            using (var tip = new SolidBrush(Color.FromArgb(120, team)))
            {
                var p = PointAlong(pts, progress);
                g.FillEllipse(tip, p.X - 3 * s, p.Y - 3 * s, 6 * s, 6 * s);
            }
        }

        private static float Dist(PointF a, PointF b)
        {
            float dx = b.X - a.X, dy = b.Y - a.Y;
            return (float)Math.Sqrt(dx * dx + dy * dy);
        }

        private static PointF PointAlong(List<PointF> pts, double progress)
        {
            if (pts.Count == 0) return PointF.Empty;
            if (pts.Count == 1) return pts[0];
            float total = 0f;
            for (int i = 1; i < pts.Count; i++) total += Dist(pts[i - 1], pts[i]);
            if (total <= 0) return pts[0];
            float want = (float)Math.Max(0, Math.Min(1, progress)) * total;
            float run = 0f;
            for (int i = 1; i < pts.Count; i++)
            {
                float seg = Dist(pts[i - 1], pts[i]);
                if (run + seg < want)
                {
                    run += seg;
                    continue;
                }
                float f = seg > 0 ? (want - run) / seg : 1f;
                return new PointF(pts[i - 1].X + (pts[i].X - pts[i - 1].X) * f,
                                  pts[i - 1].Y + (pts[i].Y - pts[i - 1].Y) * f);
            }
            return pts[pts.Count - 1];
        }


        // ---------------------------------------------------------------------
        //  5. Toast channel (hotkeys, assists, hat-tricks)
        // ---------------------------------------------------------------------
        private void DrawToast(Graphics g, ToastState toast, double elapsed, int w, float s)
        {
            double hold = Math.Max(1.0, toast.Hold);
            double inT = Math.Min(1.0, elapsed / 0.30);
            double outT = Math.Min(1.0, (hold - elapsed) / 0.45);
            double t = Math.Max(0.0, Math.Min(inT, outT));
            if (t <= 0.001) return;

            Color accent = Theme.Accent;
            if (toast.Kind == "milestone" || toast.Kind == "assist") accent = Theme.Gold;
            if (toast.Kind == "toggle") accent = Theme.Green;

            float tw = Draw.SpacedWidth(g, toast.Text, _theme.Label, 1.8f * s);
            float pw = Math.Max(300 * s, tw + 92 * s);
            float ph = 62 * s;
            float px = (w - pw) / 2f;
            float py = 96 * s - (float)((1.0 - Ease(t)) * 18 * s);
            var r = new RectangleF(px, py, pw, ph);

            using (var back = new SolidBrush(Color.FromArgb((int)(228 * t), 12, 15, 20)))
                g.FillRectangle(back, r);
            using (var bar = new SolidBrush(Color.FromArgb((int)(255 * t), accent)))
                g.FillRectangle(bar, r.Left, r.Top, 5 * s, r.Height);
            using (var edge = new Pen(Color.FromArgb((int)(60 * t), 255, 255, 255), 1f))
                g.DrawRectangle(edge, r.X, r.Y, r.Width, r.Height);
            using (var tb = new SolidBrush(Color.FromArgb((int)(255 * t), Theme.White)))
                Draw.Spaced(g, toast.Text, _theme.Label, tb, r.Left + 26 * s,
                            r.Top + (ph - _theme.Label.Size) * 0.42f, 1.8f * s);
            using (var sb = new SolidBrush(Color.FromArgb((int)(190 * t), accent)))
                Draw.Spaced(g, "MOONFROS", _theme.Micro, sb, r.Right - 26 * s -
                            Draw.SpacedWidth(g, "MOONFROS", _theme.Micro, 1.4f * s),
                            r.Top + (ph - _theme.Micro.Size) * 0.42f, 1.4f * s);
        }

        // ---------------------------------------------------------------------
        //  Optional score bug + diagnostics
        // ---------------------------------------------------------------------
        private void DrawScoreBug(Graphics g, HudState st, int w, int h, float s)
        {
            float pw = 372 * s, ph = 60 * s;
            var r = new RectangleF(52 * s, 44 * s, pw, ph);
            Draw.GlassPanel(g, r, 6 * s, Draw.ParseColor(st.Home.Color, Theme.Accent));
            using (var white = new SolidBrush(Theme.White))
            using (var muted = new SolidBrush(Theme.Muted))
            using (var acc = new SolidBrush(Theme.Accent))
            {
                Draw.Text(g, st.Home.Abbr, _theme.Value, white, r.Left + 24 * s, r.Top + 14 * s);
                Draw.TextRight(g, st.Away.Abbr, _theme.Value, white, r.Right - 24 * s, r.Top + 14 * s);
                string score = st.Home.Score + " - " + st.Away.Score;
                Draw.TextCentre(g, score, _theme.Value, acc, r.Left + pw / 2f, r.Top + 14 * s);
                Draw.Spaced(g, st.Clock, _theme.Micro, muted, r.Left + 24 * s, r.Top + 2 * s, 1.2f * s);
            }
        }

        private void DrawDiagnostics(Graphics g, HudState st, int w, int h, float s)
        {
            float pw = 560 * s, ph = 330 * s;
            var r = new RectangleF(w - pw - 40 * s, 40 * s, pw, ph);
            Draw.GlassPanel(g, r, 8 * s, Theme.Accent);
            using (var white = new SolidBrush(Theme.White))
            using (var muted = new SolidBrush(Theme.Muted))
            using (var acc = new SolidBrush(Theme.Accent))
            using (var red = new SolidBrush(Theme.Red))
            {
                Draw.Spaced(g, "NEXT-GEN BROADCAST  -  DIAGNOSTICS", _theme.Label, acc,
                            r.Left + 26 * s, r.Top + 18 * s, 1.8f * s);
                string[] rows;
                if (st == null)
                {
                    rows = new[] { "state.json   :  not found", "game window  :  searching" };
                }
                else
                {
                    string[] styles = { "full", "compact", "minimal" };
                    rows = new[]
                    {
                        "state.json   :  OK  (seq " + st.Seq + ")",
                        "presentation :  " + (st.Master ? "on" : "OFF"),
                        "style        :  " + styles[Math.Max(0, Math.Min(2, st.Style))],
                        "shot analysis:  " + (st.Analysis ? "on" : "off"),
                        "lua ffi      :  " + (st.Ffi ? "on" : "OFF  (luajit.ext.enabled = 1)"),
                        "stat region  :  " + (st.StatsRegion ? "found" : "not found"),
                        "pitch region :  " + (st.PitchRegion ? "found" : "not found"),
                        "replay cam   :  " + (st.CameraOk ? "patched" : "vanilla"),
                        "player names :  " + (st.PlayerDb ? "Player.bin" : "fallback"),
                        "cards seen   :  " + st.EventCount,
                        "match clock  :  " + st.Clock,
                        "units        :  " + st.Units,
                    };
                }
                float yy = r.Top + 52 * s;
                foreach (var row in rows)
                {
                    var brush = row.Contains("OFF") || row.Contains("not found") ? red : white;
                    Draw.Text(g, row, _theme.Label, brush, r.Left + 26 * s, yy);
                    yy += 21 * s;
                }
                Draw.Text(g, "F10 demo   F11 close   F12 quit   (in game: 7 / 8 / 9)", _theme.Micro,
                          muted, r.Left + 26 * s, r.Bottom - 26 * s);
            }
        }

        // ---------------------------------------------------------------------
        //  Demo events (F10) so the HUD can be checked without playing
        // ---------------------------------------------------------------------
        private HudEvent BuildDemoEvent(HudState st, float s)
        {
            var e = new HudEvent();
            e.Id = 900000 + _demoPhase;
            e.Duration = 20;
            e.Remaining = e.Duration - (_clock.Elapsed.TotalSeconds % e.Duration);
            e.Side = "home";
            e.TeamName = st != null ? st.Home.Name : "ARSENAL";
            e.TeamAbbr = st != null ? st.Home.Abbr : "ARS";
            e.TeamColor = st != null ? st.Home.Color : "#EF0107";
            e.Minutes = 67;
            e.MinutesExact = true;
            e.Rating = 8.4;
            e.Shots = 4;
            e.OnTarget = 3;
            e.Goals = 2;
            e.Assists = 1;
            e.Ga = 3;
            e.Passes = 34;
            e.PassPct = 88;
            e.Touches = 61;
            e.TacklesOk = 2;

            if (_demoPhase == 1)
            {
                e.Kind = "goal";
                e.PlayerName = "M. ODEGAARD";
                e.Shirt = 8;
                e.Pos = "CMF";
                e.Goals = 3;
                e.Ga = 4;
                e.Milestone = new MilestoneState { Key = "hat_trick", Label = "HAT-TRICK", Tone = "gold" };
                e.Assist = new AssistState { Name = "B. SAKA", Shirt = 7 };
                e.Shot = DemoTel(0.42);
            }
            else if (_demoPhase == 2)
            {
                e.Kind = "shot";
                e.PlayerName = "B. SAKA";
                e.Shirt = 7;
                e.Pos = "RWF";
                e.Goals = 1;
                e.Shots = 3;
                e.OnTarget = 1;
                e.Assists = 1;
                e.Shot = DemoTel(0.14);
                e.Shot.Outcome = "off_target";
            }
            else
            {
                e.Kind = "motm";
                e.PlayerName = "B. SAKA";
                e.Shirt = 7;
                e.Pos = "RWF";
                e.Rating = 8.9;
                e.ScoreLine = "ARSENAL 2 - 1 CHELSEA";
                e.Motm = new MotmStats
                {
                    Goals = 2,
                    Assists = 1,
                    Ga = 3,
                    Shots = 5,
                    OnTarget = 4,
                    Passes = 34,
                    PassesOk = 30,
                    PassPct = 88,
                    Tackles = 3,
                    TacklesOk = 2,
                    DribblesOk = 4,
                    Touches = 61,
                    Saves = 0,
                    Interceptions = 1,
                    PeakMph = 78.4,
                    Xg = 1.12
                };
            }
            return e;
        }

        private ShotState DemoTel(double xg)
        {
            var sh = new ShotState();
            sh.SpeedMph = 74.2;
            sh.SpeedKmh = 119.4;
            sh.DistanceM = 18.4;
            sh.DistanceYd = 20.1;
            sh.AngleDeg = 21.4;
            sh.ElevationDeg = 8.2;
            sh.ApexM = 1.9;
            sh.ApexFt = 6.2;
            sh.HangS = 0.92;
            sh.Xg = xg;
            sh.TargetX = 1.4;
            sh.TargetY = 1.6;
            sh.OriginX = 34.1;
            sh.OriginY = 9.5;
            sh.Outcome = "goal";
            sh.Body = "right_foot";
            sh.Source = "measured";
            sh.SpeedSource = "modelled";
            sh.DistanceSource = "measured";
            for (int i = 0; i <= 15; i++)
            {
                double f = i / 15.0;
                double x = sh.OriginX + (52.5 - sh.OriginX) * f;
                double y = sh.OriginY + (0 - sh.OriginY) * f;
                double z = Math.Sin(f * Math.PI) * 1.9;
                sh.Traj.Add(new[] { x, y, z });
            }
            return sh;
        }

        // ---------------------------------------------------------------------
        //  Text helpers
        // ---------------------------------------------------------------------
        private string MinutesText(HudEvent ev)
        {
            return "MIN " + MinutesRaw(ev);
        }

        private string MinutesRaw(HudEvent ev)
        {
            string rough = ev.MinutesExact ? "" : "~";
            return rough + Fmt0(ev.Minutes) + "'";
        }

        private string DistText(ShotState sh)
        {
            bool metric = string.Equals(_theme.UnitDist, "M", StringComparison.OrdinalIgnoreCase);
            return Fmt(metric ? sh.DistanceM : sh.DistanceYd, 1) + " " + _theme.UnitDist;
        }

        private string SpeedText(ShotState sh)
        {
            bool metric = string.Equals(_theme.UnitSpeed, "KM/H", StringComparison.OrdinalIgnoreCase);
            return Fmt(metric ? sh.SpeedKmh : sh.SpeedMph, 0) + " " + _theme.UnitSpeed;
        }

        private static double Anim(double elapsed, double remaining)
        {
            double inT = Math.Min(1.0, elapsed / 0.45);
            double outT = Math.Min(1.0, remaining / 0.55);
            return Math.Min(inT, outT);
        }

        private static double Ease(double t)
        {
            t = Math.Max(0, Math.Min(1, t));
            return t * t * (3 - 2 * t);
        }

        private static string Fmt(double v, int dec)
        {
            return v.ToString("F" + dec, CultureInfo.InvariantCulture);
        }

        private static string Fmt0(double v)
        {
            return ((int)Math.Round(v)).ToString(CultureInfo.InvariantCulture);
        }
    }

    // =========================================================================
    //  Entry point
    // =========================================================================
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            try { Native.SetProcessDPIAware(); } catch { }
            try { Native.SetCurrentProcessExplicitAppUserModelID("MoonFros.NGB.Presentation"); }
            catch { }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string state = LocateStateFile(args);
            Application.Run(new OverlayForm(state));
        }

        private static string LocateStateFile(string[] args)
        {
            if (args != null && args.Length > 0 && !string.IsNullOrEmpty(args[0]))
                return args[0];

            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string[] candidates =
            {
                Path.Combine(exeDir, @"..\content\ngb-presentation\state.json"),
                Path.Combine(exeDir, @"content\ngb-presentation\state.json"),
                Path.Combine(exeDir, @"..\..\content\ngb-presentation\state.json"),
                Path.Combine(exeDir, @"..\..\sider\content\ngb-presentation\state.json"),
            };
            foreach (var c in candidates)
            {
                try
                {
                    string full = Path.GetFullPath(c);
                    if (File.Exists(full)) return full;
                }
                catch { }
            }
            try { return Path.GetFullPath(candidates[0]); }
            catch { return candidates[0]; }
        }
    }
}
