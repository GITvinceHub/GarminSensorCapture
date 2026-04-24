import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

//! BLE (phone-app messaging) subsystem.
//!
//! Implements contracts C-030, C-031 per SPECIFICATION.md §7.4.
//! Targets FR-010 (BLE transmit), FR-011 (single-in-flight), FR-012 (resend).
//!
//! INVARIANTS:
//!  - _transmitPending == true implies exactly 1 Communications.transmit in flight.
//!  - _queue.size() <= MAX_QUEUE_SIZE (drop-oldest when full).
//!
//! NFR-012: ALL callbacks (onReceive, _onTransmitOk, _onTransmitFailed)
//!          are wrapped in try/catch — no exception propagates to CIQ.
//!
//! ACK handling (C-031): Android sends {"ack": N} where N is the highest
//! confirmed pi. The watch may receive the ack as:
//!  - a Dictionary directly, OR
//!  - a 1-element Array<Dictionary> (CIQ Mobile SDK wraps HashMap)
//!  - "ack" value may be Number or Long → use toNumber() defensively.
class CommunicationManager {

    typedef StatusCallback as Method(connected as Boolean) as Void;

    private const MAX_QUEUE_SIZE    = 20;
    private const RETRY_INTERVAL_MS = 5000;
    private const RESEND_BATCH_SIZE = 20;

    private var _statusCallback  as StatusCallback;
    private var _isConnected     as Boolean;
    private var _queue           as Array<String>;
    private var _listener        as CommunicationManager.CommListener;
    private var _transmitPending as Boolean;
    private var _lastFailureMs   as Number;
    private var _persistentQueue as PersistentQueue or Null;
    private var _packetsSent     as Number;
    private var _sendFailures    as Number;

    function initialize(statusCallback as StatusCallback) {
        _statusCallback  = statusCallback;
        _isConnected     = false;
        _queue           = [] as Array<String>;
        _listener        = new CommListener(self);
        _transmitPending = false;
        _lastFailureMs   = 0;
        _persistentQueue = null;
        _packetsSent     = 0;
        _sendFailures    = 0;
    }

    //! Inject the persistent-queue dependency (lazily wired by SessionManager).
    function setPersistentQueue(pq as PersistentQueue) as Void {
        _persistentQueue = pq;
    }

    function openChannel() as Void {
        if (Communications has :registerForPhoneAppMessages) {
            try {
                Communications.registerForPhoneAppMessages(method(:onReceive));
                System.println("CommManager: phone-app messaging registered");
            } catch (ex instanceof Lang.Exception) {
                System.println("CommManager: register failed: " + ex.getErrorMessage());
            }
        }
    }

    function closeChannel() as Void {
        if (Communications has :registerForPhoneAppMessages) {
            try {
                Communications.registerForPhoneAppMessages(null);
            } catch (ex instanceof Lang.Exception) { }
        }
        _isConnected     = false;
        _transmitPending = false;
        _queue           = [] as Array<String>;
    }

    //! C-030 sendPacket(data).
    //! Precondition: data is a non-empty String.
    //! Postcondition: data enqueued (dropping oldest if full); transmit
    //!   initiated if no transmit is in flight; no exception propagates.
    function sendPacket(data as String) as Void {
        if (data == null || data.length() == 0) { return; }
        _enqueue(data);
        if (!_transmitPending) {
            _trySend();
        }
    }

    private function _enqueue(data as String) as Void {
        if (_queue.size() >= MAX_QUEUE_SIZE) {
            _queue = _queue.slice(1, null);
        }
        _queue.add(data);
    }

    private function _trySend() as Void {
        if (_queue.size() == 0 || _transmitPending) { return; }

        if (!_isConnected) {
            var now = System.getTimer();
            if ((now - _lastFailureMs) < RETRY_INTERVAL_MS) { return; }
        }

        var packet = _queue[0];
        _queue = _queue.slice(1, null);
        _transmitPending = true;

        try {
            Communications.transmit(packet, null, _listener);
        } catch (ex instanceof Lang.Exception) {
            // Synchronous failure path — treat like async onError.
            _transmitPending = false;
            _onTransmitFailed();
            _enqueue(packet);
        }
    }

    //! Called by CommListener when transmit completes.
    //! NFR-012: wrapped — never propagate an exception back into CIQ.
    function _onTransmitOk() as Void {
        try {
            _transmitPending = false;
            var wasDisconnected = !_isConnected;
            _isConnected = true;
            _packetsSent++;

            if (wasDisconnected) {
                System.println("CommManager: BLE link restored");
                _statusCallback.invoke(true);
                _injectResendBatch();
            }
            _trySend();
        } catch (ex instanceof Lang.Exception) {
            System.println("CommManager: FATAL in _onTransmitOk: " + ex.getErrorMessage());
        }
    }

