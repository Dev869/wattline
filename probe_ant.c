/* Drive ANT_Receiver.dll directly to test the dongle end to end in seconds.
 *
 * Crash dialogs are suppressed and unhandled faults kill the process quietly:
 * the exported signatures are guesses, and a guess must never put a Wine error
 * box on the user's screen.
 */
#include <windows.h>
#include <stdio.h>

typedef void *(WINAPI *fn_init)(const char *, int, int, int);
typedef int(WINAPI *fn_any)(void *, void *, void *, void *);

static LONG WINAPI quiet_death(EXCEPTION_POINTERS *info) {
    printf("  (crashed at %p - wrong signature, ignore)\n", info->ExceptionRecord->ExceptionAddress);
    fflush(stdout);
    TerminateProcess(GetCurrentProcess(), 3);
    return EXCEPTION_EXECUTE_HANDLER;
}

int main(void) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    SetUnhandledExceptionFilter(quiet_death);

    const char *dir = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Grand Theft Auto V\\scripts";
    SetCurrentDirectoryA(dir);
    SetDllDirectoryA(dir);

    HMODULE lib = LoadLibraryA("ANT_Receiver.dll");
    if (!lib) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 1; }
    printf("ANT_Receiver.dll loaded\n");
    fflush(stdout);

    fn_init init = (fn_init)GetProcAddress(lib, "Initialize");
    fn_any start = (fn_any)GetProcAddress(lib, "Start");
    if (!init) { printf("no Initialize export\n"); return 1; }

    /* The DLL writes "<dir>\<stamp>_ANT_Receiver.log", so the first argument
     * is almost certainly where to put it. */
    const char *logs = "C:\\users\\crossover\\Documents\\Rockstar Games\\GTA V\\Logs";
    printf("calling Initialize(logdir)...\n");
    fflush(stdout);
    void *ctx = init(logs, 0, 0, 0);
    printf("Initialize -> %p\n", ctx);
    fflush(stdout);

    /* Initialize hands back a context; everything else takes it as arg one. */
    if (start) {
        printf("Start(ctx) -> %d\n", start(ctx, NULL, NULL, NULL));
        fflush(stdout);
    }
    Sleep(4000);
    printf("done\n");
    return 0;
}
