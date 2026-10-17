// Blocking HTTPS GET on Windows (WinHTTP). Used by the DEM tile fetcher on its I/O threads.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winhttp.h>
#include <string>
#include "pw/env/codec.h"

namespace pw::env {

static std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), int(s.size()), nullptr, 0);
    std::wstring w(std::size_t(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), int(s.size()), w.data(), n);
    return w;
}

bool httpGet(const std::string& url, double timeoutSeconds, std::vector<uint8_t>& out, int& status, std::string& err) {
    status = 0; out.clear();
    std::wstring wurl = widen(url);
    URL_COMPONENTS uc{};
    uc.dwStructSize = sizeof uc;
    wchar_t host[256] = {}, path[2048] = {};
    uc.lpszHostName = host; uc.dwHostNameLength = 255;
    uc.lpszUrlPath = path; uc.dwUrlPathLength = 2047;
    if (!WinHttpCrackUrl(wurl.c_str(), 0, 0, &uc)) { err = "bad URL"; return false; }
    HINTERNET s = WinHttpOpen(L"PlaneWorld/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!s) { err = "WinHttpOpen failed"; return false; }
    int ms = int(timeoutSeconds * 1000);
    WinHttpSetTimeouts(s, ms, ms, ms, ms);
    bool ok = false;
    HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
    HINTERNET r = c ? WinHttpOpenRequest(c, L"GET", path, nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                         uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0) : nullptr;
    if (r && WinHttpSendRequest(r, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) && WinHttpReceiveResponse(r, nullptr)) {
        DWORD code = 0, len = sizeof code;
        WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &code, &len, WINHTTP_NO_HEADER_INDEX);
        status = int(code);
        ok = true;
        for (;;) {
            DWORD avail = 0;
            if (!WinHttpQueryDataAvailable(r, &avail)) { ok = false; err = "read failed"; break; }
            if (avail == 0) break;
            std::size_t at = out.size();
            out.resize(at + avail);
            DWORD got = 0;
            if (!WinHttpReadData(r, out.data() + at, avail, &got)) { ok = false; err = "read failed"; break; }
            out.resize(at + got);
        }
    } else {
        err = "request failed (" + std::to_string(GetLastError()) + ")";
    }
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    return ok;
}

} // namespace pw::env
