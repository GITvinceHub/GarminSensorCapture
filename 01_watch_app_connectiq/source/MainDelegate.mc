import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.System;

//! Input delegate for the main view.
//! Handles START/STOP session button and long-press event marking.
class MainDelegate extends WatchUi.InputDelegate {

    //! Reference to session manager
    private var _sessionManager as SessionManager;

    //! Timestamp of last key press (for long-press detection)
    private var _lastKeyPressTime as Number;

    //! Long press threshold in milliseconds
    private const LONG_PRESS_THRESHOLD_MS = 1000;

    //! @param sessionManager Shared session manager instance
    function initialize(sessionManager as SessionManager) {
        InputDelegate.initialize();
        _sessionManager = sessionManager;
        _lastKeyPressTime = 0;
    }

    //! Called when a key is pressed (button down)
    //! @param keyEvent The key event containing key code
    //! @return true if handled, false to propagate
    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();

        // Record press timestamp for long-press detection
        _lastKeyPressTime = System.getTimer();

        return false;  // Let onKeyReleased handle the action
    }

    //! Called when a key is released (button up)
    //! @param keyEvent The key event containing key code
    //! @return true if handled, false to propagate
    function onKeyReleased(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();

        // Calculate hold duration
        var holdDuration = System.getTimer() - _lastKeyPressTime;

        // START button: toggle session
        if (key == WatchUi.KEY_START) {
            if (holdDuration >= LONG_PRESS_THRESHOLD_MS) {
                // Long press on START: mark an event
                _handleMarkEvent();
            } else {
                // Short press: start or stop
                _handleStartStop();
            }
            WatchUi.requestUpdate();
            return true;
        }

        // ENTER / LAP button: also toggles session (short press)
        if (key == WatchUi.KEY_ENTER) {
            if (holdDuration < LONG_PRESS_THRESHOLD_MS) {
                _handleStartStop();
            }
            WatchUi.requestUpdate();
            return true;
        }

        // BACK / DOWN during recording: stop
        if (key == WatchUi.KEY_DOWN || key == WatchUi.KEY_ESC) {
            var state = _sessionManager.getState();
            if (state == SessionManager.STATE_RECORDING) {
                _sessionManager.stopSession();
                WatchUi.requestUpdate();
                return true;
            }
        }

        return false;
    }

    //! Toggle start/stop based on current state
    private function _handleStartStop() as Void {
        var state = _sessionManager.getState();

        if (state == SessionManager.STATE_IDLE) {
            _sessionManager.startSession();
        } else if (state == SessionManager.STATE_RECORDING) {
            _sessionManager.stopSession();
        }
        // If STOPPING, ignore — already in transition
    }

    //! Mark a session event (lap/waypoint) via long press
    private function _handleMarkEvent() as Void {
        if (_sessionManager.getState() == SessionManager.STATE_RECORDING) {
            _sessionManager.markEvent();
        }
    }

    //! Handle swipe gestures (optional)
    //! @param swipeEvent The swipe event
    //! @return true if handled
    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return false;
    }

    //! Handle tap/touch events (optional, only on touchscreen devices)
    //! @param clickEvent The click event
    //! @return true if handled
    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        return false;
    }
}
