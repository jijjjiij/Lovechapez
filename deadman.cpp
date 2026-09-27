// Deadman Switch — "Я жив" tracker that pushes status to a GitHub Gist.
// Build (MinGW):
//   g++ deadman.cpp -o deadman.exe -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi -mwindows -std=c++17
// Build (MSVC):
//   cl deadman.cpp /link gdiplus.lib winhttp.lib gdi32.lib comctl32.lib dwmapi.lib user32.lib /SUBSYSTEM:WINDOWS

#include <windows.h>
#include <gdiplus.h>
#include <winhttp.h>
#include <dwmapi.h>
#include <string>
#include <sstream>
#include <ctime>
#include <cstdio>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "dwmapi.lib")

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

using namespace Gdiplus;

// ---- control ids ----
#define ID_BTN_ALIVE      101
#define ID_BTN_BUSY_1      102
#define ID_BTN_BUSY_3      103
#define ID_BTN_BUSY_5      104
#define ID_BTN_BUSY_8      105
#define ID_BTN_BUSY_12     106
#define ID_BTN_BUSY_24     107
#define ID_EDIT_CUSTOM     108
#define ID_BTN_CUSTOM_APPLY 109
#define ID_STATIC_STATUS   110
#define ID_STATIC_LAST     111
#define IDT_TICK           1001

// ---- palette ----
static const COLORREF BG            = RGB(0x14, 0x16, 0x1f);
static const COLORREF PANEL         = RGB(0x1e, 0x21, 0x2e);
static const COLORREF ALIVE_TOP     = RGB(0x34, 0xd3, 0x99);
static const COLORREF ALIVE_BOT     = RGB(0x18, 0x9a, 0x6e);
static const COLORREF BUSY_TOP      = RGB(0xf5, 0xa6, 0x23);
static const COLORREF BUSY_BOT      = RGB(0xc9, 0x7c, 0x0c);
static const COLORREF TEXT_LIGHT    = RGB(0xe9, 0xec, 0xf2);
static const COLORREF TEXT_DIM      = RGB(0x9a, 0xa3, 0xb5);

struct AppState {
    std::string token;
    std::string gistId;
    std::string filename = "status.json";
    int intervalHours = 12;
    time_t lastAlive = 0;
    time_t busyUntil = 0; // 0 = not busy
    HFONT fontBig = nullptr, fontMid = nullptr, fontSmall = nullptr;
};
static AppState g;

// ---------------- config ----------------
static std::string GetExeDir() {
    char path[MAX_PATH];
    GetModuleFileNameA(nullptr, path, MAX_PATH);
    std::string s(path);
    size_t pos = s.find_last_of("\\/");
    return (pos == std::string::npos) ? "" : s.substr(0, pos + 1);
}

static void LoadConfig() {
    std::string ini = GetExeDir() + "config.ini";
    char buf[512];
    GetPrivateProfileStringA("deadman", "token", "", buf, sizeof(buf), ini.c_str());
    g.token = buf;
    GetPrivateProfileStringA("deadman", "gist_id", "", buf, sizeof(buf), ini.c_str());
    g.gistId = buf;
    GetPrivateProfileStringA("deadman", "filename", "status.json", buf, sizeof(buf), ini.c_str());
    g.filename = buf;
    g.intervalHours = GetPrivateProfileIntA("deadman", "interval_hours", 12, ini.c_str());
}

// ---------------- json / http ----------------
static std::string EscapeJson(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (char c : in) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            default:   out += c;
        }
    }
    return out;
}

static std::string IsoUtc(time_t t) {
    tm gmt;
    gmtime_s(&gmt, &t);
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &gmt);
    return buf;
}

