#include <assert.h>
#include <stdio.h>
#include "../watchlog.h"

int main(void) {
    assert(watchlog_should_stream(0, 0));
    assert(watchlog_should_stream(-1, 0));
    assert(watchlog_should_stream(-1, 1));
    assert(!watchlog_should_stream(0, 1));
    const char *prefix = "Oct 26 10:43:25 phone bluetoothd(CoreUtils)[106] <Notice>: "
        "Power source updated CBPowerSource Nm 'Apple Watch', AcCa Watch, Present yes, Battery ";
    char line[1024];
    const char *values[] = { "-66%", "+66%", "0%", "100%", "101%", "-999%", "unknown", "66x", "%" };
    int expected[] = { 66, 66, 0, 100, -1, -1, -1, -1, -1 };
    int charging[] = { 0, 1, -1, -1, -1, -1, -1, -1, -1 };
    for (size_t i = 0; i < sizeof expected / sizeof expected[0]; i++) {
        snprintf(line, sizeof line, "%s%s", prefix, values[i]);
        assert(watchlog_level(line) == expected[i]);
        assert(watchlog_charging(line) == charging[i]);
    }
    assert(watchlog_level("bluetoothd(CoreUtils) Power source updated CBPowerSource AcCa Headphones, Present yes, Battery -66%") == -1);
    assert(watchlog_level("bluetoothd(CoreUtils) Power source updated CBPowerSource AcCa Watch, Present no, Battery -66%") == -1);
    assert(watchlog_level("app: AcCa Watch, Present yes, Battery -66%") == -1);
    assert(watchlog_charging("bluetoothd(CoreUtils) Power source updated CBPowerSource AcCa Headphones, Present yes, Battery +66%") == -1);
    assert(watchlog_charging("bluetoothd(CoreUtils) Power source updated CBPowerSource AcCa Watch, Present no, Battery +66%") == -1);
    puts("watchlog tests passed");
}
