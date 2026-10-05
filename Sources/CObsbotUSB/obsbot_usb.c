#include "obsbot_usb.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

#define UVC_SET_CUR 0x01
#define UVC_GET_CUR 0x81

// First matching USB device service, or 0. Caller releases.
static io_service_t find_device(uint16_t vid, uint16_t pid) {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) return 0;
    // SInt32 so PIDs above 0x7FFF (the Tiny 2 is 0xFEF8) don't overflow.
    SInt32 v = vid, p = pid;
    CFNumberRef vn = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);
    CFNumberRef pn = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &p);
    CFDictionarySetValue(matching, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(matching, CFSTR(kUSBProductID), pn);
    CFRelease(vn);
    CFRelease(pn);
    // Consumes `matching`.
    return IOServiceGetMatchingService(kIOMainPortDefault, matching);
}

// bInterfaceNumber of the VideoControl interface (class 0x0E, subclass 0x01).
// It forms the low byte of wIndex. Defaults to 0, which is what the Tiny 2 uses.
static uint8_t video_control_interface(io_service_t device) {
    uint8_t num = 0;
    io_iterator_t iter = 0;
    if (IORegistryEntryCreateIterator(device, kIOServicePlane,
                                      kIORegistryIterateRecursively,
                                      &iter) != KERN_SUCCESS)
        return num;
    io_service_t child;
    while ((child = IOIteratorNext(iter))) {
        CFNumberRef cls = IORegistryEntryCreateCFProperty(
            child, CFSTR(kUSBInterfaceClass), kCFAllocatorDefault, 0);
        CFNumberRef sub = IORegistryEntryCreateCFProperty(
            child, CFSTR(kUSBInterfaceSubClass), kCFAllocatorDefault, 0);
        CFNumberRef ifn = IORegistryEntryCreateCFProperty(
            child, CFSTR(kUSBInterfaceNumber), kCFAllocatorDefault, 0);
        int c = -1, s = -1, n = -1;
        if (cls) CFNumberGetValue(cls, kCFNumberIntType, &c);
        if (sub) CFNumberGetValue(sub, kCFNumberIntType, &s);
        if (ifn) CFNumberGetValue(ifn, kCFNumberIntType, &n);
        if (cls) CFRelease(cls);
        if (sub) CFRelease(sub);
        if (ifn) CFRelease(ifn);
        IOObjectRelease(child);
        if (c == kUSBVideoInterfaceClass && s == kUSBVideoControlSubClass && n >= 0) {
            num = (uint8_t)n;
            break;
        }
    }
    IOObjectRelease(iter);
    return num;
}

static IOReturn open_device(io_service_t service, IOUSBDeviceInterface182 ***out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != kIOReturnSuccess || !plugin) return kr ? kr : kIOReturnError;

    IOUSBDeviceInterface182 **dev = NULL;
    HRESULT res = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&dev);
    (*plugin)->Release(plugin);
    if (res != S_OK || !dev) return kIOReturnError;

    kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) {
        (*dev)->Release(dev);
        return kr;
    }
    *out = dev;
    return kIOReturnSuccess;
}

static int xu_transfer(uint16_t vid, uint16_t pid, uint8_t request_type,
                       uint8_t request, uint8_t unit, uint8_t selector,
                       void *buf, uint16_t len) {
    io_service_t service = find_device(vid, pid);
    if (!service) return kIOReturnNoDevice;
    uint8_t ifnum = video_control_interface(service);

    IOUSBDeviceInterface182 **dev = NULL;
    IOReturn kr = open_device(service, &dev);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess) return kr;

    IOUSBDevRequestTO req = {0};
    req.bmRequestType = request_type;
    req.bRequest = request;
    req.wValue = (uint16_t)(selector << 8);
    req.wIndex = (uint16_t)((unit << 8) | ifnum);
    req.wLength = len;
    req.pData = buf;
    req.noDataTimeout = 1000;
    req.completionTimeout = 1000;
    kr = (*dev)->DeviceRequestTO(dev, &req);

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return kr;
}

int obsbot_xu_set(uint16_t vid, uint16_t pid, uint8_t unit, uint8_t selector,
                  const uint8_t *buf, uint16_t len) {
    return xu_transfer(vid, pid, 0x21, UVC_SET_CUR, unit, selector, (void *)buf, len);
}

int obsbot_xu_get(uint16_t vid, uint16_t pid, uint8_t unit, uint8_t selector,
                  uint8_t *buf, uint16_t len) {
    return xu_transfer(vid, pid, 0xA1, UVC_GET_CUR, unit, selector, buf, len);
}

int obsbot_present(uint16_t vid, uint16_t pid) {
    io_service_t service = find_device(vid, pid);
    if (!service) return 0;
    IOObjectRelease(service);
    return 1;
}
