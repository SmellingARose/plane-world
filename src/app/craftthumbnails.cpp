#include "craftthumbnails.h"
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QMetaObject>
#include "pw/craft/library.h"
#include "pw/gpu.h"
#include "pw/render/thumbnail.h"

namespace pc = pw::craft;

// Lives on the worker thread; the device and renderer are made on first use there.
class CraftThumbnailWorker : public QObject {
    Q_OBJECT
public:
    void render(const QString& key, const QString& path, const std::shared_ptr<const pc::CraftDocument>& doc) {
        bool ok = false;
        if (!m_broken && !m_thumbs) {
            std::string err;
            m_dev = pw::gpu::createDevice({}, &err);
            if (m_dev) m_thumbs = pw::render::ThumbnailRenderer::create(*m_dev, &err);
            if (!m_thumbs) { m_broken = true; qWarning("craft thumbnails: no GPU renderer (%s)", err.c_str()); emit unavailable(); }
        }
        if (m_thumbs) {
            std::vector<uint8_t> rgba;
            std::string err;
            const int w = CraftThumbnails::kWidth * 2, h = CraftThumbnails::kHeight * 2;
            if (m_thumbs->render(*doc, w, h, rgba, &err)) {
                const QImage img = QImage(rgba.data(), w, h, w * 4, QImage::Format_RGBA8888)
                                       .convertToFormat(QImage::Format_RGB32)
                                       .scaled(CraftThumbnails::kWidth, CraftThumbnails::kHeight, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
                const QString part = path + ".part";   // written whole, then renamed: readers never see half a file
                QFile::remove(part);
                if (img.save(part, "PNG")) {
                    QFile::remove(path);
                    ok = QFile::rename(part, path);
                }
                if (ok) pc::library::removeThumbnails(key.toStdString(), path.toStdString());
            } else {
                qWarning("craft thumbnail %s: %s", qPrintable(key), err.c_str());
            }
        }
        emit done(key, path, ok);
    }
signals:
    void done(const QString& key, const QString& path, bool ok);
    void unavailable();
private:
    std::unique_ptr<pw::gpu::Device> m_dev;
    std::unique_ptr<pw::render::ThumbnailRenderer> m_thumbs;
    bool m_broken = false;
};

CraftThumbnails::CraftThumbnails(QObject* parent) : QObject(parent) {
    m_worker = new CraftThumbnailWorker;
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(m_worker, &CraftThumbnailWorker::done, this, [this](const QString& key, const QString& path, bool ok) {
        m_pending.remove(path);
        if (ok) emit ready(key, path);
    });
    connect(m_worker, &CraftThumbnailWorker::unavailable, this, [this] { m_unavailable = true; emit unavailableChanged(); });
    m_thread.setObjectName("craft thumbnails");
    m_thread.start(QThread::LowPriority);
}

CraftThumbnails::~CraftThumbnails() {
    m_thread.quit();
    m_thread.wait();
}

QString CraftThumbnails::cached(const QString& key, const pc::CraftDocument& doc) {
    const QString path = QString::fromStdString(pc::library::thumbnailPath(key.toStdString(), doc));
    return QFileInfo::exists(path) ? path : QString();
}

QString CraftThumbnails::request(const QString& key, const pc::CraftDocument& doc) {
    const QString path = QString::fromStdString(pc::library::thumbnailPath(key.toStdString(), doc));
    if (QFileInfo::exists(path)) return path;
    if (m_unavailable || m_pending.contains(path)) return {};
    m_pending.insert(path);
    auto copy = std::make_shared<const pc::CraftDocument>(doc);
    QMetaObject::invokeMethod(m_worker, [w = m_worker, key, path, copy] { w->render(key, path, copy); }, Qt::QueuedConnection);
    return {};
}

#include "craftthumbnails.moc"
