import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

//! Flash-backed ACK-tracked send queue.
//!
//! Implements contracts C-040, C-041 per SPECIFICATION.md §7.5.
//! Targets FR-015 (purge on ACK), FR-016 (survive restart), FR-017 (60 entries).
//!
//! Storage layout: key "pq" → Array of {"pi" => Number, "d" => String}.
//!
//! Capacity: MAX_ENTRIES = 60 (~54 KB at ~900 B/packet).
//! Larger values risk OOM on fēnix 8 (~128 KB per-app budget).
//!
//! INVARIANTS:
//!  - _entries.size() <= MAX_ENTRIES after every push.
//!  - After ackUpTo(N), no entry has pi <= N (INV-007).
class PersistentQueue {

    private const STORAGE_KEY = "pq";
    private const MAX_ENTRIES = 60;
    private const FLUSH_EVERY = 10;  // push-to-flash cadence

    private var _entries as Array;
    private var _dirty   as Number;

    function initialize() {
        _dirty   = 0;
        _entries = [] as Array;
        _loadFromStorage();
    }

    //! C-040 push(pi, json).
    //! Precondition: pi >= 0; json is non-empty String.
    //! Postcondition: entry {pi, d:json} is in _entries; if size exceeded
    //!   MAX_ENTRIES the oldest entry was dropped; flash flushed every
    //!   FLUSH_EVERY pushes. Invariant preserved.
    function push(pi as Number, json as String) as Void {
        if (json == null || json.length() == 0) { return; }

        if (_entries.size() >= MAX_ENTRIES) {
            _entries = _entries.slice(1, null);
            System.println("PersistentQueue: capacity reached, oldest packet dropped");
        }
        _entries.add({"pi" => pi, "d" => json});
        _dirty++;
        if (_dirty >= FLUSH_EVERY) {
            _writeToStorage();
        }
    }

    //! C-041 ackUpTo(ackPi).
    //! Precondition: ackPi >= 0.
    //! Postcondition: all entries with pi <= ackPi removed (INV-007);
    //!   flash flushed if at least one entry was removed.
    function ackUpTo(ackPi as Number) as Void {
        var before = _entries.size();
        var kept   = [] as Array;
        for (var i = 0; i < _entries.size(); i++) {
            var e = _entries[i] as Dictionary;
            if ((e.get("pi") as Number) > ackPi) {
                kept.add(e);
            }
        }
        var removed = before - kept.size();
        if (removed > 0) {
            _entries = kept;
            _writeToStorage();
            System.println("PersistentQueue: ACK pi<=" + ackPi.toString()
                + " removed=" + removed.toString()
                + " pending=" + _entries.size().toString());
        }
    }

    //! Return up to maxCount oldest entries. Does NOT remove them.
    function getResendBatch(maxCount as Number) as Array {
        var end = _entries.size();
        if (maxCount < end) { end = maxCount; }
        return _entries.slice(0, end);
    }

    function flush() as Void { _writeToStorage(); }

    function size() as Number { return _entries.size(); }

    //! Wipe the queue — called on new session start so old pi values don't
    //! collide with the reset-to-0 counter.
    function clear() as Void {
        _entries = [] as Array;
        _dirty   = 0;
        try {
            Application.Storage.deleteValue(STORAGE_KEY);
        } catch (ex instanceof Lang.Exception) {
            System.println("PersistentQueue: clear error: " + ex.getErrorMessage());
        }
        System.println("PersistentQueue: cleared for new session");
    }

    // ── Private ───────────────────────────────────────────────────

    //! Write _entries to flash. Wrapped per instructions: setValue can throw
    //! if the storage quota (~64 KB) is exceeded.
    private function _writeToStorage() as Void {
        try {
            Application.Storage.setValue(STORAGE_KEY, _entries);
            _dirty = 0;
        } catch (ex instanceof Lang.Exception) {
            System.println("PersistentQueue: write failed: " + ex.getErrorMessage());
            // Keep _dirty set so we try again on the next push.
        }
    }

    private function _loadFromStorage() as Void {
        try {
            var raw = Application.Storage.getValue(STORAGE_KEY);
            if (raw instanceof Array) {
                _entries = raw as Array;
                if (_entries.size() > 0) {
                    System.println("PersistentQueue: restored "
                        + _entries.size().toString() + " unACK-ed packets from storage");
                }
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("PersistentQueue: load error: " + ex.getErrorMessage());
            _entries = [] as Array;
        }
    }
}
