pragma Singleton
import QtQuick

// World file actions shared by WORLD, FLY and EVOLVE. Panels call these; WorldDialogs (one instance, in Main) shows the
// dialogs: a name prompt for saving, "save changes?" before the open world is replaced, and the saved-worlds manager.
QtObject {
    signal saveNameRequested(var after)        // ask for a name, save, then run `after` (or nothing)
    signal unsavedCheckRequested(var action)   // ask about unsaved edits, then run `action` unless cancelled
    signal managerRequested()

    /// Save the open world: in place when it has a file, otherwise ask for a name first.
    function save(after) {
        if (WorldModel.filePath !== "") { if (WorldModel.save() && after) after() }
        else saveNameRequested(after || null)
    }
    function saveAs() { saveNameRequested(null) }
    /// Run `action` once unsaved edits to the open world are saved or discarded.
    function whenSaved(action) {
        if (WorldModel.dirty) unsavedCheckRequested(action)
        else action()
    }
    function open(name, after) { whenSaved(() => { if (WorldModel.open(name) && after) after() }) }
    function newWorld(preset) { whenSaved(() => WorldModel.newWorld(preset)) }
    function manage() { WorldModel.refreshLibrary(); managerRequested() }

    /// What FLY and EVOLVE can pick, in order: flat ground, the open world, then saved worlds (newest first, without the
    /// open world's own file). { kind: "flat" | "open" | "saved", name, label, detail }
    function choices() {
        const l = [{ kind: "flat", name: "", label: qsTr("Flat ground"), detail: qsTr("Endless flat ground, no wind") },
                   { kind: "open", name: "", label: WorldModel.name + (WorldModel.dirty ? "  •" : ""), detail: qsTr("Open in the WORLD tab") }]
        for (const w of WorldModel.libraryInfo)
            if (!w.current) l.push({ kind: "saved", name: w.name, label: w.name, detail: qsTr("Saved %1").arg(w.modified) })
        return l
    }
}
