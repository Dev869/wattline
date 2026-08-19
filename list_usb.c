/* Does Wine's setupapi report our fake ANT stick? The ANT library appears to
 * cross-check the hardware ID before opening, so this is the gate to test. */
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <stdio.h>

int main(void) {
    HDEVINFO set = SetupDiGetClassDevsA(NULL, "USB", NULL, DIGCF_ALLCLASSES);
    if (set == INVALID_HANDLE_VALUE) {
        printf("SetupDiGetClassDevs failed: %lu\n", GetLastError());
        return 1;
    }
    SP_DEVINFO_DATA info = {sizeof(info)};
    int found = 0, ant = 0;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &info); i++) {
        char id[512] = {0};
        if (CM_Get_Device_IDA(info.DevInst, id, sizeof(id), 0) == CR_SUCCESS) {
            found++;
            if (strstr(id, "VID_0FCF")) { ant++; printf("ANT MATCH: %s\n", id); }
            else if (found <= 8) printf("  device: %s\n", id);
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    printf("\n%d USB devices visible, %d matching VID_0FCF\n", found, ant);
    return ant ? 0 : 2;
}
