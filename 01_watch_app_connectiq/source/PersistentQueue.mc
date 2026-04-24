import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

//! Persistent ACK-tracked send queue backed by Application.Storage.
//!
//! Every packet transmitted over BLE is pushed here immediately.
//! The entry is removed only when the Android companion confirms receipt
//! with an ACK message ({"ack": pi}).  On BLE reconnect the watch
//! retransmits the oldest unacknowledged entries so no data is silently lost
//! during short disconnections (target: up to ~5 minutes @ 4 pkt/s).
//!
//! Storage layout
//!   Key "pq"  →  Array of {"pi" => Number, "d" => String}
//!   "pi" = packet index (monotonic within a session, resets on new session)
//!   "d"  = full JSON string of the packet
//!
//! Capacity
//!   MAX_ENTRIES = 60  →  ≈ 54 KB at ~900 B/packet  (≈ 15 s @ 4 pkt/s)
//!   Larger values risk OOM: each entry stores a ~900-byte JSON String.
//!   At 500 entries the in-memory array holds ~450 KB — far above the
//!   CIQ per-app memory budget (~128 KB on fēnix 8), causing the runtime
//!   to kill the app after ~15–30 s when ACKs stop arriving (e.g. Android crash).
//!   60 entries protect against short BLE disconnections without OOM risk.
//!
//!   Flash is written every FLUSH_EVERY pushes to reduce wear; a forced flush
//!   is done on every ACK and on session stop.
class PersistentQueue {

    private const STORAGE_KEY = "pq";
    private const MAX_ENTRIES = 60;
    private const FLUSH_EVERY = 10;   // push-to-flash interval

    //! In-memory mirror of the storage array
    private var _entries as Array;

    //! Number of pushes since last flash write
    private var _dirty as Number;

    function initialize() {
        _dirty   = 0;
        _entries = [] as Array;
        _loadFromStorage();
    }

    // ── Public API ────────────────────────────────────────────────

    //! Add a packet to the queue.
    //! Called by SessionManager immediately before handing the packet to
    //! CommunicationManager.
    //! @param pi   Monotonic packet index for the current session
    //! @param json Serialised JSON string of the packet
    function push(pi as Number, json as String) as Void {
        if (_entries.size() >= MAX_ENTRIES) {
            // Drop oldest — a warning is logged but recording continues.
            _entries = _entries.slice(1, null);
            System.println("PersistentQueue: capacity reached, oldest packet dropped");
        }
        _entries.add({"pi" => pi, "d" => json});
        _dirty++;
        if (_dirty >= FLUSH_EVERY) {
            _writeToStorage();
        }
    }

    //! Remove all entries whose packet index is ≤ ackPi.
    //! Called by CommunicationManager when the Android companion sends an ACK.
    //! Forces an immediate flash write so the deletion survives a crash.
    //! @param ackPi Highest packet index confirmed received by Android
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
            _writeToStorage();  // forced flush — deletion must be durable
            System.println("PersistentQueue: ACK pi<=" + ackPi.toString()
                + "  removed=" + removed.toString()
                + "  pending=" + _entries.size().toString());
        }
    }

    //! Return up to maxCount oldest entries for reconnect retransmission.
    //! The caller should re-enqueue the "d" field of each entry.
    //! Entries are NOT removed here; removal happens via ackUpTo().
    //! @param maxCount Maximum number of entries to return
    //! @return Slice of the internal array (oldest first)
    function getResendBatch(maxCount as Number) as Array {
        var end = _entries.size();
        if (maxCount < end) { end = maxCount; }
        return _entries.slice(0, end);
    }

    //! Force a write to flash.  Call on session stop and app exit.
    function flush() as Void {
        _writeToStorage();
    }

    //! Number of packets currently waiting for an ACK.
    function size() as Number {
        return _entries.size();
    }

    //! Wipe the queue — called at the start of each new session so packet
    //! indices from the previous session do not collide with new ones.
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

    private function _writeToStorage() as Void {
        try {
            Application.Storage.setValue(STORAGE_KEY, _entries);
            _dirty = 0;
        } catch (ex instanceof Lang.Exception) {
            System.println("PersistentQueue: write failed: " + ex.getErrorMessage());
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
