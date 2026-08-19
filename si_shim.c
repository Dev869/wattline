/* DSI_SiUSBXp_3_1.DLL replacement: pretends an ANT USB stick is plugged in,
 * and pipes its serial stream over TCP to the emulator running on macOS.
 *
 * GT Bike V's ANT_Receiver.dll loads this DLL to talk to a SiLabs-based ANT
 * stick. CrossOver has no USB driver stack, so instead of a real stick we
 * answer with a socket to 127.0.0.1:$ANT_BRIDGE_PORT, where ant_stick.py
 * speaks the ANT message protocol using live Bluetooth sensor data.
 *
 * Every call is logged so we can see exactly what the caller expects.
 *
 * Build: make dll
 */

#include <windows.h>
#include <winsock2.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>

#define SI_SUCCESS 0x00
#define SI_INVALID_HANDLE 0x01
#define SI_READ_ERROR 0x02
#define SI_WRITE_ERROR 0x04
#define SI_INVALID_PARAMETER 0x06
#define SI_DEVICE_NOT_FOUND 0xFF

#define SI_RETURN_SERIAL_NUMBER 0x00
#define SI_RETURN_DESCRIPTION 0x01
#define SI_RETURN_LINK_NAME 0x02
#define SI_RETURN_VID 0x03
#define SI_RETURN_PID 0x04

#define SI_RX_EMPTY 0x00
#define SI_RX_READY 0x02

#define DEFAULT_PORT 51234

static SOCKET g_sock = INVALID_SOCKET;
static DWORD g_read_timeout = 1000;
static DWORD g_write_timeout = 1000;
static CRITICAL_SECTION g_lock;
static FILE *g_log;

static void shimlog(const char *fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

static void hexdump(const char *tag, const unsigned char *buf, int n) {
    if (!g_log) return;
    fprintf(g_log, "  %s:", tag);
    for (int i = 0; i < n && i < 32; i++) fprintf(g_log, " %02X", buf[i]);
    if (n > 32) fprintf(g_log, " ...(%d)", n);
    fputc('\n', g_log);
    fflush(g_log);
}

static int bridge_port(void) {
    char buf[16];
    DWORD n = GetEnvironmentVariableA("ANT_BRIDGE_PORT", buf, sizeof(buf));
    if (n > 0 && n < sizeof(buf)) {
        int p = atoi(buf);
        if (p > 0 && p < 65536) return p;
    }
    return DEFAULT_PORT;
}

/* Is the emulator listening? Decides whether we claim a stick exists. */
static SOCKET bridge_connect(void) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return INVALID_SOCKET;

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)bridge_port());
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        shimlog("connect to 127.0.0.1:%d failed (%d)", bridge_port(), WSAGetLastError());
        closesocket(s);
        return INVALID_SOCKET;
    }
    BOOL nodelay = TRUE;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&nodelay, sizeof(nodelay));
    return s;
}

__declspec(dllexport) DWORD WINAPI SI_GetNumDevices(LPDWORD lpdwNumDevices) {
    SOCKET probe = bridge_connect();
    DWORD n = (probe == INVALID_SOCKET) ? 0 : 1;
    if (probe != INVALID_SOCKET) closesocket(probe);
    if (lpdwNumDevices) *lpdwNumDevices = n;
    shimlog("SI_GetNumDevices -> %lu", n);
    return n ? SI_SUCCESS : SI_DEVICE_NOT_FOUND;
}

