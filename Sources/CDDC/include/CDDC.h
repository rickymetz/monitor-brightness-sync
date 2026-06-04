#ifndef CDDC_H
#define CDDC_H

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

// Private IOKit AV-service API used to talk DDC/CI to external displays on
// Apple Silicon. The symbols live in IOKit.framework but are not declared in
// any public header, so we declare them here and link against IOKit.
typedef CFTypeRef IOAVService;

extern IOAVService IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);

#endif /* CDDC_H */