static std::wstring Widen(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

// Fire-and-forget PATCH to api.github.com/gists/{id}, updates one file's content.
static bool PushGistStatus() {
    if (g.token.empty() || g.gistId.empty()) return false;

    std::ostringstream statusJson;
    statusJson << "{\"last_alive\":\"" << IsoUtc(g.lastAlive) << "\","
               << "\"busy_until\":" << (g.busyUntil ? ("\"" + IsoUtc(g.busyUntil) + "\"") : "null") << ","
               << "\"interval_hours\":" << g.intervalHours << "}";

    std::ostringstream body;
    body << "{\"files\":{\"" << g.filename << "\":{\"content\":\""
         << EscapeJson(statusJson.str()) << "\"}}}";
    std::string bodyStr = body.str();

    bool ok = false;
    HINTERNET hSession = WinHttpOpen(L"DeadmanSwitch/1.0",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (hSession) {
        HINTERNET hConnect = WinHttpConnect(hSession, L"api.github.com", INTERNET_DEFAULT_HTTPS_PORT, 0);
        if (hConnect) {
            std::wstring path = L"/gists/" + Widen(g.gistId);
            HINTERNET hRequest = WinHttpOpenRequest(hConnect, L"PATCH", path.c_str(),
                nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
            if (hRequest) {
                std::wstring headers =
                    L"Authorization: token " + Widen(g.token) + L"\r\n"
                    L"Content-Type: application/json\r\n"
                    L"User-Agent: DeadmanSwitch\r\n";
                BOOL sent = WinHttpSendRequest(hRequest, headers.c_str(), (DWORD)-1,
                    (LPVOID)bodyStr.data(), (DWORD)bodyStr.size(), (DWORD)bodyStr.size(), 0);
                if (sent && WinHttpReceiveResponse(hRequest, nullptr)) {
                    DWORD statusCode = 0, size = sizeof(statusCode);
                    WinHttpQueryHeaders(hRequest,
                        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &size, WINHTTP_NO_HEADER_INDEX);
                    ok = (statusCode >= 200 && statusCode < 300);
                }
                WinHttpCloseHandle(hRequest);
            }
            WinHttpCloseHandle(hConnect);
        }
        WinHttpCloseHandle(hSession);
    }
    return ok;
}

// ---------------- drawing helpers ----------------
static void RoundedPath(GraphicsPath& path, const Rect& r, int radius) {
    int d = radius * 2;
    path.AddArc(r.X, r.Y, d, d, 180, 90);
    path.AddArc(r.X + r.Width - d, r.Y, d, d, 270, 90);
    path.AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0, 90);
    path.AddArc(r.X, r.Y + r.Height - d, d, d, 90, 90);
    path.CloseFigure();
}

static void DrawGradButton(LPDRAWITEMSTRUCT dis, COLORREF top, COLORREF bot,
                            const wchar_t* text, REAL fontSize, bool bold) {
    Graphics graphics(dis->hDC);
    graphics.SetSmoothingMode(SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(TextRenderingHintAntiAlias);

    Rect rc(dis->rcItem.left, dis->rcItem.top,
            dis->rcItem.right - dis->rcItem.left, dis->rcItem.bottom - dis->rcItem.top);
    bool pressed = (dis->itemState & ODS_SELECTED) != 0;
    if (pressed) { top = RGB(GetRValue(top) * 0.8, GetGValue(top) * 0.8, GetBValue(top) * 0.8);
                   bot = RGB(GetRValue(bot) * 0.8, GetGValue(bot) * 0.8, GetBValue(bot) * 0.8); }

    GraphicsPath path;
    RoundedPath(path, rc, 10);
    LinearGradientBrush brush(rc,
        Color(255, GetRValue(top), GetGValue(top), GetBValue(top)),
        Color(255, GetRValue(bot), GetGValue(bot), GetBValue(bot)),
        LinearGradientModeVertical);
    graphics.FillPath(&brush, &path);

    FontFamily ff(L"Segoe UI");
    Font font(&ff, fontSize, bold ? FontStyleBold : FontStyleRegular, UnitPixel);
    SolidBrush textBrush(Color(255, 255, 255, 255));
    StringFormat sf;
    sf.SetAlignment(StringAlignmentCenter);
    sf.SetLineAlignment(StringAlignmentCenter);
    RectF rcf((REAL)rc.X, (REAL)rc.Y, (REAL)rc.Width, (REAL)rc.Height);
    graphics.DrawString(text, -1, &font, rcf, &sf, &textBrush);
}

// ---------------- state / status text ----------------
static std::wstring FormatDelta(long long seconds, bool future) {
    if (seconds < 0) seconds = 0;
    long long h = seconds / 3600, m = (seconds % 3600) / 60;
    wchar_t buf[64];
    swprintf(buf, 64, future ? L"%lldч %02dм" : L"%lldч %02dм назад", h, (int)m);
    return buf;
}

static std::wstring ComputeStatusText(COLORREF& colorOut) {
    time_t now = time(nullptr);
    if (g.busyUntil && now < g.busyUntil) {
        colorOut = BUSY_TOP;
        return L"ЗАНЯТ ещё " + FormatDelta(g.busyUntil - now, true);
    }
    long long elapsed = g.lastAlive ? (now - g.lastAlive) : 999999;
    if (!g.lastAlive || elapsed > (long long)g.intervalHours * 3600) {
        colorOut = RGB(0xef, 0x44, 0x44);
        return L"НЕ ЖИВ — просрочено";
    }
    colorOut = ALIVE_TOP;
    return L"ЖИВ — отклик " + FormatDelta(elapsed, false);
}

static void SetAlive() {
    g.lastAlive = time(nullptr);
    g.busyUntil = 0;
    PushGistStatus();
}

static void SetBusy(int hours) {
    g.lastAlive = time(nullptr);
    g.busyUntil = g.lastAlive + (time_t)hours * 3600;
    PushGistStatus();
}

// ---------------- window proc ----------------
static HWND hStatus, hLast, hEditCustom;

static void UpdateLabels(HWND hwnd) {
    COLORREF c;
    std::wstring s = ComputeStatusText(c);
    SetWindowTextW(hStatus, s.c_str());
    InvalidateRect(hStatus, nullptr, TRUE);

    wchar_t buf[128];
    if (g.lastAlive) {
        tm lt; localtime_s(&lt, &g.lastAlive);
        swprintf(buf, 128, L"последнее подтверждение: %02d:%02d:%02d", lt.tm_hour, lt.tm_min, lt.tm_sec);
    } else {
        wcscpy_s(buf, L"ещё не подтверждалось");
    }
    SetWindowTextW(hLast, buf);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        BOOL dark = TRUE;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));

        g.fontBig   = CreateFontW(-22, 0,0,0, FW_BOLD, 0,0,0, DEFAULT_CHARSET, 0,0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g.fontMid   = CreateFontW(-16, 0,0,0, FW_SEMIBOLD, 0,0,0, DEFAULT_CHARSET, 0,0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g.fontSmall = CreateFontW(-13, 0,0,0, FW_NORMAL, 0,0,0, DEFAULT_CHARSET, 0,0, CLEARTYPE_QUALITY, 0, L"Segoe UI");

        CreateWindowW(L"BUTTON", L"Я ЖИВ", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
            20, 20, 380, 90, hwnd, (HMENU)ID_BTN_ALIVE, nullptr, nullptr);

        hStatus = CreateWindowW(L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_CENTER,
            20, 120, 380, 30, hwnd, (HMENU)ID_STATIC_STATUS, nullptr, nullptr);
        SendMessageW(hStatus, WM_SETFONT, (WPARAM)g.fontMid, TRUE);

        hLast = CreateWindowW(L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_CENTER,
            20, 152, 380, 20, hwnd, (HMENU)ID_STATIC_LAST, nullptr, nullptr);
        SendMessageW(hLast, WM_SETFONT, (WPARAM)g.fontSmall, TRUE);

        CreateWindowW(L"STATIC", L"занят на:", WS_CHILD | WS_VISIBLE,
            20, 182, 100, 20, hwnd, nullptr, nullptr, nullptr);

        struct { int id; const wchar_t* label; } busyBtns[] = {
            {ID_BTN_BUSY_1, L"1ч"}, {ID_BTN_BUSY_3, L"3ч"}, {ID_BTN_BUSY_5, L"5ч"},
            {ID_BTN_BUSY_8, L"8ч"}, {ID_BTN_BUSY_12, L"12ч"}, {ID_BTN_BUSY_24, L"24ч"},
        };
        int x = 20, y = 206, w = 58, h = 40, gap = 6;
        for (int i = 0; i < 6; i++) {
            CreateWindowW(L"BUTTON", busyBtns[i].label, WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                x + i * (w + gap), y, w, h, hwnd, (HMENU)(INT_PTR)busyBtns[i].id, nullptr, nullptr);
        }

        hEditCustom = CreateWindowW(L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_BORDER | ES_NUMBER | ES_CENTER,
            20, 258, 100, 30, hwnd, (HMENU)ID_EDIT_CUSTOM, nullptr, nullptr);
        SendMessageW(hEditCustom, WM_SETFONT, (WPARAM)g.fontSmall, TRUE);

        CreateWindowW(L"BUTTON", L"применить (часы)", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
            130, 258, 270, 30, hwnd, (HMENU)ID_BTN_CUSTOM_APPLY, nullptr, nullptr);

        LoadConfig();
        SetTimer(hwnd, IDT_TICK, 1000, nullptr);
        UpdateLabels(hwnd);
        return 0;
    }
    case WM_DRAWITEM: {
        LPDRAWITEMSTRUCT dis = (LPDRAWITEMSTRUCT)lp;
        switch (dis->CtlID) {
        case ID_BTN_ALIVE:
            DrawGradButton(dis, ALIVE_TOP, ALIVE_BOT, L"Я ЖИВ", 26, true);
            break;
        case ID_BTN_CUSTOM_APPLY:
            DrawGradButton(dis, RGB(0x3b,0x4a,0x6b), RGB(0x27,0x33,0x4d), L"применить (часы)", 13, false);
            break;
        default:
            DrawGradButton(dis, BUSY_TOP, BUSY_BOT,
                [&]{ wchar_t buf[16]; GetWindowTextW(dis->hwndItem, buf, 16); return std::wstring(buf); }().c_str(),
                14, true);
        }
        return TRUE;
    }
    case WM_CTLCOLORSTATIC: {
        HDC hdc = (HDC)wp;
        SetTextColor(hdc, TEXT_LIGHT);
        SetBkColor(hdc, BG);
        return (LRESULT)GetStockObject(NULL_BRUSH) ? (LRESULT)CreateSolidBrush(BG) : 0;
    }
    case WM_CTLCOLOREDIT: {
        HDC hdc = (HDC)wp;
        SetTextColor(hdc, TEXT_LIGHT);
        SetBkColor(hdc, PANEL);
        static HBRUSH hb = CreateSolidBrush(PANEL);
        return (LRESULT)hb;
    }
    case WM_ERASEBKGND: {
        HDC hdc = (HDC)wp;
        RECT rc; GetClientRect(hwnd, &rc);
        HBRUSH b = CreateSolidBrush(BG);
        FillRect(hdc, &rc, b);
        DeleteObject(b);
        return 1;
    }
    case WM_COMMAND: {
        int id = LOWORD(wp);
        switch (id) {
        case ID_BTN_ALIVE:      SetAlive(); UpdateLabels(hwnd); break;
        case ID_BTN_BUSY_1:     SetBusy(1);  UpdateLabels(hwnd); break;
        case ID_BTN_BUSY_3:     SetBusy(3);  UpdateLabels(hwnd); break;
        case ID_BTN_BUSY_5:     SetBusy(5);  UpdateLabels(hwnd); break;
        case ID_BTN_BUSY_8:     SetBusy(8);  UpdateLabels(hwnd); break;
        case ID_BTN_BUSY_12:    SetBusy(12); UpdateLabels(hwnd); break;
        case ID_BTN_BUSY_24:    SetBusy(24); UpdateLabels(hwnd); break;
        case ID_BTN_CUSTOM_APPLY: {
            wchar_t buf[16];
            GetWindowTextW(hEditCustom, buf, 16);
            int hours = _wtoi(buf);
            if (hours > 0) { SetBusy(hours); UpdateLabels(hwnd); }
            break;
        }
        }
        return 0;
    }
    case WM_TIMER:
        if (wp == IDT_TICK) UpdateLabels(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, IDT_TICK);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, LPWSTR, int nCmdShow) {
    GdiplusStartupInput gsi;
    ULONG_PTR gdipToken;
    GdiplusStartup(&gdipToken, &gsi, nullptr);

    WNDCLASSW wc = {};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = L"DeadmanSwitchWnd";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = CreateSolidBrush(BG);
    RegisterClassW(&wc);

    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"Deadman Switch",
        WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 440, 340,
        nullptr, nullptr, hInst, nullptr);
    ShowWindow(hwnd, nCmdShow);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    GdiplusShutdown(gdipToken);
    return 0;
}
