#import <Metal/Metal.h>
#include <QQuickWindow>
#include <QtQuick/qsgtexture_platform.h>
#include "gpuviewport.h"
#include "pw/gpu.h"

QSGTexture* pwWrapNativeTexture(QQuickWindow* w, const pw::gpu::NativeTarget& t) {
    return QNativeInterface::QSGMetalTexture::fromNative((__bridge id<MTLTexture>)t.texture, w, QSize(t.width, t.height));
}
