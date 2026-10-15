// macOS half of the DXMT shared-texture test: opens the texture DXMT registered under a
// bootstrap name, the way DXMT's own winemetal imports it, and reads back each layer's first
// pixel. Expect layer 0 red and layer 1 green.
//
// clang -fobjc-arc open_texture.m -framework Metal -framework Foundation -o open_texture
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <servers/bootstrap.h>

@interface MTLSharedTextureHandle ()
- (MTLSharedTextureHandle *)initWithMachPort:(mach_port_t)port;
@end

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: open_texture DXMT_shared_resource_...\n"); return 2; }
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, argv[1], &port);
    if (kr != KERN_SUCCESS) { printf("FAIL bootstrap_look_up: %d\n", kr); return 1; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    MTLSharedTextureHandle *handle = [[MTLSharedTextureHandle alloc] initWithMachPort:port];
    id<MTLTexture> tex = [dev newSharedTextureWithHandle:handle];
    if (!tex) { printf("FAIL newSharedTextureWithHandle\n"); return 1; }
    printf("opened: type %lu, %lux%lu, %lu layers, format %lu, iosurface %p\n", (unsigned long)tex.textureType,
           (unsigned long)tex.width, (unsigned long)tex.height, (unsigned long)tex.arrayLength,
           (unsigned long)tex.pixelFormat, tex.iosurface);

    id<MTLCommandQueue> q = [dev newCommandQueue];
    for (NSUInteger layer = 0; layer < tex.arrayLength; layer++) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tex.pixelFormat
                                                                                     width:1 height:1 mipmapped:NO];
        d.storageMode = MTLStorageModeShared;
        id<MTLTexture> px = [dev newTextureWithDescriptor:d];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:tex sourceSlice:layer sourceLevel:0 sourceOrigin:MTLOriginMake(10, 10, 0)
                sourceSize:MTLSizeMake(1, 1, 1) toTexture:px destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        uint8_t rgba[4];
        [px getBytes:rgba bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        printf("layer %lu pixel: %u %u %u %u\n", (unsigned long)layer, rgba[0], rgba[1], rgba[2], rgba[3]);
    }
    return 0;
}
