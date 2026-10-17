#pragma once
// EvolveModel: the EVOLVE tab for QML (port of Swift App/Evolve/EvolveModel.swift on the C++ evolution core).
//
//  * The experiment document is exposed as a JSON-shaped QVariantMap (`experiment`); QML edits it with
//    set("episode.duration", 20). Every edit re-decodes through ExperimentDocument::fromJson, so the UI can only
//    ever produce documents the core accepts, and the file format stays the Swift app's.
//  * Runs execute on the core's orchestrator thread; generation records are batched through a mailbox and
//    delivered to the GUI thread at most every 100 ms (charts stay smooth with tiny generations).
//  * Replays are re-simulated on a worker (replay::record, bit-identical to training) and drawn by the viewport
//    through ReplayProvider.
#include <QObject>
#include <QQmlEngine>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include "pw/evo/run.h"
#include "replayprovider.h"

class EvolveModel : public QObject, public ReplayProvider {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantMap experiment READ experiment NOTIFY experimentChanged)
    Q_PROPERTY(QString name READ name NOTIFY experimentChanged)
    Q_PROPERTY(QString filePath READ filePath NOTIFY experimentChanged)
    Q_PROPERTY(bool dirty READ dirty NOTIFY experimentChanged)
    Q_PROPERTY(QStringList presets READ presets CONSTANT)
    Q_PROPERTY(QVariantList library READ library NOTIFY libraryChanged)
    Q_PROPERTY(QString libraryDir READ libraryDir CONSTANT)
    Q_PROPERTY(QStringList crafts READ crafts NOTIFY libraryChanged)
    Q_PROPERTY(QStringList algorithmKinds READ algorithmKinds CONSTANT)
    Q_PROPERTY(QVariantMap io READ io NOTIFY ioChanged)
    Q_PROPERTY(int geneCount READ geneCount NOTIFY ioChanged)
    // script
    Q_PROPERTY(QString scriptMessage READ scriptMessage NOTIFY scriptChanged)
    Q_PROPERTY(int scriptErrorLine READ scriptErrorLine NOTIFY scriptChanged)
    Q_PROPERTY(int scriptErrorColumn READ scriptErrorColumn NOTIFY scriptChanged)
    Q_PROPERTY(bool scriptOk READ scriptOk NOTIFY scriptChanged)
    Q_PROPERTY(bool checking READ checking NOTIFY scriptChanged)
    Q_PROPERTY(QString engineName READ engineName CONSTANT)
    // run
    Q_PROPERTY(QString runState READ runState NOTIFY runChanged)
    Q_PROPERTY(QString runID READ runID NOTIFY runChanged)
    Q_PROPERTY(QString runError READ runError NOTIFY runChanged)
    Q_PROPERTY(bool preparing READ preparing NOTIFY runChanged)
    Q_PROPERTY(bool running READ running NOTIFY runChanged)
    Q_PROPERTY(bool hasRun READ hasRun NOTIFY runChanged)
    Q_PROPERTY(QStringList runDirs READ runDirs NOTIFY runChanged)
    Q_PROPERTY(QVariantMap chart READ chart NOTIFY historyChanged)
    Q_PROPERTY(QVariantList generations READ generations NOTIFY historyChanged)
    Q_PROPERTY(QVariantMap last READ last NOTIFY historyChanged)
    Q_PROPERTY(QStringList termNames READ termNames NOTIFY historyChanged)
    Q_PROPERTY(QVariantMap archive READ archive NOTIFY historyChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    // replay
    Q_PROPERTY(bool replayActive READ replayActive NOTIFY replayChanged)
    Q_PROPERTY(bool replayBusy READ replayBusy NOTIFY replayChanged)
    Q_PROPERTY(QString replayInfo READ replayInfo NOTIFY replayChanged)
    Q_PROPERTY(QString selected READ selected NOTIFY replayChanged)
    Q_PROPERTY(double replayDuration READ replayDuration NOTIFY replayChanged)
    Q_PROPERTY(double replayTime READ replayTime WRITE setReplayTime NOTIFY replayTimeChanged)
    Q_PROPERTY(double replaySpeed MEMBER m_replaySpeed NOTIFY replayChanged)
    Q_PROPERTY(bool replayPlaying READ replayPlaying WRITE setReplayPlaying NOTIFY replayChanged)
    Q_PROPERTY(QVariantList replayOutputs READ replayOutputs NOTIFY replayTimeChanged)
public:
    explicit EvolveModel(QObject* parent);   // no default: QML must use create() (one shared instance)
    ~EvolveModel() override;
    static EvolveModel* instance();
    static EvolveModel* create(QQmlEngine*, QJSEngine*);

    QVariantMap experiment() const { return m_map; }
    QString name() const { return QString::fromStdString(m_doc.name); }
    QString filePath() const { return m_path; }
    bool dirty() const { return m_dirty; }
    QStringList presets() const;
    QVariantList library() const { return m_library; }
    QString libraryDir() const;
    QStringList crafts() const { return m_crafts; }
    QStringList algorithmKinds() const;
    QVariantMap io() const { return m_io; }
    int geneCount() const { return m_geneCount; }
    QString scriptMessage() const { return m_scriptMsg; }
    int scriptErrorLine() const { return m_errLine; }
    int scriptErrorColumn() const { return m_errCol; }
    bool scriptOk() const { return m_scriptOk; }
    bool checking() const { return m_checking; }
    QString engineName() const;
    QString runState() const;
    QString runID() const { return m_run ? QString::fromStdString(m_run->runID) : QString(); }
    QString runError() const { return m_runError; }
    bool preparing() const { return m_preparing; }
    bool running() const { return m_state == pw::evo::RunState::Running || m_state == pw::evo::RunState::Stopping; }
    bool hasRun() const { return m_run != nullptr; }
    QStringList runDirs() const { return m_runDirs; }
    QVariantMap chart() const { return m_chart; }
    QVariantList generations() const { return m_rows; }
    QVariantMap last() const;
    QStringList termNames() const { return m_terms; }
    QVariantMap archive() const { return m_archiveMap; }
    QString status() const { return m_status; }
    bool replayActive() const { return m_traj != nullptr; }
    bool replayBusy() const { return m_replayBusy; }
    QString replayInfo() const { return m_replayInfo; }
    QString selected() const { return m_selected; }
    double replayDuration() const;
    double replayTime() const { return m_replayTime; }
    void setReplayTime(double t);
    bool replayPlaying() const { return m_playing; }
    void setReplayPlaying(bool p) { if (p != m_playing) { m_playing = p; emit replayChanged(); } }
    QVariantList replayOutputs() const;

    // document
    Q_INVOKABLE void set(const QString& path, const QVariant& value);
    Q_INVOKABLE QVariant get(const QString& path) const;
    Q_INVOKABLE void newFromPreset(const QString& preset);
    /// Out-of-the-box experiment that visibly learns in ~10 s: the Trainer's network learns to hold 150 m and
    /// stay level from an air start over flat ground (population 32, 40 generations, 20 s episodes).
    Q_INVOKABLE void quickStart();
    Q_INVOKABLE bool open(const QString& pathOrUrl);
    Q_INVOKABLE bool save();
    Q_INVOKABLE bool saveAs(const QString& pathOrUrl);
    Q_INVOKABLE void duplicate();
    Q_INVOKABLE void refreshLibrary();
    Q_INVOKABLE QVariantList algorithmSchema(const QString& kind) const;
    Q_INVOKABLE void setAero(const QString& id);   // AeroModelPicker id: fast profile, "custom" or "full.<preset>"
    Q_INVOKABLE void setPreset(const QString& genomePreset);   // what evolves; adjusts controller mode + script
    Q_INVOKABLE void toggleIO(const QString& which, const QString& name, bool on);   // "inputs" | "outputs"
    Q_INVOKABLE void setInputScale(const QString& name, double scale);
    Q_INVOKABLE void addDesignGene();
    Q_INVOKABLE void removeDesignGene(int index);
    Q_INVOKABLE QStringList craftParts() const;
    Q_INVOKABLE QStringList geneFields(const QString& part) const;
    Q_INVOKABLE void addAxis();
    Q_INVOKABLE void removeAxis(int index);
    // script
    Q_INVOKABLE void checkScript();
    Q_INVOKABLE void setScript(const QString& source);
    Q_INVOKABLE QString presetScript(const QString& kind) const;   // "neural" | "design"
    // run
    Q_INVOKABLE void start();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void resume();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void newRun();
    Q_INVOKABLE void resumeDir(const QString& dir);
    // replay / export
    Q_INVOKABLE void replay(const QString& candidate);   // "g<gen>" | "cell<k>" | "best"
    Q_INVOKABLE void stopReplay();
    Q_INVOKABLE QString exportBest();                     // path of the exported craft ("" on failure)
    Q_INVOKABLE void flyWithAutopilot();
    /// Set by the FLY controller: receives the trained controller that flyWithAutopilot hands over.
    static std::function<void(std::shared_ptr<const pw::evo::ExperimentContext>, pw::evo::Genome, pw::evo::ScriptRuntimeFactory)> autopilotSink;

    // ReplayProvider
    const pw::craft::CraftDocument* replayCraft(uint64_t& version) const override;
    bool replayPoses(std::vector<pw::geo::Transform>& parts, pw::geo::Transform& origin) const override;
    const pw::craft::CraftDocument* idleCraft(uint64_t& version) const override { version = m_craftVersion; return m_craft ? &*m_craft : nullptr; }

    /// Tests / smoke: block until the run leaves Running/Stopping (processes events).
    bool waitForRun(int timeoutMs);
    bool waitForReplay(int timeoutMs);
    bool waitForCheck(int timeoutMs);
    const pw::evo::ExperimentDocument& document() const { return m_doc; }
signals:
    void experimentChanged();
    void libraryChanged();
    void ioChanged();
    void scriptChanged();
    void runChanged();
    void historyChanged();
    void statusChanged();
    void replayChanged();
    void replayTimeChanged();
    /// The exported craft (with its controller embedded) should be flown in FLY with the autopilot on.
    void flyRequested(const QString& craftPath);
private:
    void setDoc(const pw::evo::ExperimentDocument& d, bool dirty);
    void setStatus(const QString& s) { if (s != m_status) { m_status = s; emit statusChanged(); } }
    void refreshIO();
    void refreshRunDirs();
    void attach(std::unique_ptr<pw::evo::EvolutionRun> run, bool fresh);
    void drain();
    void rebuildDerived();
    void frame();
    std::optional<pw::evo::HallOfFameEntry> candidate(const QString& id) const;

    pw::evo::ExperimentDocument m_doc;
    QVariantMap m_map;
    QString m_path, m_status;
    bool m_dirty = false;
    QVariantList m_library;
    QStringList m_crafts;
    QVariantMap m_io;
    int m_geneCount = 0;
    std::optional<pw::craft::CraftDocument> m_craft;   // resolved flight craft (for IO, design genes)

    QString m_scriptMsg;
    int m_errLine = 0, m_errCol = 0;
    bool m_scriptOk = false, m_checking = false;
    std::atomic<int> m_checkToken{0};

    std::unique_ptr<pw::evo::EvolutionRun> m_run;
    pw::evo::RunState m_state = pw::evo::RunState::Idle;
    QString m_runError;
    bool m_preparing = false;
    QStringList m_runDirs;
    std::vector<pw::evo::GenerationRecord> m_history;
    std::vector<pw::evo::HallOfFameEntry> m_hall;
    std::optional<pw::evo::EliteArchive> m_archive;
    std::vector<int> m_speciesCounts;
    QStringList m_terms;
    QVariantMap m_chart, m_archiveMap;
    QVariantList m_rows;

    struct Mailbox {
        std::mutex mtx;
        std::vector<pw::evo::GenerationRecord> records;
        std::vector<pw::evo::HallOfFameEntry> hall;
        std::optional<pw::evo::EliteArchive> archive;
        bool scheduled = false;
    };
    std::shared_ptr<Mailbox> m_box = std::make_shared<Mailbox>();
    std::thread m_prep;

    std::shared_ptr<pw::evo::Trajectory> m_traj;
    std::vector<int> m_partMap;   // document part index -> trajectory part index
    uint64_t m_trajVersion = 0;
    uint64_t m_craftVersion = 0;   // bumped whenever m_craft is re-resolved
    bool m_replayBusy = false, m_playing = false;
    double m_replayTime = 0, m_replaySpeed = 1;
    QString m_replayInfo, m_selected;
    std::thread m_replayThread;
    QTimer m_timer;
    double m_lastFrame = 0;
};
