#ifndef OBSBOT_USB_H
#define OBSBOT_USB_H

#include <stdint.h>

// Raw UVC Extension Unit access to an OBSBOT camera over the USB default
// control endpoint.
//
// macOS's UVCAssistant owns the camera's UVC interfaces, but not the device, so
// we open the device itself and issue class requests with an interface
// recipient. The camera keeps streaming to other apps while we do this.
//
// Each call opens the device, does one transfer and closes it again, so we never
// hold the device open and block other clients such as OBSBOT Center.
//
// Returns 0 on success, or an IOReturn code (kIOReturnNoDevice if no matching
// camera is attached).

int obsbot_xu_set(uint16_t vid, uint16_t pid, uint8_t unit, uint8_t selector,
                  const uint8_t *buf, uint16_t len);

int obsbot_xu_get(uint16_t vid, uint16_t pid, uint8_t unit, uint8_t selector,
                  uint8_t *buf, uint16_t len);

// 1 if a device with this VID/PID is attached, else 0. Doesn't open it.
int obsbot_present(uint16_t vid, uint16_t pid);

#endif