    //! Called by CommListener (or exception path) on transmit failure.
    //! NFR-012: wrapped.
    function _onTransmitFailed() as Void {
        try {
            _transmitPending = false;
            _lastFailureMs   = System.getTimer();
            _sendFailures++;
            var wasConnected = _isConnected;
            _isConnected = false;
            if (wasConnected) {
                System.println("CommManager: BLE link lost (failures="
                    + _sendFailures.toString() + ")");
                _statusCallback.invoke(false);
            }
            // New packets will re-trigger _trySend() via RETRY_INTERVAL_MS guard.
        } catch (ex instanceof Lang.Exception) {
            System.println("CommManager: FATAL in _onTransmitFailed: " + ex.getErrorMessage());
        }
    }

    private function _injectResendBatch() as Void {
        if (_persistentQueue == null) { return; }
        var pq = _persistentQueue as PersistentQueue;
        var batch = pq.getResendBatch(RESEND_BATCH_SIZE);
        if (batch.size() == 0) { return; }

        for (var i = 0; i < batch.size(); i++) {
            var entry = batch[i] as Dictionary;
            var json  = entry.get("d");
            if (json != null) {
                _enqueue(json as String);
            }
        }
        System.println("CommManager: " + batch.size().toString()
            + " unACK-ed packets re-queued (persistent pending="
            + pq.size().toString() + ")");
    }

    //! C-031 onReceive(msg).
    //! Precondition: msg is a Communications.PhoneAppMessage.
    //! Postcondition: if data contains an ACK, _persistentQueue.ackUpTo(N) is
    //!   called; all exceptions attrapées et loggées (NFR-012).
    //!
    //! Robust ACK parsing — data may be:
    //!   {"ack": N}                    direct Dictionary
    //!   [{"ack": N}]                  Array of 1 Dictionary (CIQ Mobile wrap)
    //!   N may be Number or Long → toNumber() defensively.
    function onReceive(msg as Communications.PhoneAppMessage) as Void {
        try {
            _onReceiveImpl(msg);
        } catch (ex instanceof Lang.Exception) {
            System.println("CommManager: FATAL in onReceive: " + ex.getErrorMessage());
        }
    }

    private function _onReceiveImpl(msg as Communications.PhoneAppMessage) as Void {
        if (msg == null) { return; }
        var data = msg.data;
        if (data == null) { return; }

        // Unwrap single-element Array (CIQ Mobile SDK packaging).
        if (data instanceof Array && (data as Array).size() > 0) {
            data = (data as Array)[0];
        }

        if (data instanceof Dictionary) {
            var ack = (data as Dictionary).get("ack");
            if (ack != null && _persistentQueue != null) {
                var ackPi = 0;
                try {
                    if (ack instanceof Lang.Number)     { ackPi = ack as Number; }
                    else if (ack instanceof Lang.Long)  { ackPi = (ack as Long).toNumber(); }
                    else if (ack instanceof Lang.Float) { ackPi = (ack as Float).toNumber(); }
                    else if (ack instanceof Lang.String){ ackPi = (ack as String).toNumber(); }
                } catch (ex instanceof Lang.Exception) { ackPi = 0; }
                (_persistentQueue as PersistentQueue).ackUpTo(ackPi);
                return;
            }
        }

        System.println("CommManager: received: " + data.toString());
    }

    // ── Accessors ─────────────────────────────────────────────────

    function isConnected()     as Boolean { return _isConnected;    }
    function getQueueSize()    as Number  { return _queue.size();   }
    function getPacketsSent()  as Number  { return _packetsSent;    }
    function getSendFailures() as Number  { return _sendFailures;   }

    function getLinkStats() as Dictionary {
        var pqSize = (_persistentQueue != null)
            ? (_persistentQueue as PersistentQueue).size()
            : 0;
        return {
            "isLinked"       => _isConnected,
            "packetsSent"    => _packetsSent,
            "sendFailures"   => _sendFailures,
            "queueSize"      => _queue.size(),
            "persistentSize" => pqSize
        };
    }

    // ── Inner listener ────────────────────────────────────────────

    class CommListener extends Communications.ConnectionListener {

        private var _owner as CommunicationManager;

        function initialize(owner as CommunicationManager) {
            Communications.ConnectionListener.initialize();
            _owner = owner;
        }

        function onComplete() as Void {
            _owner._onTransmitOk();
        }

        function onError() as Void {
            _owner._onTransmitFailed();
        }
    }
}
