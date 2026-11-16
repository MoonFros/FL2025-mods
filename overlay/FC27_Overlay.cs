// =============================================================================
//  EA FC 27 HyperMotion Broadcast HUD  (FC27_Overlay.cs)
//
//  Transparent, click-through, always-on-top overlay for
//  PES 2021 / SmokePatch Football Life 2025 (FL_2025.exe v1.0).
//
//  Reads  ..\content\fc27-broadcast\state.json  (written by the Sider Lua
//  module modules\FC27_Broadcast.lua) and paints three EA FC style broadcast
//  graphics with per-pixel alpha:
//
//     1. GOAL  - HyperMotion goal card with live shot telemetry
//                (speed / distance / angle / xG / apex / hang time) plus a
//                shot trajectory diagram.
//     2. SHOT  - goal / miss / save player popup with the player's match
//                totals: shots, shots on target, goals, assists, G/A.
//     3. MOTM  - post-match Man of the Match card with the full stat grid.
//
//  Build (no SDK required, .NET Framework 4.x ships with Windows 10/11):
//     %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
//         /target:winexe /optimize+ /platform:x64
//         /out:FC27_Overlay.exe FC27_Overlay.cs
//         /reference:System.dll /reference:System.Drawing.dll
//         /reference:System.Windows.Forms.dll
//         /win32manifest:app.manifest
//
//  Hotkeys:  F8 = cycle demo card   F9 = diagnostics   F12 = quit
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
using System.Threading;
using System.Windows.Forms;

