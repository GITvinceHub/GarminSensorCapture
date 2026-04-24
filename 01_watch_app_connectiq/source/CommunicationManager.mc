import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

//! Manages phone-app messaging to the Android companion app.
//! Uses Toybox.Communications.transmit to send JSON packets,
//! and Communications.registerForPhoneAppMessages to receive ACKs.
//!
//! Features:
//! - Send queue (max MAX_QUEUE_SIZE packets) while phone unreachable
//! - ConnectionListener tracks success/failure
//! - Auto-retry pending queue after a successful transmit
class CommunicationManager {

    //! Callback type: status change (connected/disconnected)
    typedef StatusCallback as Method(connected as Boolean) as Void;

    //! Maximum packets in send queue
    private const MAX_QUEUE_SIZE = 20;

    //! Status callback
    private var _statusCallback as StatusCallback;

    //! Whether phone messaging appears to be working (last transmit succeeded)
    private var _isConnected as Boolean;

    //! Send queue (holds payloads when disconnected)
    private var _queue as Array<String>;

    //! Bound listener instance
    private var _listener as CommunicationManager.CommListener;

    //! Total packets successfully transmitted
    private var _packetsSent as Number;

    //! Total transmit failures
    private var _sendFailures as Number;

    //! @param statusCallback Called when connection status changes
    function initialize(statusCallback as StatusCallback) {
        _statusCallback = statusCallback;
        _isConnected    = false;
        _queue          = [] as Array<String>;
        _packetsSent    = 0;
        _sendFailures   = 0;
        _listener       = new CommListener(self);
    }

    //! Open communications: register phone-app message receiver.
    //! With the modern Communications API there is no "channel" to open —
    //! transmit() handles the phone hop each time.
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

    //! Close communications: unregister phone-app handler + clear queue.
    function closeChannel() as Void {
        if (Communications has :registerForPhoneAppMessages) {
            try {
                Communications.registerForPhoneAppMessages(null);
            } catch (ex instanceof Lang.Exception) {
                System.println("CommManager: unregister failed: " + ex.getErrorMessage());
            }
        }
        _isConnected = false;
        _queue = [] as Array<String>;
    }

    //! Send a JSON packet string to the companion app.
    //! If previous transmits failed, also queue for later retry.
    //! @param data JSON string to send
    function sendPacket(data as String) as Void {
        if (data == null || data.length() == 0) {
            return;
        }

        // If we have a backlog, queue first then try to drain
        if (_queue.size() > 0) {
            _enqueue(data);
            _drainQueue();
        } else {
            _transmit(data);
        }
    }

    //! Queue a packet, dropping oldest if at capacity.
    private function _enqueue(data as String) as Void {
        if (_queue.size() >= MAX_QUEUE_SIZE) {
            _queue = _queue.slice(1, null);
            System.println("CommManager: queue full, dropped oldest packet");
        }
        _queue.add(data);
    }

    //! Transmit a payload via Communications.transmit.
    private function _transmit(data as String) as Void {
        try {
            Communications.transmit(data, null, _listener);
        } catch (ex instanceof Lang.Exception) {
            System.println("CommManager: transmit exception: " + ex.getErrorMessage());
            _handleFailure();
            _enqueue(data);
        }
    }

    //! Attempt to flush the queue. Stops at first failure
    //! (further failures are reported asynchronously via the listener).
    private function _drainQueue() as Void {
        while (_queue.size() > 0 && _isConnected) {
            var packet = _queue[0];
            _queue = _queue.slice(1, null);
            _transmit(packet);
        }
    }

    //! Called by CommListener on successful transmit.
    function _handleSuccess() as Void {
        var wasConnected = _isConnected;
        _isConnected = true;
        _packetsSent++;
        if (!wasConnected) {
            _statusCallback.invoke(true);
        }
        if (_queue.size() > 0) {
            _drainQueue();
        }
    }

    //! Called by CommListener on transmit error.
    function _handleFailure() as Void {
        var wasConnected = _isConnected;
        _isConnected  = false;
        _sendFailures++;
        if (wasConnected) {
            _statusCallback.invoke(false);
        }
    }

    //! Handle incoming messages from the phone (e.g. ACKs).
    //! @param msg PhoneAppMessage with data attribute
    function onReceive(msg as Communications.PhoneAppMessage) as Void {
        // Protocol does not require ACKs at present; just log receipt.
        var data = msg.data;
        System.println("CommManager: received from phone: " + (data != null ? data.toString() : "null"));
    }

    //! @return true if the last transmit succeeded
    function isConnected() as Boolean {
        return _isConnected;
    }

    function getPacketsSent() as Number {
        return _packetsSent;
    }

    function getSendFailures() as Number {
        return _sendFailures;
    }

    function getQueueSize() as Number {
        return _queue.size();
    }

    //! Return a link-stats snapshot for UI display.
    //! @return Dictionary with keys: isLinked, packetsSent, sendFailures, queueSize
    function getLinkStats() as Dictionary {
        return {
            "isLinked"     => _isConnected,
            "packetsSent"  => _packetsSent,
            "sendFailures" => _sendFailures,
            "queueSize"    => _queue.size()
        };
    }

    //! Inner listener class bound to this CommunicationManager.
    class CommListener extends Communications.ConnectionListener {

        private var _owner as CommunicationManager;

        function initialize(owner as CommunicationManager) {
            Communications.ConnectionListener.initialize();
            _owner = owner;
        }

        //! Transmit completed successfully.
        function onComplete() as Void {
            _owner._handleSuccess();
        }

        //! Transmit failed.
        function onError() as Void {
            _owner._handleFailure();
        }
    }
}
