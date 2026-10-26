// Native helpers for AutoCopy quick actions: global hotkeys, microphone mute
// (Windows Core Audio), and the click-through "MIC MUTED" overlay.
// Compiled at startup by AutoCopy.ps1 via Add-Type (C# 5, .NET Framework).
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace AutoCopyNative
{
    // ---------------- Core Audio COM interop ----------------
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorCom { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr props);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float level, ref Guid ctx);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
        [PreserveSig] int GetMasterVolumeLevel(out float level);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint ch, float level, ref Guid ctx);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float level, ref Guid ctx);
        [PreserveSig] int GetChannelVolumeLevel(uint ch, out float level);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    public static class Mic
    {
        const int eCapture = 1, eConsole = 0, eCommunications = 2, DEVICE_STATE_ACTIVE = 1, CLSCTX_ALL = 23;

        // Mics that were live when we muted, so unmute only restores those
        // (a mic that was already muted on purpose stays muted).
        static readonly List<string> mutedByUs = new List<string>();

        static IMMDeviceEnumerator NewEnum() { return (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom()); }

        static IAudioEndpointVolume Volume(IMMDevice d)
        {
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object o;
            Marshal.ThrowExceptionForHR(d.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o));
            return (IAudioEndpointVolume)o;
        }

        static string DefaultId(IMMDeviceEnumerator e, int role)
        {
            IMMDevice d;
            if (e.GetDefaultAudioEndpoint(eCapture, role, out d) != 0 || d == null) return null;
            string id; d.GetId(out id);
            return id;
        }

        /// <summary>-1 = no microphone, 0 = live, 1 = muted (default recording device).</summary>
        public static int GetState()
        {
            try
            {
                IMMDevice d;
                if (NewEnum().GetDefaultAudioEndpoint(eCapture, eConsole, out d) != 0 || d == null) return -1;
                bool m;
                if (Volume(d).GetMute(out m) != 0) return -1;
                return m ? 1 : 0;
            }
            catch { return -1; }
        }

        /// <summary>Mute (or unmute) every active recording device.</summary>
        public static void SetMuted(bool mute)
        {
            IMMDeviceEnumerator e = NewEnum();
            string defConsole = DefaultId(e, eConsole), defComms = DefaultId(e, eCommunications);
            IMMDeviceCollection col;
            Marshal.ThrowExceptionForHR(e.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, out col));
            uint n; col.GetCount(out n);
            Guid ctx = Guid.Empty;
            if (mute) mutedByUs.Clear();
            for (uint i = 0; i < n; i++)
            {
                try
                {
                    IMMDevice d; col.Item(i, out d);
                    string id; d.GetId(out id);
                    IAudioEndpointVolume v = Volume(d);
                    bool cur; v.GetMute(out cur);
                    if (mute)
                    {
                        if (!cur) { v.SetMute(true, ref ctx); mutedByUs.Add(id); }
                    }
                    else if (cur && (mutedByUs.Contains(id) || id == defConsole || id == defComms))
                    {
                        v.SetMute(false, ref ctx);
                    }
                }
                catch { }
            }
            if (!mute) mutedByUs.Clear();
        }
    }

    // ---------------- Global hotkeys ----------------
    public class HotkeyEventArgs : EventArgs
    {
        public int Id;
        public HotkeyEventArgs(int id) { Id = id; }
    }

    public class HotkeyWindow : NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        readonly List<int> ids = new List<int>();
        public event EventHandler<HotkeyEventArgs> Pressed;

        public HotkeyWindow()
        {
            CreateParams cp = new CreateParams();
            cp.Parent = new IntPtr(-3); // HWND_MESSAGE: invisible message-only window
            CreateHandle(cp);
        }

        /// <summary>mods: Alt=1 Ctrl=2 Shift=4 Win=8. Returns false if another app owns the combo.</summary>
        public bool Register(int id, uint mods, uint vk)
        {
            bool ok = RegisterHotKey(Handle, id, mods | 0x4000 /* MOD_NOREPEAT */, vk);
            if (ok) ids.Add(id);
            return ok;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312) // WM_HOTKEY
            {
                EventHandler<HotkeyEventArgs> h = Pressed;
                if (h != null) h(this, new HotkeyEventArgs(m.WParam.ToInt32()));
            }
            base.WndProc(ref m);
        }

        public void UnregisterAll()
        {
            foreach (int id in ids) UnregisterHotKey(Handle, id);
            ids.Clear();
        }

        public void Dispose()
        {
            UnregisterAll();
            DestroyHandle();
        }
    }

    // ---------------- "MIC MUTED" overlay ----------------
    // Borderless, always-on-top, click-through, never takes focus, hidden from
    // Alt+Tab and the taskbar. Sits centred just above the taskbar of the
    // primary monitor.
    public class OverlayForm : Form
    {
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

        readonly string text;
        readonly float scale = 1f;

        public static void EnableDpiAwareness() { try { SetProcessDPIAware(); } catch { } }

        public OverlayForm(string text)
        {
            this.text = text;
            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) scale = g.DpiX / 96f;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(200, 16, 16);
            Opacity = 0.92;              // also makes the window layered (needed for click-through)
            DoubleBuffered = true;
            Size = new Size((int)(190 * scale), (int)(44 * scale));
            Font = new Font("Segoe UI", 15f, FontStyle.Bold, GraphicsUnit.Point);
            Place();
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000008   // WS_EX_TOPMOST
                           |  0x00000020   // WS_EX_TRANSPARENT (clicks pass through)
                           |  0x00000080   // WS_EX_TOOLWINDOW (no Alt+Tab)
                           |  0x08000000;  // WS_EX_NOACTIVATE
                return cp;
            }
        }

        public void Place()
        {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            Point p = new Point(wa.Left + (wa.Width - Width) / 2, wa.Bottom - Height - (int)(14 * scale));
            if (Location != p) Location = p;
        }

        /// <summary>Re-assert top-most (games and other overlays can push us down).</summary>
        public void KeepOnTop()
        {
            Place();
            SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0010); // NOMOVE|NOSIZE|NOACTIVATE
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using (Pen border = new Pen(Color.FromArgb(255, 120, 120), 2f * scale))
                g.DrawRectangle(border, border.Width / 2, border.Width / 2, Width - border.Width, Height - border.Width);

            // crossed-out mic glyph on the left
            float cx = 26 * scale, cy = Height / 2f - 2 * scale;
            using (Pen pen = new Pen(Color.White, 2.2f * scale))
            using (GraphicsPath body = new GraphicsPath())
            {
                body.AddArc(cx - 5 * scale, cy - 11 * scale, 10 * scale, 10 * scale, 180, 180);
                body.AddArc(cx - 5 * scale, cy - 3 * scale, 10 * scale, 10 * scale, 0, 180);
                body.CloseFigure();
                g.DrawPath(pen, body);
                g.DrawArc(pen, cx - 9 * scale, cy - 6 * scale, 18 * scale, 16 * scale, 0, 180);
                g.DrawLine(pen, cx, cy + 10 * scale, cx, cy + 14 * scale);
                g.DrawLine(pen, cx - 11 * scale, cy - 12 * scale, cx + 11 * scale, cy + 14 * scale);
            }

            RectangleF r = new RectangleF(44 * scale, 0, Width - 50 * scale, Height);
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                g.DrawString(text, Font, Brushes.White, r, sf);
            }
        }
    }
}
