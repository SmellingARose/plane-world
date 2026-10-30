#pragma once
// CraftThumbnails: pictures for BUILD's craft library cards. Each picture is the craft rendered offscreen by
// pw::render::ThumbnailRenderer (the BUILD ground and lighting, BUILD's default 3/4 view) on a worker thread with its
// own GPU device, so nothing waits on it and Qt Quick's device is untouched. Pictures are cached as PNG files under
// <library root>/thumbnails, named by key + shape hash (pw::craft::library::thumbnailPath): a cached picture is
// reused straight away, a changed craft gets a new one and its old pictures are removed.
#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>
#include <QThread>
#include <memory>
#include "pw/craft/document.h"

class CraftThumbnailWorker;

class CraftThumbnails : public QObject {
    Q_OBJECT
public:
    explicit CraftThumbnails(QObject* parent = nullptr);
    ~CraftThumbnails() override;
    /// Picture size on disk (logical card size x 2 for HiDPI); rendered at twice this and scaled down.
    static constexpr int kWidth = 480, kHeight = 300;
    /// The cached picture for `key` (e.g. "built-in/Trainer" or a saved craft's file stem) if it exists, else "".
    static QString cached(const QString& key, const pw::craft::CraftDocument& doc);
    /// cached() or, when missing, queues a render and returns "" (ready() follows).
    QString request(const QString& key, const pw::craft::CraftDocument& doc);
    /// True once the GPU could not be used: no more pictures will come.
    bool unavailable() const { return m_unavailable; }
signals:
    void ready(const QString& key, const QString& path);
    void unavailableChanged();
private:
    QThread m_thread;
    CraftThumbnailWorker* m_worker = nullptr;
    QSet<QString> m_pending;   // picture paths queued or rendering
    bool m_unavailable = false;
};
