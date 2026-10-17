#import <Metal/Metal.h>
#include <QQuickWindow>
#include <QtQuick/qsgtexture_platform.h>
#include "gpuviewport.h"
#include "pw/gpu.h"

QSGTexture* pwWrapNativeTexture(QQuickWindow* w, pw::gpu::Texture* t) {
    return QNativeInterface::QSGMetalTexture::fromNative((__bridge id<MTLTexture>)t->native(), w, QSize(t->width(), t->height()));
}