namespace Fc27Broadcast
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
    //  State model
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
        public string Outcome = "", Body = "", Source = "";
        public List<double[]> Traj = new List<double[]>();
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
        public double Rating;
        public string TeamName = "", TeamAbbr = "", TeamColor = "#AEFF00";
        public double Shots, OnTarget, Goals, Assists, Ga, Passes, PassPct;
        public double TacklesOk, DribblesOk, Touches, Saves;
        public ShotState Shot;
        public MotmStats Motm;
        public string ScoreLine = "";
    }

    internal sealed class HudState
    {
        public int Seq;
        public string Units = "imperial";
        public bool ScoreBug;
        public bool Ffi, StatsRegion, PitchRegion, CameraOk, PlayerDb;
        public string NamesSource = "";
        public int EventCount;
        public string Clock = "";
        public TeamState Home = new TeamState(), Away = new TeamState();
        public HudEvent Event;
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
            st.Units = S(hud, "units", "imperial");
            st.ScoreBug = B(hud, "scorebug", false);

            var status = D(root, "status");
            st.Ffi = B(status, "ffi", false);
            st.StatsRegion = B(status, "stats_region", false);
            st.PitchRegion = B(status, "pitch_region", false);
            st.CameraOk = B(status, "camera", false);
            st.PlayerDb = B(status, "player_db", false);
            st.NamesSource = S(status, "names", "");
            st.EventCount = I(status, "events", 0);

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

                var t = D(ev, "team");
                e.TeamName = S(t, "name", "");
                e.TeamAbbr = S(t, "abbr", "");
                e.TeamColor = S(t, "color", "#AEFF00");

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
                    var ms = D(motm, "stats");
                    var mm = new MotmStats();
                    mm.Goals = N(ms, "goals", 0);
                    mm.Assists = N(ms, "assists", 0);
                    mm.Ga = N(ms, "ga", 0);
                    mm.Shots = N(ms, "shots", 0);
                    mm.OnTarget = N(ms, "on_target", 0);
                    mm.Passes = N(ms, "passes", 0);
                    mm.PassesOk = N(ms, "passes_ok", 0);
                    mm.PassPct = N(ms, "pass_pct", 0);
                    mm.Tackles = N(ms, "tackles", 0);
                    mm.TacklesOk = N(ms, "tackles_ok", 0);
                    mm.DribblesOk = N(ms, "dribbles_ok", 0);
                    mm.Touches = N(ms, "touches", 0);
                    mm.Saves = N(ms, "saves", 0);
                    mm.Interceptions = N(ms, "interceptions", 0);
                    mm.PeakMph = N(ms, "peak_mph", 0);
                    mm.Xg = N(ms, "xg", 0);
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
    // =========================================================================
    internal sealed class Theme
    {
        public static readonly Color Volt = Color.FromArgb(255, 174, 255, 0);
        public static readonly Color VoltDim = Color.FromArgb(120, 174, 255, 0);
        public static readonly Color Ink = Color.FromArgb(255, 8, 11, 15);
        public static readonly Color Glass1 = Color.FromArgb(242, 10, 14, 19);
        public static readonly Color Glass2 = Color.FromArgb(232, 18, 24, 31);
        public static readonly Color White = Color.FromArgb(255, 255, 255, 255);
        public static readonly Color Muted = Color.FromArgb(210, 154, 166, 178);
        public static readonly Color Cyan = Color.FromArgb(255, 0, 224, 255);
        public static readonly Color Red = Color.FromArgb(255, 255, 69, 58);

        public string UnitSpeed = "MPH";
        public string UnitDist = "YD";
        public string UnitHeight = "FT";

        public Font Big, Huge, Name, NameSmall, Label, Value, ValueBig, Tiny, Mid, Title;

        public void ApplyUnits(HudState st)
        {
            bool metric = st != null && string.Equals(st.Units, "metric", StringComparison.OrdinalIgnoreCase);
            UnitSpeed = metric ? "KM/H" : "MPH";
            UnitDist = metric ? "M" : "YD";
            UnitHeight = metric ? "M" : "FT";
        }

        public static float Speed(double mph, double kmh, bool metric)
        {
            return (float)(metric ? kmh : mph);
        }

        public void Build(float s)
        {
            Dispose();
            string famBig = PickFamily("Bahnschrift SemiCondensed", "Bahnschrift", "Segoe UI Semibold", "Arial");
            string famText = PickFamily("Segoe UI Semibold", "Segoe UI", "Arial");
            Big = new Font(famBig, 76f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Huge = new Font(famBig, 108f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Name = new Font(famBig, 52f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            NameSmall = new Font(famBig, 40f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Mid = new Font(famBig, 32f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Title = new Font(famText, 20f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Label = new Font(famText, 15f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Value = new Font(famBig, 30f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            ValueBig = new Font(famBig, 44f * s, FontStyle.Bold, GraphicsUnit.Pixel);
            Tiny = new Font(famText, 13f * s, FontStyle.Regular, GraphicsUnit.Pixel);
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
            Font[] all = { Big, Huge, Name, NameSmall, Mid, Title, Label, Value, ValueBig, Tiny };
            foreach (var f in all) if (f != null) f.Dispose();
            Big = Huge = Name = NameSmall = Mid = Title = Label = Value = ValueBig = Tiny = null;
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

        public static void GlassPanel(Graphics g, RectangleF r, float skew, Color teamColor)
        {
            using (var path = Skew(r, skew))
            using (var b = new LinearGradientBrush(
                new RectangleF(r.X, r.Y, r.Width, r.Height + 1),
                Theme.Glass1, Theme.Glass2, LinearGradientMode.Vertical))
            {
                g.FillPath(b, path);
                using (var edge = new Pen(Color.FromArgb(46, 255, 255, 255), Math.Max(1f, r.Height * 0.004f)))
                    g.DrawPath(edge, path);
            }
            // left accent bar: volt -> team colour
            var bar = new RectangleF(r.Left, r.Top, Math.Max(5f, r.Height * 0.03f), r.Height);
            using (var b2 = new LinearGradientBrush(bar, Theme.Volt, teamColor, LinearGradientMode.Vertical))
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

        public static void Pill(Graphics g, RectangleF r, Color fill, string text, Font f, Color txt)
        {
            using (var path = new GraphicsPath())
            {
                float d = r.Height * 0.35f;
                path.AddArc(r.Left, r.Top, d, r.Height, 90, 180);
                path.AddArc(r.Right - d, r.Top, d, r.Height, 270, 180);
                path.CloseFigure();
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
            }
            using (var tb = new SolidBrush(txt))
            {
                float tw = Width(g, text, f);
                Text(g, text, f, tb, r.Left + (r.Width - tw) / 2f, r.Top + (r.Height - f.Size) * 0.42f);
            }
        }

        public static void AccentLine(Graphics g, float x, float y, float w, float h, float p)
        {
            using (var b = new SolidBrush(Color.FromArgb(90, 255, 255, 255)))
                g.FillRectangle(b, x, y, w, h);
            using (var b = new SolidBrush(Theme.Volt))
                g.FillRectangle(b, x, y, w * Math.Max(0f, Math.Min(1f, p)), h);
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
        private const int HOTKEY_DEMO = 0xB001;
        private const int HOTKEY_DIAG = 0xB002;
        private const int HOTKEY_QUIT = 0xB003;

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

        public OverlayForm(string statePath)
        {
            _statePath = statePath;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            Bounds = new Rectangle(0, 0, 1, 1);
            BackColor = Color.Black;
            Name = "FC27Overlay";

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
            Native.RegisterHotKey(Handle, HOTKEY_DEMO, 0, (uint)Keys.F8);
            Native.RegisterHotKey(Handle, HOTKEY_DIAG, 0, (uint)Keys.F9);
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
            _logPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "FC27_Overlay.log");
            Log("overlay starting; state = " + _statePath);
            TryReadState(true);
            _timer.Start();
        }

        private void Log(string s)
        {
            try
            {
                var fi = new FileInfo(_logPath ?? "FC27_Overlay.log");
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
            string[] wanted = { "FL_2025", "PES2021", "FL2025" };
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

            // never float above the desktop / other apps: only draw when the
            // game is the foreground application
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
            try
            {
                Tick();
            }
            catch (Exception ex)
            {
                Log("tick error: " + ex.Message);
            }
        }

        private void Tick()
        {
            ProbeGameWindow();
            TryReadState(false);

            HudState st = _state;
            if (st == null && _demoPhase == 0 && !_diag) { if (Visible) Hide(); return; }
            if (!ComputeGameRect()) { if (Visible) Hide(); return; }

            float s = Math.Max(0.35f, Math.Min(2.6f, _winH / 1080f));
            if (_theme.Big == null || Math.Abs(_theme.Big.Size - 76f * s) > 0.5f)
                _theme.Build(s);

            if (Location.X != _winX || Location.Y != _winY ||
                _rt.Width != _winW || _rt.Height != _winH)
                Bounds = new Rectangle(_winX, _winY, _winW, _winH);
            _rt.Resize(_winW, _winH);

            // ---- which event is on screen right now? ----
            HudEvent ev = null;
            double elapsed = 0, remaining = 0;

            if (_demoPhase != 0)
            {
                const double cycle = 18.0;
                double since = _clock.Elapsed.TotalSeconds - _demoStart;
                double tt = since % cycle;
                ev = BuildDemoEvent(st, s);
                ev.Duration = cycle;
                ev.Remaining = cycle - tt;
                elapsed = tt;
                remaining = ev.Remaining;
            }
            else if (st != null && st.Event != null && st.Event.Remaining > 0)
            {
                ev = st.Event;
                remaining = ev.Remaining;
                long key = (long)ev.Id * 31 + ev.Kind.GetHashCode();
                if (key != _lastEventKey) { _lastEventKey = key; _eventFirstSeen = _clock.Elapsed.TotalSeconds; }
                elapsed = Math.Max(0, _clock.Elapsed.TotalSeconds - _eventFirstSeen);
            }

            bool anything = ev != null || (st != null && st.ScoreBug) || _diag;
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
                    case "goal": DrawGoal(g, ev, st, _winW, _winH, s, elapsed, remaining); break;
                    case "shot": DrawShot(g, ev, st, _winW, _winH, s, elapsed, remaining); break;
                    case "motm": DrawMotm(g, ev, st, _winW, _winH, s, elapsed, remaining); break;
                }
            }
            if (_diag) DrawDiagnostics(g, st, _winW, _winH, s);

            _rt.Present(Handle, _winX, _winY);
        }

        // ---------------------------------------------------------------------
        //  1. GOAL card
        // ---------------------------------------------------------------------
        private void DrawGoal(Graphics g, HudEvent ev, HudState st, int w, int h, float s,
                              double elapsed, double remaining)
        {
            double t = Anim(elapsed, remaining);
            if (t <= 0.001) return;
            Color team = Draw.ParseColor(ev.TeamColor, Theme.Volt);

            float alpha = (float)Math.Min(1.0, t * 1.4);
            float slide = (float)((1.0 - Ease(t)) * 46 * s);

            float pw = 1240 * s, ph = 300 * s;
            float px = 56 * s;
            float py = h - 56 * s - ph + slide;
            if (py < 20 * s) py = 20 * s;

            var panel = new RectangleF(px, py, pw, ph);
            Draw.GlassPanel(g, panel, 12 * s, team);

            using (var white = new SolidBrush(Color.FromArgb((int)(255 * alpha), 255, 255, 255)))
            using (var volt = new SolidBrush(Color.FromArgb((int)(255 * alpha), Theme.Volt)))
            using (var muted = new SolidBrush(Color.FromArgb((int)(215 * alpha), 154, 166, 178)))
            using (var faint = new SolidBrush(Color.FromArgb((int)(120 * alpha), 220, 226, 232)))
            {
                float x = px + 40 * s;
                float y = py + 18 * s;

                // "GOAL" + minute pill
                Draw.Text(g, "GOAL", _theme.Big, volt, x, y - 6 * s);
                float gw = Draw.Width(g, "GOAL", _theme.Big);
                string minute = st != null ? MinutesOnly(st.Clock) : "";
                if (minute.Length > 0)
                {
                    var pill = new RectangleF(x + gw + 22 * s, y + 16 * s, 78 * s, 40 * s);
                    Draw.Pill(g, pill, team, minute, _theme.Mid, Theme.White);
                }

                // scorer
                string name = string.IsNullOrEmpty(ev.PlayerName) ? "GOALSCORER" : ev.PlayerName;
                Draw.TextClipped(g, name, _theme.Name, white, x, y + 78 * s, pw - 480 * s);

                // meta line
                string meta = "#" + ev.Shirt + "  " +
                              (string.IsNullOrEmpty(ev.Pos) ? "" : ev.Pos + "  ") +
                              (string.IsNullOrEmpty(ev.TeamAbbr) ? "" : ev.TeamAbbr);
                Draw.Spaced(g, meta.Trim(), _theme.Label, muted, x + 2 * s, y + 142 * s, 1.6f * s);

                // stat strip
                ShotState sh = ev.Shot;
                string[] labels = { "SPEED", "DISTANCE", "ANGLE", "xG", "APEX", "HANG" };
                string[] values = new string[6];
                bool metric = st != null && st.Units == "metric";
                if (sh != null)
                {
                    values[0] = Fmt(metric ? sh.SpeedKmh : sh.SpeedMph, 1) + " " + _theme.UnitSpeed;
                    values[1] = Fmt(metric ? sh.DistanceM : sh.DistanceYd, 1) + " " + _theme.UnitDist;
                    values[2] = Fmt(sh.AngleDeg, 1) + "\u00B0";
                    values[3] = Fmt(sh.Xg, 2);
                    values[4] = Fmt(metric ? sh.ApexM : sh.ApexFt, 1) + " " + _theme.UnitHeight;
                    values[5] = Fmt(sh.HangS, 2) + "s";
                }
                else
                {
                    values[0] = "-"; values[1] = "-"; values[2] = "-";
                    values[3] = "-"; values[4] = "-"; values[5] = "-";
                }
                float cy = py + 196 * s;
                float cellW = 112 * s;
                for (int i = 0; i < 6; i++)
                {
                    float cx = x + i * cellW;
                    Draw.Spaced(g, labels[i], _theme.Tiny, muted, cx, cy, 1.2f * s);
                    Draw.Text(g, values[i], _theme.Value, i == 0 ? volt : white, cx, cy + 18 * s);
                }

                // possession-style progress / remaining bar
                if (ev.Duration > 0)
                {
                    float prog = (float)Math.Max(0, Math.Min(1, ev.Remaining / ev.Duration));
                    Draw.AccentLine(g, px + 40 * s, py + ph - 16 * s, pw - 80 * s, 3.2f * s, prog);
                }

                // ---- trajectory diagram (right side) ----
                if (sh != null && sh.Traj.Count > 2)
                {
                    var box = new RectangleF(px + pw - 392 * s, py + 22 * s, 360 * s, 254 * s);
                    DrawTrajectory(g, sh, box, s, alpha, team, volt, muted, faint);
                }
                else
                {
                    string outcome = sh != null ? sh.Outcome.ToUpperInvariant() : "GOAL";
                    Draw.TextRight(g, outcome, _theme.Mid, faint, px + pw - 40 * s, py + 40 * s);
                }

                // small branding
                using (var brand = new SolidBrush(Color.FromArgb((int)(130 * alpha), 174, 255, 0)))
                    Draw.Spaced(g, "HYPERMOTION  TELEMETRY", _theme.Tiny, brand,
                                px + 40 * s, py + ph - 34 * s, 2.4f * s);
            }
        }

        private void DrawTrajectory(Graphics g, ShotState sh, RectangleF box, float s,
                                    float alpha, Color team, Brush volt, Brush muted, Brush faint)
        {
            using (var p = Draw.Skew(box, 6 * s))
            using (var b = new SolidBrush(Color.FromArgb((int)(120 * alpha), 4, 8, 12)))
                g.FillPath(b, p);

            float padL = 14 * s, padR = 16 * s, padB = 26 * s, padT = 18 * s;
            float gx0 = box.Left + padL, gx1 = box.Right - padR;
            float gy0 = box.Bottom - padB, gy1 = box.Top + padT;
            float gw = gx1 - gx0, gh = gy0 - gy1;

            // grid
            using (var pen = new Pen(Color.FromArgb((int)(30 * alpha), 255, 255, 255), 1f))
            {
                for (int i = 1; i <= 3; i++)
                {
                    float yy = gy1 + gh * i / 4f;
                    g.DrawLine(pen, gx0, yy, gx1, yy);
                }
            }

            // pitch baseline
            using (var pen = new Pen(Color.FromArgb((int)(150 * alpha), 120, 130, 140), 1.2f * s))
                g.DrawLine(pen, gx0, gy0, gx1, gy0);

            // goal frame (2.44 m high) on the right
            double maxH = Math.Max(2.6, sh.ApexM > 0 ? sh.ApexM * 1.15 : 2.6);
            float gpost = gy0 - (float)(2.44 / maxH) * gh;
            using (var pen = new Pen(Color.FromArgb((int)(220 * alpha), 235, 240, 245), 2.4f * s))
            {
                g.DrawLine(pen, gx1, gy0, gx1, gpost);
                g.DrawLine(pen, gx1, gpost, gx1 - 10 * s, gpost);
            }

            // trajectory polyline, side elevation (distance vs height)
            double ox = sh.OriginX, oy = sh.OriginY;
            var pts = new List<PointF>();
            double maxD = Math.Max(1.0, sh.DistanceM);
            for (int i = 0; i < sh.Traj.Count; i++)
            {
                double tx = sh.Traj[i][0], ty = sh.Traj[i][1], tz = sh.Traj[i][2];
                double d = Math.Sqrt((tx - ox) * (tx - ox) + (ty - oy) * (ty - oy));
                float fx = gx0 + (float)(d / maxD) * gw;
                float fy = gy0 - (float)(tz / maxH) * gh;
                pts.Add(new PointF(fx, fy));
            }
            if (pts.Count > 2)
            {
                using (var pen = new Pen(Color.FromArgb((int)(235 * alpha), Theme.Volt), 2.8f * s))
                {
                    pen.LineJoin = LineJoin.Round;
                    g.DrawLines(pen, pts.ToArray());
                }
                // fading trail
                using (var b = new SolidBrush(Color.FromArgb((int)(255 * alpha), 255, 255, 255)))
                {
                    var last = pts[pts.Count - 1];
                    g.FillEllipse(b, last.X - 4 * s, last.Y - 4 * s, 8 * s, 8 * s);
                }
            }

            // target marker on the goal line
            float tX = gx1 - 5 * s;
            float tY = gy0 - (float)(Math.Max(0, sh.TargetY) / maxH) * gh;
            using (var pen = new Pen(Color.FromArgb((int)(255 * alpha), Theme.Cyan), 1.8f * s))
                g.DrawEllipse(pen, tX - 5 * s, tY - 5 * s, 10 * s, 10 * s);

            // caption
            Draw.Spaced(g, "TRAJECTORY", _theme.Tiny, muted, box.Left + padL, box.Top + 4 * s, 1.4f * s);
            Draw.TextRight(g, "GOAL FACE", _theme.Tiny, faint, gx1, box.Top + 4 * s);
            string foot = string.IsNullOrEmpty(sh.Body) ? "" : sh.Body.Replace('_', ' ').ToUpperInvariant();
            Draw.TextRight(g, foot, _theme.Tiny, muted, gx1, box.Bottom - 18 * s);
        }

        // ---------------------------------------------------------------------
        //  2. SHOT / MISS card
        // ---------------------------------------------------------------------
        private void DrawShot(Graphics g, HudEvent ev, HudState st, int w, int h, float s,
                              double elapsed, double remaining)
        {
            double t = Anim(elapsed, remaining);
            if (t <= 0.001) return;
            Color team = Draw.ParseColor(ev.TeamColor, Theme.Volt);
            float alpha = (float)Math.Min(1, t * 1.5);
            float slide = (float)((1.0 - Ease(t)) * 40 * s);

            float pw = 780 * s, ph = 188 * s;
            float px = 56 * s;
            float py = h - 56 * s - ph + slide;
            if (py < 20 * s) py = 20 * s;

            Draw.GlassPanel(g, new RectangleF(px, py, pw, ph), 8 * s, team);

            using (var white = new SolidBrush(Color.FromArgb((int)(255 * alpha), 255, 255, 255)))
            using (var volt = new SolidBrush(Color.FromArgb((int)(255 * alpha), Theme.Volt)))
            using (var muted = new SolidBrush(Color.FromArgb((int)(210 * alpha), 154, 166, 178)))
            {
                float x = px + 32 * s, y = py + 14 * s;

                string outcome = "SHOT";
                if (ev.Shot != null)
                {
                    switch (ev.Shot.Outcome)
                    {
                        case "on_target": outcome = "SHOT ON TARGET"; break;
                        case "off_target": outcome = "SHOT OFF TARGET"; break;
                        case "own_goal": outcome = "OWN GOAL"; break;
                        default: outcome = "GOAL"; break;
                    }
                }
                Draw.Spaced(g, outcome, _theme.Label, volt, x, y, 2.2f * s);

                // right side of the header: team + shirt
                string meta = (string.IsNullOrEmpty(ev.TeamAbbr) ? "" : ev.TeamAbbr + "   ") + "#" + ev.Shirt;
                Draw.TextRight(g, meta, _theme.Label, muted, px + pw - 32 * s, y);

                // player name
                Draw.TextClipped(g, ev.PlayerName, _theme.NameSmall, white, x, y + 20 * s,
                                 pw - 64 * s);

                // five stat cells across the card
                string[] labels = { "SHOTS", "ON TARGET", "GOALS", "ASSISTS", "G / A" };
                string[] values =
                {
                    Fmt0(ev.Shots), Fmt0(ev.OnTarget), Fmt0(ev.Goals), Fmt0(ev.Assists), Fmt0(ev.Ga)
                };
                float cw = (pw - 64 * s) / 5f;
                for (int i = 0; i < 5; i++)
                {
                    float cx = x + i * cw;
                    using (var sep = new SolidBrush(Color.FromArgb((int)(34 * alpha), 255, 255, 255)))
                        g.FillRectangle(sep, cx, py + 92 * s, cw - 16 * s, 1.4f * s);
                    Draw.Spaced(g, labels[i], _theme.Tiny, muted, cx, py + 100 * s, 0.9f * s);
                    Draw.Text(g, values[i], _theme.ValueBig,
                              i >= 2 ? volt : white, cx, py + 118 * s);
                }

                if (ev.Duration > 0)
                {
                    float prog = (float)Math.Max(0, Math.Min(1, ev.Remaining / ev.Duration));
                    Draw.AccentLine(g, px + 32 * s, py + ph - 10 * s, pw - 64 * s, 2.6f * s, prog);
                }
            }
        }

        // ---------------------------------------------------------------------
        //  3. MOTM card
        // ---------------------------------------------------------------------
        private void DrawMotm(Graphics g, HudEvent ev, HudState st, int w, int h, float s,
                              double elapsed, double remaining)
        {
            double t = Anim(elapsed, remaining);
            if (t <= 0.001) return;
            Color team = Draw.ParseColor(ev.TeamColor, Theme.Volt);
            float alpha = (float)Math.Min(1, t * 1.4);
            float slide = (float)((1.0 - Ease(t)) * 60 * s);

            float pw = 820 * s, ph = 560 * s;
            float px = w - 56 * s - pw;
            float py = (h - ph) / 2 + slide;
            if (px < 20 * s) px = 20 * s;

            // glow behind the card
            using (var path = new GraphicsPath())
            {
                path.AddEllipse(px + pw * 0.35f, py + ph * 0.15f, pw * 0.8f, ph * 0.8f);
                using (var pgb = new PathGradientBrush(path))
                {
                    pgb.CenterColor = Color.FromArgb((int)(70 * alpha), team);
                    pgb.SurroundColors = new[] { Color.FromArgb(0, team) };
                    g.FillPath(pgb, path);
                }
            }

            Draw.GlassPanel(g, new RectangleF(px, py, pw, ph), 14 * s, team);

            using (var white = new SolidBrush(Color.FromArgb((int)(255 * alpha), 255, 255, 255)))
            using (var volt = new SolidBrush(Color.FromArgb((int)(255 * alpha), Theme.Volt)))
            using (var muted = new SolidBrush(Color.FromArgb((int)(215 * alpha), 154, 166, 178)))
            using (var teamB = new SolidBrush(Color.FromArgb((int)(255 * alpha), team)))
            {
                float x = px + 44 * s, y = py + 28 * s;
                Draw.Spaced(g, "MAN OF THE MATCH", _theme.Title, volt, x, y, 4.0f * s);
                Draw.Spaced(g, "HYPERMOTION  MATCH  RATING", _theme.Tiny, muted, x, y + 26 * s, 2.0f * s);

                // rating badge
                float bx = px + 44 * s, by = py + 74 * s, bd = 148 * s;
                using (var ring = new Pen(Color.FromArgb((int)(255 * alpha), Theme.Volt), 4 * s))
                    g.DrawEllipse(ring, bx, by, bd, bd);
                using (var inner = new SolidBrush(Color.FromArgb((int)(60 * alpha), 174, 255, 0)))
                    g.FillEllipse(inner, bx + 8 * s, by + 8 * s, bd - 16 * s, bd - 16 * s);
                string rating = ev.Rating > 0 ? Fmt(ev.Rating, 1) : "-";
                float rw = Draw.Width(g, rating, _theme.Huge);
                Draw.Text(g, rating, _theme.Huge, volt,
                          bx + (bd - rw) / 2f, by + bd / 2f - 62 * s);
                string rlabel = "RATING";
                float lw = Draw.Width(g, rlabel, _theme.Tiny);
                Draw.Spaced(g, rlabel, _theme.Tiny, muted,
                            bx + (bd - lw - 6 * s) / 2f, by + bd - 40 * s, 1.6f * s);

                // name block
                float nx = bx + bd + 36 * s;
                Draw.Text(g, ev.PlayerName, _theme.Name, white, nx, by + 8 * s);
                Draw.Text(g, (ev.TeamName + (string.IsNullOrEmpty(ev.TeamAbbr) ? "" : "  " + ev.TeamAbbr)),
                          _theme.Title, teamB, nx, by + 74 * s);
                Draw.Text(g, ev.ScoreLine, _theme.Mid, muted, nx, by + 104 * s);

                // stat grid 4 x 2
                MotmStats mm = ev.Motm;
                string[] labels = { "GOALS", "ASSISTS", "G / A", "SHOTS", "ON TARGET", "PASS %", "TACKLES", "TOUCHES" };
                string[] values = new string[8];
                if (mm != null)
                {
                    values[0] = Fmt0(mm.Goals);
                    values[1] = Fmt0(mm.Assists);
                    values[2] = Fmt0(mm.Ga);
                    values[3] = Fmt0(mm.Shots);
                    values[4] = Fmt0(mm.OnTarget);
                    values[5] = Fmt0(mm.PassPct) + "%";
                    values[6] = Fmt0(mm.TacklesOk > 0 ? mm.TacklesOk : mm.Tackles);
                    values[7] = Fmt0(mm.Touches);
                }
                else
                {
                    for (int i = 0; i < 8; i++) values[i] = "-";
                }

                float gx0 = px + 44 * s, gy0 = py + 258 * s;
                float cw = (pw - 88 * s) / 4f, chh = 104 * s;
                for (int i = 0; i < 8; i++)
                {
                    int col = i % 4, row = i / 4;
                    float cx = gx0 + col * cw;
                    float cy = gy0 + row * chh;
                    using (var sep = new SolidBrush(Color.FromArgb((int)(36 * alpha), 255, 255, 255)))
                        g.FillRectangle(sep, cx, cy, cw - 12 * s, 1.4f * s);
                    Draw.Spaced(g, labels[i], _theme.Tiny, muted, cx, cy + 12 * s, 1.2f * s);
                    Draw.Text(g, values[i], _theme.ValueBig, i < 3 ? volt : white, cx, cy + 34 * s);
                }

                // footer
                string foot = "";
                if (mm != null)
                {
                    bool metric = st != null && st.Units == "metric";
                    double peak = metric ? mm.PeakMph * 1.609344 : mm.PeakMph;
                    if (mm.PeakMph > 0)
                        foot = "PEAK SHOT  " + Fmt(peak, 1) + " " + _theme.UnitSpeed;
                    if (mm.Xg > 0)
                        foot += (foot.Length > 0 ? "      " : "") + "TOTAL xG  " + Fmt(mm.Xg, 2);
                }
                Draw.Spaced(g, foot, _theme.Label, muted, px + 44 * s, py + ph - 52 * s, 1.8f * s);

                if (ev.Duration > 0)
                {
                    float prog = (float)Math.Max(0, Math.Min(1, ev.Remaining / ev.Duration));
                    Draw.AccentLine(g, px + 44 * s, py + ph - 26 * s, pw - 88 * s, 3.2f * s, prog);
                }
            }
        }

        // ---------------------------------------------------------------------
        //  Optional score bug + diagnostics
        // ---------------------------------------------------------------------
        private void DrawScoreBug(Graphics g, HudState st, int w, int h, float s)
        {
            float pw = 360 * s, ph = 62 * s;
            var r = new RectangleF(56 * s, 48 * s, pw, ph);
            Draw.GlassPanel(g, r, 6 * s, Draw.ParseColor(st.Home.Color, Theme.Volt));
            using (var white = new SolidBrush(Theme.White))
            using (var muted = new SolidBrush(Theme.Muted))
            using (var volt = new SolidBrush(Theme.Volt))
            {
                Draw.Text(g, st.Home.Abbr, _theme.Value, white, r.Left + 26 * s, r.Top + 14 * s);
                Draw.TextRight(g, st.Away.Abbr, _theme.Value, white, r.Right - 26 * s, r.Top + 14 * s);
                string score = st.Home.Score + " - " + st.Away.Score;
                float sw = Draw.Width(g, score, _theme.Value);
                Draw.Text(g, score, _theme.Value, volt, r.Left + (pw - sw) / 2f, r.Top + 14 * s);
                Draw.Spaced(g, st.Clock, _theme.Tiny, muted, r.Left + (pw - 40 * s) / 2f, r.Top + 2 * s, 1.0f * s);
            }
        }

        private void DrawDiagnostics(Graphics g, HudState st, int w, int h, float s)
        {
            float pw = 520 * s, ph = 300 * s;
            var r = new RectangleF(w - pw - 40 * s, 40 * s, pw, ph);
            Draw.GlassPanel(g, r, 8 * s, Theme.Cyan);
            using (var white = new SolidBrush(Theme.White))
            using (var muted = new SolidBrush(Theme.Muted))
            using (var volt = new SolidBrush(Theme.Volt))
            using (var red = new SolidBrush(Theme.Red))
            {
                Draw.Spaced(g, "EA FC 27 BROADCAST  -  DIAGNOSTICS", _theme.Label, volt,
                            r.Left + 26 * s, r.Top + 18 * s, 1.8f * s);
                string[] rows;
                if (st == null)
                {
                    rows = new[] { "state.json  :  not found", "game window :  searching" };
                }
                else
                {
                    rows = new[]
                    {
                        "state.json   :  OK  (seq " + st.Seq + ")",
                        "lua ffi      :  " + (st.Ffi ? "on" : "OFF  (luajit.ext.enabled = 1)"),
                        "stat region  :  " + (st.StatsRegion ? "found" : "not found"),
                        "pitch region :  " + (st.PitchRegion ? "found" : "not found"),
                        "replay cam   :  " + (st.CameraOk ? "patched" : "vanilla"),
                        "player names :  " + (st.PlayerDb ? "Player.bin" : "fallback"),
                        "events seen  :  " + st.EventCount,
                        "match clock  :  " + st.Clock,
                        "units        :  " + st.Units,
                    };
                }
                float yy = r.Top + 54 * s;
                foreach (var row in rows)
                {
                    var brush = row.Contains("OFF") || row.Contains("not found") ? red : white;
                    Draw.Text(g, row, _theme.Label, brush, r.Left + 26 * s, yy);
                    yy += 24 * s;
                }
                Draw.Text(g, "F8 demo   F9 close   F12 quit", _theme.Tiny, muted,
                          r.Left + 26 * s, r.Bottom - 30 * s);
            }
        }

        // ---------------------------------------------------------------------
        //  Demo events (F8) so the HUD can be checked without playing
        // ---------------------------------------------------------------------
        private HudEvent BuildDemoEvent(HudState st, float s)
        {
            var e = new HudEvent();
            e.Id = 900000 + _demoPhase;
            e.Duration = _demoPhase == 3 ? 20 : 14;
            e.Remaining = e.Duration - ((_clock.Elapsed.TotalSeconds % e.Duration));
            e.Side = "home";
            e.TeamName = st != null ? st.Home.Name : "ARSENAL";
            e.TeamAbbr = st != null ? st.Home.Abbr : "ARS";
            e.TeamColor = st != null ? st.Home.Color : "#EF0107";

            if (_demoPhase == 3)
            {
                e.Kind = "motm";
                e.PlayerName = "B. SAKA";
                e.Shirt = 7; e.Pos = "RWF"; e.Rating = 8.7;
                e.ScoreLine = "ARSENAL 2 - 1 CHELSEA";
                e.Motm = new MotmStats
                {
                    Goals = 2, Assists = 1, Ga = 3, Shots = 5, OnTarget = 4,
                    Passes = 34, PassesOk = 30, PassPct = 88, Tackles = 3, TacklesOk = 2,
                    DribblesOk = 4, Touches = 61, Saves = 0, Interceptions = 1,
                    PeakMph = 78.4, Xg = 1.12
                };
            }
            else if (_demoPhase == 2)
            {
                e.Kind = "shot";
                e.PlayerName = "C. PALMER";
                e.Shirt = 20; e.Pos = "CF";
                e.TeamName = "CHELSEA"; e.TeamAbbr = "CHE"; e.TeamColor = "#034694";
                e.Shots = 3; e.OnTarget = 1; e.Goals = 0; e.Assists = 1; e.Ga = 1;
                e.Shot = DemoShot("off_target");
            }
            else
            {
                e.Kind = "goal";
                e.PlayerName = "B. SAKA";
                e.Shirt = 7; e.Pos = "RWF";
                e.Shots = 4; e.OnTarget = 3; e.Goals = 2; e.Assists = 1; e.Ga = 3;
                e.Shot = DemoShot("goal");
            }
            return e;
        }

        private static ShotState DemoShot(string outcome)
        {
            var sh = new ShotState();
            sh.SpeedMph = 74.2; sh.SpeedKmh = 119.4;
            sh.DistanceM = 16.8; sh.DistanceYd = 18.4;
            sh.AngleDeg = 22.6; sh.ElevationDeg = 8.4;
            sh.ApexM = 1.9; sh.ApexFt = 6.2; sh.HangS = 0.92;
            sh.Xg = 0.24;
            sh.TargetX = 1.2; sh.TargetY = 1.4;
            sh.OriginX = 36.0; sh.OriginY = 9.0;
            sh.Outcome = outcome; sh.Body = "right_foot"; sh.Source = "measured";
            for (int i = 0; i <= 15; i++)
            {
                double t = i / 15.0;
                double d = sh.DistanceM * t;
                double z = 4 * sh.ApexM * t * (1 - t) * 0.85 + sh.TargetY * t * t;
                double ang = Math.Atan2(0 - sh.OriginY, 52.5 - sh.OriginX);
                sh.Traj.Add(new double[]
                {
                    sh.OriginX + Math.Cos(ang) * d,
                    sh.OriginY + Math.Sin(ang) * d,
                    z
                });
            }
            return sh;
        }

        // ---------------------------------------------------------------------
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

        private static string MinutesOnly(string clock)
        {
            if (string.IsNullOrEmpty(clock)) return "";
            int idx = clock.IndexOf(':');
            if (idx <= 0) return clock;
            return clock.Substring(0, idx).Trim() + "'";
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
            try
            {
                Native.SetCurrentProcessExplicitAppUserModelID("FC27.Broadcast.Overlay");
            }
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
                Path.Combine(exeDir, @"..\content\fc27-broadcast\state.json"),
                Path.Combine(exeDir, @"content\fc27-broadcast\state.json"),
                Path.Combine(exeDir, @"..\..\content\fc27-broadcast\state.json"),
                Path.Combine(exeDir, @"..\..\sider\content\fc27-broadcast\state.json"),
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
