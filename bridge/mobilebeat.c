/*
 * mobilebeat — battery monitor using Apple's MobileDevice.framework.
 *
 * Unlike libimobiledevice/usbmuxd, MobileDevice follows CoreDevice's modern
 * RemotePairing transport and therefore continues to see iOS 17+ devices on
 * Wi-Fi (including devices advertising a supportsRP Bonjour identity).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_DEVS 8
#define POLL_S 30

typedef struct am_device *am_device_t;
typedef struct am_device_notification *am_device_notification_t;
typedef struct {
    am_device_t device;
    unsigned int msg;
    am_device_notification_t subscription;
} am_device_notification_callback_info;

extern int AMDeviceNotificationSubscribe(
    void (*callback)(am_device_notification_callback_info *, void *),
    unsigned int, unsigned int, void *, am_device_notification_t *);
extern void AMDeviceRetain(am_device_t);
extern void AMDeviceRelease(am_device_t);
extern CFStringRef AMDeviceCopyDeviceIdentifier(am_device_t);
extern int AMDeviceConnect(am_device_t);
extern int AMDeviceDisconnect(am_device_t);
extern int AMDeviceIsPaired(am_device_t);
extern int AMDeviceValidatePairing(am_device_t);
extern int AMDeviceStartSession(am_device_t);
extern int AMDeviceStopSession(am_device_t);
extern CFTypeRef AMDeviceCopyValue(am_device_t, CFStringRef, CFStringRef);
extern int AMDeviceSecureStartService(am_device_t, CFStringRef, CFDictionaryRef, void **);
extern uint64_t AMDServiceConnectionSendMessage(void *, CFPropertyListRef, CFPropertyListFormat);
extern uint64_t AMDServiceConnectionReceiveMessage(void *, CFPropertyListRef *, CFPropertyListFormat *);
extern void AMDServiceConnectionInvalidate(void *);

typedef struct {
    am_device_t device;
    char udid[256];
    int in_use;
    int failures;
} Dev;

static Dev devs[MAX_DEVS];

static void cfstr(CFStringRef value, char *out, size_t cap) {
    out[0] = '\0';
    if (value)
        CFStringGetCString(value, out, cap, kCFStringEncodingUTF8);
}

static void json_string(char *dst, size_t cap, const char *src) {
    size_t j = 0;
    for (size_t i = 0; src && src[i] && j + 3 < cap; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '"' || c == '\\') dst[j++] = '\\';
        if (c >= 0x20) dst[j++] = (char)c;
    }
    dst[j] = '\0';
}

static int dict_int(CFDictionaryRef dict, CFStringRef key, int fallback) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return fallback;
    int result = fallback;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    return result;
}

static int dict_bool(CFDictionaryRef dict, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    return value && CFGetTypeID(value) == CFBooleanGetTypeID()
        && CFBooleanGetValue((CFBooleanRef)value);
}

static CFPropertyListRef companion_command(am_device_t device, CFDictionaryRef command) {
    void *connection = NULL;
    int service_err = AMDeviceSecureStartService(device, CFSTR("com.apple.companion_proxy"),
                                                  NULL, &connection);
    if (service_err != 0 || !connection) {
        fprintf(stderr, "companion service error=%d\n", service_err);
        fflush(stderr);
        return NULL;
    }
    CFPropertyListRef reply = NULL;
    CFPropertyListFormat format = kCFPropertyListBinaryFormat_v1_0;
    AMDServiceConnectionSendMessage(connection, command, format);
    AMDServiceConnectionReceiveMessage(connection, &reply, &format);
    /* Invalidate alone does not close the socket: the connection is a CF object
     * that owns its fd until it is deallocated. Every companion_proxy query used
     * to leak one socket, so after a day or two the process held thousands of
     * stale fds and the service stopped answering — the Watch row then vanished. */
    AMDServiceConnectionInvalidate(connection);
    CFRelease((CFTypeRef)connection);
    return reply;
}

