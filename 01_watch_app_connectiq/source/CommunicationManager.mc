//! CommunicationManager.mc
//! BLE transmit with strict single-in-flight semantics.
//!
//! INV-008 (critical — fixes v1.0 93% packet loss):
//!   At any instant, at most ONE Communications.transmit is in flight.
//!   Never call transmit twice without onComplete/onError in between.
//!
//! FR-011, FR-011b: queue in memory, drain driven by onComplete/onError AND by
//! the dispatch Timer in SessionManager (via sendPacket which tries a drain if idle).
using Toybox.Communications;
using Toybox.Lang;
using Toybox.System;

class CommunicationManager {

    //! In-memory queue cap. Old entries are dropped on overflow (FR-011 philosophy:
    //! we favour recent samples; the Android side detects gaps by packetIndex).
    public static const MAX_QUEUE = 20;

    //! Backoff when onError fires — short, because we want to retry quickly.
    public static const BACKOFF_MS = 500;

    private var _queue;              // Array<String>
    private var _transmitPending;    // Boolean — INV-008 guard
    private var _listener;           // CommListener instance
    private var _packetsSent;
    private var _packetsFailed;
    private var _lastErrorCode;
    private var _isLinkUp;           // best-effort, toggled by onComplete/onError

    function initialize() {
        _queue = [];
        _transmitPending = false;
        _packetsSent = 0;
        _packetsFailed = 0;
        _lastErrorCode = 0;
        _isLinkUp = true;
        _listener = new _CommListener(self);
    }

    //! Public API: enqueue + attempt to drain one. Never calls transmit() directly
    //! if something is already in flight (INV-008).
    function sendPacket(data) {
        try {
            if (data == null || data.equals("")) { return; }
            _enqueue(data);
            if (!_transmitPending) {
                _tryDrain();
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("CommManager: sendPacket FATAL " + ex.getErrorMessage());
        }
    }

    function _enqueue(data) {
        if (_queue.size() >= MAX_QUEUE) {
            // Drop oldest to make room for freshest data.
            _queue = _queue.slice(1, null);
        }
        _queue.add(data);
    }

    //! Pull one packet off the head and transmit it. Called only when
    //! _transmitPending == false — which is true at init, after onComplete,
    //! and after onError.
    //! GIQ-020: `Communications has :transmit` gate — defensive against
    //!          future firmwares / trimmed builds.
    function _tryDrain() {
        if (_transmitPending) { return; }
        if (_queue.size() == 0) { return; }
        if (!(Toybox.Communications has :transmit)) {
            System.println("CommManager: Communications.transmit not available");
            return;
        }

        var packet = _queue[0];
        _queue = _queue.slice(1, null);
        _transmitPending = true;
        try {
            Communications.transmit(packet, null, _listener);
        } catch (ex instanceof Lang.Exception) {
            System.println("CommManager: transmit threw " + ex.getErrorMessage());
            _transmitPending = false;
            _packetsFailed += 1;
            _isLinkUp = false;
            // Re-queue at the head so we don't lose it.
            _queue = [packet].addAll(_queue);
            // Do NOT immediately retry — let the dispatch Timer try again.
        }
    }

    //! Called by _CommListener on successful transmission.
    function _onComplete() {
        try {
            _transmitPending = false;
            _packetsSent += 1;
            _isLinkUp = true;
            _tryDrain();        // pipeline next
        } catch (ex instanceof Lang.Exception) {
            System.println("CommManager: _onComplete FATAL " + ex.getErrorMessage());
        }
    }

    //! Called by _CommListener on transmit error.
    function _onError(code) {
        try {
            _transmitPending = false;
            _packetsFailed += 1;
            _lastErrorCode = code;
            _isLinkUp = false;
            // Don't drain immediately — the Timer tick will retry after BACKOFF_MS.
        } catch (ex instanceof Lang.Exception) {
            System.println("CommManager: _onError FATAL " + ex.getErrorMessage());
        }
    }

    function getQueueSize()    { return _queue.size(); }
    function getPacketsSent()  { return _packetsSent; }
    function getPacketsFailed(){ return _packetsFailed; }
    function getLastError()    { return _lastErrorCode; }
    function isLinkUp()        { return _isLinkUp; }
    function isTransmitPending() { return _transmitPending; }
}

//! Private listener that forwards CIQ callbacks to the owning CommunicationManager.
//! Both callbacks MUST be try/catch wrapped (NFR-012).
class _CommListener extends Communications.ConnectionListener {
    private var _owner;

    function initialize(owner) {
        ConnectionListener.initialize();
        _owner = owner;
    }

    function onComplete() {
        try {
            _owner._onComplete();
        } catch (ex instanceof Lang.Exception) {
            System.println("_CommListener: onComplete FATAL " + ex.getErrorMessage());
        }
    }

    function onError() {
        try {
            _owner._onError(-1);
        } catch (ex instanceof Lang.Exception) {
            System.println("_CommListener: onError FATAL " + ex.getErrorMessage());
        }
    }
}