__declspec(dllexport) DWORD WINAPI SI_GetProductString(DWORD dwDeviceNum, LPVOID lpvDeviceString,
                                                       DWORD dwFlags) {
    if (!lpvDeviceString) return SI_INVALID_PARAMETER;
    char *out = (char *)lpvDeviceString;
    switch (dwFlags) {
        case SI_RETURN_SERIAL_NUMBER: strcpy(out, "ANTBRIDGE1"); break;
        case SI_RETURN_DESCRIPTION:   strcpy(out, "ANT USBStick2"); break;
        case SI_RETURN_LINK_NAME:     strcpy(out, "ANT USBStick2"); break;
        /* VID and PID come back as a raw 16-bit value, not text: the ANT
         * library casts the buffer straight to a USHORT and compares it to
         * 0x0FCF/0x1008. ASCII here makes it reject the stick as foreign. */
        case SI_RETURN_VID:           *(unsigned short *)out = 0x0FCF; break;
        case SI_RETURN_PID:           *(unsigned short *)out = 0x1008; break;
        default: return SI_INVALID_PARAMETER;
    }
    if (dwFlags == SI_RETURN_VID || dwFlags == SI_RETURN_PID)
        shimlog("SI_GetProductString(dev=%lu flags=%lu) -> 0x%04X", dwDeviceNum, dwFlags,
                *(unsigned short *)out);
    else
        shimlog("SI_GetProductString(dev=%lu flags=%lu) -> %s", dwDeviceNum, dwFlags, out);
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_Open(DWORD dwDevice, HANDLE *cyHandle) {
    EnterCriticalSection(&g_lock);
    if (g_sock != INVALID_SOCKET) {
        closesocket(g_sock);
        g_sock = INVALID_SOCKET;
    }
    g_sock = bridge_connect();
    LeaveCriticalSection(&g_lock);

    if (g_sock == INVALID_SOCKET) {
        shimlog("SI_Open(%lu) -> no bridge", dwDevice);
        return SI_DEVICE_NOT_FOUND;
    }
    if (cyHandle) *cyHandle = (HANDLE)(ULONG_PTR)g_sock;
    shimlog("SI_Open(%lu) -> ok", dwDevice);
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_Close(HANDLE cyHandle) {
    EnterCriticalSection(&g_lock);
    if (g_sock != INVALID_SOCKET) {
        closesocket(g_sock);
        g_sock = INVALID_SOCKET;
    }
    LeaveCriticalSection(&g_lock);
    shimlog("SI_Close");
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_Read(HANDLE cyHandle, LPVOID lpBuffer, DWORD dwBytesToRead,
                                           LPDWORD lpdwBytesReturned, LPVOID overlapped) {
    if (lpdwBytesReturned) *lpdwBytesReturned = 0;
    if (g_sock == INVALID_SOCKET) return SI_INVALID_HANDLE;
    if (!lpBuffer || !dwBytesToRead) return SI_INVALID_PARAMETER;

    DWORD tv = g_read_timeout;
    setsockopt(g_sock, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof(tv));

    int n = recv(g_sock, (char *)lpBuffer, (int)dwBytesToRead, 0);
    if (n > 0) {
        if (lpdwBytesReturned) *lpdwBytesReturned = (DWORD)n;
        shimlog("SI_Read want=%lu got=%d", dwBytesToRead, n);
        hexdump("rx", (const unsigned char *)lpBuffer, n);
        return SI_SUCCESS;
    }
    if (n == 0) {
        shimlog("SI_Read: bridge closed");
        return SI_READ_ERROR;
    }
    int err = WSAGetLastError();
    if (err == WSAETIMEDOUT) return SI_SUCCESS; /* nothing to report yet */
    shimlog("SI_Read error %d", err);
    return SI_READ_ERROR;
}

__declspec(dllexport) DWORD WINAPI SI_Write(HANDLE cyHandle, LPVOID lpBuffer, DWORD dwBytesToWrite,
                                            LPDWORD lpdwBytesWritten, LPVOID overlapped) {
    if (lpdwBytesWritten) *lpdwBytesWritten = 0;
    if (g_sock == INVALID_SOCKET) return SI_INVALID_HANDLE;
    if (!lpBuffer || !dwBytesToWrite) return SI_INVALID_PARAMETER;

    const char *p = (const char *)lpBuffer;
    DWORD left = dwBytesToWrite;
    while (left) {
        int n = send(g_sock, p, (int)left, 0);
        if (n <= 0) {
            shimlog("SI_Write error %d", WSAGetLastError());
            return SI_WRITE_ERROR;
        }
        p += n;
        left -= (DWORD)n;
    }
    if (lpdwBytesWritten) *lpdwBytesWritten = dwBytesToWrite;
    shimlog("SI_Write %lu bytes", dwBytesToWrite);
    hexdump("tx", (const unsigned char *)lpBuffer, (int)dwBytesToWrite);
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_CheckRXQueue(HANDLE cyHandle, LPDWORD lpdwNumBytesInQueue,
                                                   LPDWORD lpdwQueueStatus) {
    if (g_sock == INVALID_SOCKET) return SI_INVALID_HANDLE;

    u_long avail = 0;
    ioctlsocket(g_sock, FIONREAD, &avail);
    static int checks = 0;
    if (checks++ < 5) shimlog("SI_CheckRXQueue -> %lu waiting", (unsigned long)avail);
    if (lpdwNumBytesInQueue) *lpdwNumBytesInQueue = (DWORD)avail;
    if (lpdwQueueStatus) *lpdwQueueStatus = avail ? SI_RX_READY : SI_RX_EMPTY;
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_FlushBuffers(HANDLE cyHandle, BYTE tx, BYTE rx) {
    shimlog("SI_FlushBuffers tx=%d rx=%d", tx, rx);
    if (rx && g_sock != INVALID_SOCKET) {
        char scratch[256];
        u_long avail = 0;
        ioctlsocket(g_sock, FIONREAD, &avail);
        while (avail) {
            int n = recv(g_sock, scratch, (int)min(avail, sizeof(scratch)), 0);
            if (n <= 0) break;
            avail -= (u_long)n;
        }
    }
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_SetTimeouts(DWORD dwReadTimeout, DWORD dwWriteTimeout) {
    g_read_timeout = dwReadTimeout ? dwReadTimeout : 1000;
    g_write_timeout = dwWriteTimeout;
    shimlog("SI_SetTimeouts read=%lu write=%lu", dwReadTimeout, dwWriteTimeout);
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_GetTimeouts(LPDWORD r, LPDWORD w) {
    if (r) *r = g_read_timeout;
    if (w) *w = g_write_timeout;
    return SI_SUCCESS;
}

/* Line settings mean nothing to a socket, but the caller expects success. */
__declspec(dllexport) DWORD WINAPI SI_SetBaudRate(HANDLE cyHandle, DWORD dwBaudRate) {
    shimlog("SI_SetBaudRate %lu", dwBaudRate);
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_SetLineControl(HANDLE cyHandle, WORD wLineControl) {
    shimlog("SI_SetLineControl %u", wLineControl);
    return SI_SUCCESS;
}

__declspec(dllexport) DWORD WINAPI SI_SetFlowControl(HANDLE cyHandle, BYTE cts, BYTE rts, BYTE dtr,
                                                     BYTE dsr, BYTE dcd, BOOL xonxoff) {
    shimlog("SI_SetFlowControl");
    return SI_SUCCESS;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&g_lock);
        g_log = fopen("C:\\ant_shim.log", "a");
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
        shimlog("--- shim loaded, bridge port %d ---", bridge_port());
    } else if (reason == DLL_PROCESS_DETACH) {
        if (g_sock != INVALID_SOCKET) closesocket(g_sock);
        if (g_log) fclose(g_log);
    }
    return TRUE;
}