static CFTypeRef unwrap_value(CFTypeRef value) {
    if (value && CFGetTypeID(value) == CFArrayGetTypeID() &&
        CFArrayGetCount((CFArrayRef)value) > 0)
        return CFArrayGetValueAtIndex((CFArrayRef)value, 0);
    return value;
}

static CFPropertyListRef watch_value(am_device_t device, CFStringRef udid, CFStringRef key) {
    const void *keys[] = { CFSTR("Command"), CFSTR("GetValueGizmoUDIDKey"), CFSTR("GetValueKeyKey") };
    const void *values[] = { CFSTR("GetValueFromRegistry"), udid, key };
    CFDictionaryRef command = CFDictionaryCreate(NULL, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFPropertyListRef reply = companion_command(device, command);
    CFRelease(command);
    if (!reply || CFGetTypeID(reply) != CFDictionaryGetTypeID()) {
        if (reply) CFRelease(reply);
        return NULL;
    }
    CFTypeRef values_dict = CFDictionaryGetValue((CFDictionaryRef)reply,
                                                  CFSTR("RetrievedValueDictionary"));
    CFTypeRef value = values_dict && CFGetTypeID(values_dict) == CFDictionaryGetTypeID()
        ? CFDictionaryGetValue((CFDictionaryRef)values_dict, key) : NULL;
    CFPropertyListRef copy = value ? CFPropertyListCreateDeepCopy(NULL, value,
        kCFPropertyListImmutable) : NULL;
    CFRelease(reply);
    return copy;
}

static void poll_watch(am_device_t device) {
    const void *keys[] = { CFSTR("Command") };
    const void *values[] = { CFSTR("GetDeviceRegistry") };
    CFDictionaryRef command = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFPropertyListRef reply = companion_command(device, command);
    CFRelease(command);
    if (!reply || CFGetTypeID(reply) != CFDictionaryGetTypeID()) {
        if (reply) CFRelease(reply);
        return;
    }
    CFTypeRef registry = CFDictionaryGetValue((CFDictionaryRef)reply, CFSTR("PairedDevicesArray"));
    if (!registry || CFGetTypeID(registry) != CFArrayGetTypeID() ||
        CFArrayGetCount((CFArrayRef)registry) == 0) {
        CFRelease(reply);
        return;
    }
    CFTypeRef watch_udid = CFArrayGetValueAtIndex((CFArrayRef)registry, 0);
    if (CFGetTypeID(watch_udid) != CFStringGetTypeID()) {
        CFRelease(reply);
        return;
    }
    CFRetain(watch_udid);
    CFRelease(reply);

    CFPropertyListRef level_raw = watch_value(device, watch_udid, CFSTR("BatteryCurrentCapacity"));
    CFPropertyListRef charging_raw = watch_value(device, watch_udid, CFSTR("BatteryIsCharging"));
    CFPropertyListRef name_raw = watch_value(device, watch_udid, CFSTR("DeviceName"));
    CFRelease(watch_udid);

    CFTypeRef level_value = unwrap_value(level_raw);
    CFTypeRef charging_value = unwrap_value(charging_raw);
    CFTypeRef name_value = unwrap_value(name_raw);
    int level = -1, charging = 0;
    if (level_value && CFGetTypeID(level_value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)level_value, kCFNumberIntType, &level);
    if (charging_value && CFGetTypeID(charging_value) == CFBooleanGetTypeID())
        charging = CFBooleanGetValue((CFBooleanRef)charging_value);
    char name[256] = "Apple Watch", safe_name[512];
    if (name_value && CFGetTypeID(name_value) == CFStringGetTypeID())
        cfstr((CFStringRef)name_value, name, sizeof name);
    json_string(safe_name, sizeof safe_name, name);
    if (level >= 0) {
        printf("{\"type\":\"watch\",\"name\":\"%s\",\"level\":%d,\"charging\":%s}\n",
               safe_name, level, charging ? "true" : "false");
        fflush(stdout);
    }
    if (name_raw) CFRelease(name_raw);
    if (charging_raw) CFRelease(charging_raw);
    if (level_raw) CFRelease(level_raw);
}

static int poll_device(Dev *slot) {
    am_device_t device = slot->device;
    if (!device || AMDeviceConnect(device) != 0) return -1;
    if (!AMDeviceIsPaired(device) || AMDeviceValidatePairing(device) != 0) {
        AMDeviceDisconnect(device);
        return -1;
    }
    if (AMDeviceStartSession(device) != 0) {
        AMDeviceDisconnect(device);
        return -1;
    }

    CFStringRef name_value = (CFStringRef)AMDeviceCopyValue(device, NULL, CFSTR("DeviceName"));
    CFStringRef class_value = (CFStringRef)AMDeviceCopyValue(device, NULL, CFSTR("DeviceClass"));
    CFDictionaryRef battery = (CFDictionaryRef)AMDeviceCopyValue(
        device, CFSTR("com.apple.mobile.battery"), NULL);

    char name[256], klass[64], safe_name[512], safe_udid[512];
    cfstr(name_value, name, sizeof name);
    cfstr(class_value, klass, sizeof klass);
    json_string(safe_name, sizeof safe_name, name);
    json_string(safe_udid, sizeof safe_udid, slot->udid);

    int level = -1, charging = 0;
    if (battery && CFGetTypeID(battery) == CFDictionaryGetTypeID()) {
        level = dict_int(battery, CFSTR("BatteryCurrentCapacity"), -1);
        charging = dict_bool(battery, CFSTR("BatteryIsCharging"));
    }

    if (level >= 0) {
        const char *type = strcasecmp(klass, "iPad") == 0 ? "pad" : "phone";
        printf("{\"type\":\"%s\",\"udid\":\"%s\",\"name\":\"%s\",\"level\":%d,\"charging\":%s}\n",
               type, safe_udid, safe_name, level, charging ? "true" : "false");
        fflush(stdout);
        if (strcmp(type, "phone") == 0) poll_watch(device);
    }

    if (battery) CFRelease(battery);
    if (class_value) CFRelease(class_value);
    if (name_value) CFRelease(name_value);
    AMDeviceStopSession(device);
    AMDeviceDisconnect(device);
    return level >= 0 ? 0 : -1;
}

static void poll_all(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    for (int i = 0; i < MAX_DEVS; i++) {
        if (!devs[i].in_use) continue;
        if (poll_device(&devs[i]) == 0) devs[i].failures = 0;
        else if (++devs[i].failures >= 3) {
            AMDeviceRelease(devs[i].device);
            memset(&devs[i], 0, sizeof devs[i]);
        }
    }
}

static void on_device(am_device_notification_callback_info *event, void *info) {
    (void)info;
    if (event->msg != 1 || !event->device) return;

    CFStringRef udid_value = AMDeviceCopyDeviceIdentifier(event->device);
    char udid[256];
    cfstr(udid_value, udid, sizeof udid);
    if (udid_value) CFRelease(udid_value);
    if (!udid[0]) return;

    Dev *slot = NULL;
    for (int i = 0; i < MAX_DEVS; i++) {
        if (devs[i].in_use && strcmp(devs[i].udid, udid) == 0) {
            slot = &devs[i];
            AMDeviceRelease(slot->device);
            break;
        }
        if (!slot && !devs[i].in_use) slot = &devs[i];
    }
    if (!slot) return;

    memset(slot, 0, sizeof *slot);
    slot->device = event->device;
    AMDeviceRetain(slot->device);
    strncpy(slot->udid, udid, sizeof(slot->udid) - 1);
    slot->in_use = 1;
    poll_device(slot);
}

int main(void) {
    am_device_notification_t subscription = NULL;
    if (AMDeviceNotificationSubscribe(on_device, 0, 0, NULL, &subscription) != 0)
        return 1;

    CFRunLoopTimerContext context = {0};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + POLL_S, POLL_S, 0, 0, poll_all, &context);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    CFRunLoopRun();
    CFRelease(timer);
    return 0;
}
