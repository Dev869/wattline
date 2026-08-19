/* Windows-side check: load the shim exactly the way GT Bike V's ANT library
 * does, and confirm a real ANT conversation crosses into macOS and back.
 *
 * Build: make test-exe     Run: make check-bottle
 */

#include <windows.h>
#include <stdio.h>

typedef DWORD(WINAPI *fn_num)(LPDWORD);
typedef DWORD(WINAPI *fn_prod)(DWORD, LPVOID, DWORD);
typedef DWORD(WINAPI *fn_open)(DWORD, HANDLE *);
typedef DWORD(WINAPI *fn_rw)(HANDLE, LPVOID, DWORD, LPDWORD, LPVOID);
typedef DWORD(WINAPI *fn_timeouts)(DWORD, DWORD);

static FILE *out;
#define SAY(...)                  \
    do {                          \
        printf(__VA_ARGS__);      \
        fprintf(out, __VA_ARGS__);\
        fflush(out);              \
    } while (0)

int main(void) {
    out = fopen("C:\\shim_test.txt", "w");

    HMODULE lib = LoadLibraryA("DSI_SiUSBXp_3_1.DLL");
    if (!lib) {
        SAY("FAIL: LoadLibrary error %lu\n", GetLastError());
        return 1;
    }
    SAY("loaded DSI_SiUSBXp_3_1.DLL\n");

    fn_num get_num = (fn_num)GetProcAddress(lib, "SI_GetNumDevices");
    fn_prod get_prod = (fn_prod)GetProcAddress(lib, "SI_GetProductString");
    fn_open si_open = (fn_open)GetProcAddress(lib, "SI_Open");
    fn_rw si_read = (fn_rw)GetProcAddress(lib, "SI_Read");
    fn_rw si_write = (fn_rw)GetProcAddress(lib, "SI_Write");
    fn_timeouts si_timeouts = (fn_timeouts)GetProcAddress(lib, "SI_SetTimeouts");
    if (!get_num || !get_prod || !si_open || !si_read || !si_write || !si_timeouts) {
        SAY("FAIL: missing exports\n");
        return 1;
    }

    DWORD devices = 0;
    if (get_num(&devices) != 0 || devices == 0) {
        SAY("FAIL: no ANT device (is ant_stick.py running?)\n");
        return 1;
    }
    SAY("SI_GetNumDevices  -> %lu\n", devices);

    char desc[256] = {0};
    get_prod(0, desc, 1);
    SAY("SI_GetProductString -> %s\n", desc);

    HANDLE h = NULL;
    if (si_open(0, &h) != 0) {
        SAY("FAIL: SI_Open\n");
        return 1;
    }
    SAY("SI_Open           -> ok\n");
    si_timeouts(2000, 2000);

    /* Reset system, then ask for capabilities - the ANT library's first moves */
    BYTE reset[] = {0xA4, 0x01, 0x4A, 0x00, 0xEF};
    BYTE caps[] = {0xA4, 0x02, 0x4D, 0x00, 0x54, 0xBF};
    DWORD wrote = 0;
    si_write(h, reset, sizeof(reset), &wrote, NULL);
    Sleep(200);
    si_write(h, caps, sizeof(caps), &wrote, NULL);

    BYTE buf[256];
    DWORD got = 0, total = 0;
    int saw_startup = 0, saw_caps = 0;
    for (int i = 0; i < 10 && !(saw_startup && saw_caps); i++) {
        if (si_read(h, buf + total, sizeof(buf) - total, &got, NULL) != 0) break;
        total += got;
        for (DWORD j = 0; j + 2 < total; j++) {
            if (buf[j] != 0xA4) continue;
            if (buf[j + 2] == 0x6F) saw_startup = 1;
            if (buf[j + 2] == 0x54) saw_caps = 1;
        }
    }

    SAY("read %lu bytes:", total);
    for (DWORD i = 0; i < total; i++) SAY(" %02X", buf[i]);
    SAY("\n");

    if (saw_startup && saw_caps) {
        SAY("\nPASS: bottle -> macOS ANT bridge is working\n");
        return 0;
    }
    SAY("\nFAIL: startup=%d capabilities=%d\n", saw_startup, saw_caps);
    return 1;
}
