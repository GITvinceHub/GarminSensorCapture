import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

//! Manages phone-app messaging to the Android companion app.
//!
//! Design: single-in-flight model.
//!   Only one Communications.transmit() call is outstanding at any time.
//!   The next packet is sent only after the listener fires onComplete() or
//!   onError() for the previous one.  This prevents CIQ runtime warnings
//!   ("Communications transmit queue full") when the phone is absent.
//!
//! Retry back-off: after a transmit failure we wait RETRY_INTERVAL_MS before
//!   the next attempt.  Queued packets accumulate during the wait.
//!
//! Persistent ACK queue (Level 2):
//!   A PersistentQueue reference can be injected via setPersistentQueue().
//!   When the Android companion sends {"ack": N}, all stored packets with
//!   pi ≤ N are deleted from flash.  On BLE reconnect, up to
//!   RESEND_BATCH_SIZE unACK-ed packets are re-injected into the send queue.
class CommunicationManager {

    //! Callback type: status change (connected / disconnected)
    typedef StatusCallback as Method(connected as Boolean) as Void;

    //! Maximum packets held in the in-memory send queue
    private const MAX_QUEUE_SIZE    = 20;

    //! Minimum ms between transmit attempts after a failure (back-off)
    private const RETRY_INTERVAL_MS = 5000;

    //! Number of persistent-queue entries re-injected on BLE reconnect
    private const RESEND_BATCH_SIZE = 20;

    //! Status callback (injected by SessionManager)
    private var _statusCallback  as StatusCallback;

    //! Whether the last transmit succeeded (connection assumed live)
    private var _isConnected     as Boolean;

    //! In-memory send queue (oldest-drop when full)
    private var _queue           as Array<String>;

    //! Bound listener (reused across all transmit calls)
    private var _listener        as CommunicationManager.CommListener;

    //! True while a Communications.transmit() call is outstanding
    private var _transmitPending as Boolean;

    //! getTimer() value at the most recent failure (for back-off)
    private var _lastFailureMs   as Number;

    //! Reference to the persistent ACK queue (optional — null if not set)
    private var _persistentQueue as PersistentQueue or Null;

    //! Total packets successfully ACK-ed by the system
    private var _packetsSent     as Number;

    //! Total transmit failures (exception or onError callback)
    private var _sendFailures    as Number;

    //! @param statusCallback Invoked on connection-state changes
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

    //! Inject the persistent-queue dependency.
    //! Called by SessionManager after both objects are constructed.
    function setPersistentQueue(pq as PersistentQueue) as Void {
        _persistentQueue = pq;
    }

    //! Register the phone-app message receiver.
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

    //! Unregister and discard the in-memory queue.
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

    //! Enqueue a JSON string for delivery.
    //! @param data JSON string to send
    function sendPacket(data as String) as Void {
        if (data == null || data.length() == 0) { return; }
        _enqueue(data);
        if (!_transmitPending) {
            _trySend();
        }
    }

    // ── Private helpers ───────────────────────────────────────────

    //! Add data to the tail of the in-memory queue, dropping oldest if full.
    private function _enqueue(data as String) as Void {
        if (_queue.size() >= MAX_QUEUE_SIZE) {
            _queue = _queue.slice(1, null);
        }
        _queue.add(data);
    }

    //! Attempt to transmit the head of the in-memory queue.
    //! Conditions: queue non-empty, no outstanding transmit, back-off elapsed.
    private function _trySend() as Void {
        if (_queue.size() == 0 || _transmitPending) { return; }

        // Respect back-off interval after failures
        if (!_isConnected) {
            var now = System.getTimer();
            if ((now - _lastFailureMs) < RETRY_INTERVAL_MS) {
                return;
            }
        }

        var packet = _queue[0];
        _queue = _queue.slice(1, null);
        _transmitPending = true;

        try {
            Communications.transmit(packet, null, _listener);
        } catch (ex instanceof Lang.Exception) {
            // Synchronous failure (rare): treat like async onError
            _transmitPending = false;
            _onTransmitFailed();
            _enqueue(packet);   // re-queue for retry after back-off
        }
    }

    //! Called by CommListener when the system ACK-s a transmit.
    function _onTransmitOk() as Void {
        _transmitPending = false;
        var wasDisconnected = !_isConnected;
        _isConnected = true;
        _packetsSent++;

        if (wasDisconnected) {
            System.println("CommManager: BLE link restored");
            _statusCallback.invoke(true);
            // ── Re-inject unACK-ed packets from persistent queue ──────
            // Android will deduplicate by packet index (pi) if it already
            // has some of these; the watch retransmits them to guarantee
            // no data is permanently lost due to the disconnection.
            _injectResendBatch();
        }

        _trySend();   // pipeline: send next queued packet immediately
    }

    //! Called by CommListener (or exception path) on transmit failure.
    function _onTransmitFailed() as Void {
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
        // Do NOT retry immediately — _trySend() throttles via RETRY_INTERVAL_MS.
        // New sensor packets arrive every ~250 ms and each call to sendPacket()
        // will re-trigger _trySend(), so no polling timer is needed.
    }

    //! Re-enqueue up to RESEND_BATCH_SIZE packets from the persistent queue
    //! so they are retransmitted after a BLE reconnection.
    //! Persistent-queue entries are removed only when Android ACKs them,
    //! not here.
    private function _injectResendBatch() as Void {
        if (_persistentQueue == null) { return; }
        var pq    = _persistentQueue as PersistentQueue;
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
            + " unACK-ed packets re-queued for resend (persistent pending="
            + pq.size().toString() + ")");
    }

    //! Handle incoming messages from the phone.
    //! Expected ACK format : {"ack": <Number>}
    //!   where the number is the highest packet index (pi) confirmed received.
    function onReceive(msg as Communications.PhoneAppMessage) as Void {
        var data = msg.data;
        if (data == null) { return; }

        // ── ACK handling ──────────────────────────────────────────
        if (data instanceof Dictionary) {
            var ack = (data as Dictionary).get("ack");
            if (ack != null && _persistentQueue != null) {
                (_persistentQueue as PersistentQueue).ackUpTo(ack as Number);
                return;  // ACK message processed — nothing else to log
            }
        }

        // ── Other messages (commands, debug) ──────────────────────
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
            "isLinked"      => _isConnected,
            "packetsSent"   => _packetsSent,
            "sendFailures"  => _sendFailures,
            "queueSize"     => _queue.size(),
            "persistentSize"=> pqSize
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
