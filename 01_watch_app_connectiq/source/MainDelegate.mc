//! MainDelegate.mc
//! Minimal button mapping — KISS:
//!   START  → toggle session
//!   BACK   → exit app (standard CIQ back-out behaviour)
//!   UP/DOWN unused for now
using Toybox.WatchUi;
using Toybox.System;
using Toybox.Lang;

class MainDelegate extends WatchUi.BehaviorDelegate {

    private var _session;
    private var _view;

    function initialize(sessionManager, view) {
        BehaviorDelegate.initialize();
        _session = sessionManager;
        _view = view;
    }

    //! CIQ shortcut for the START button (also mapped on fēnix).
    function onSelect() {
        try {
            if (_session != null) {
                _session.toggleSession();
                WatchUi.requestUpdate();
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("MainDelegate: onSelect FATAL " + ex.getErrorMessage());
        }
        return true;
    }

    //! BACK — let the CIQ runtime handle exit (returns false ⇒ default behaviour).
    function onBack() {
        try {
            if (_session != null && _session.getState() != SessionManager.STATE_IDLE) {
                _session.stopSession();
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("MainDelegate: onBack FATAL " + ex.getErrorMessage());
        }
        return false;   // let system close the app
    }

    //! Generic key handler — try to catch any KEY_ENTER / KEY_START events not
    //! already handled by onSelect (depending on device).
    function onKey(keyEvent) {
        try {
            if (keyEvent == null) { return false; }
            var key = keyEvent.getKey();
            if (key == WatchUi.KEY_ENTER || key == WatchUi.KEY_START) {
                if (_session != null) {
                    _session.toggleSession();
                    WatchUi.requestUpdate();
                }
                return true;
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("MainDelegate: onKey FATAL " + ex.getErrorMessage());
        }
        return false;
    }
}
