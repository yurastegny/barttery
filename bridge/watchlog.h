#ifndef BARTTERY_WATCHLOG_H
#define BARTTERY_WATCHLOG_H

#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* Only accept a present Watch power-source update, never phone/AirPods data. */
static int watchlog_level(const char *line) {
    if (!strstr(line, "bluetoothd(CoreUtils)") ||
        !strstr(line, "Power source updated CBPowerSource ") ||
        !strstr(line, "AcCa Watch,") || !strstr(line, "Present yes,")) return -1;
    const char *p = strstr(line, "Battery ");
    if (!p) return -1;
    p += strlen("Battery ");
    if (*p == '-' || *p == '+') p++;
    if (!isdigit((unsigned char)*p)) return -1;
    char *end = NULL;
    long level = strtol(p, &end, 10);
    if (*end != '%' || level < 0 || level > 100) return -1;
    return (int)level;
}

/* Observed Watch power events use Battery +N% on the charger and -N% off it.
 * An unsigned value has an unknown charging state, not "not charging". */
static int watchlog_charging(const char *line) {
    if (watchlog_level(line) < 0) return -1;
    const char *p = strstr(line, "Battery ") + strlen("Battery ");
    return *p == '+' ? 1 : (*p == '-' ? 0 : -1);
}
#endif
