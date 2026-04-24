import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.System;

//! Input delegate — maps physical buttons to app actions.
//!
//! Button assignment (fēnix 8 Pro physical layout):
//!   START / STOP  short  → Start / Stop recording
//!   START / STOP  long   → New session (stop current + start fresh)
//!   BACK / LAP    short  → Mark event (lap / waypoint)
//!   BACK / LAP    long   → Cancel / back (close menu, or no-op)
//!   UP / MENU     short  → Next screen (1 → 2 → … → 6 → 1)
//!   UP / MENU     long   → Open capture menu (KEY_MENU injected by OS)
//!   DOWN          short  → Next detail sub-page in current screen
//!   DOWN          long   → Toggle button lock
//!
//! Button lock: when enabled all keys except DOWN are silently eaten.
class MainDelegate extends WatchUi.InputDelegate {

    //! Threshold for long-press detection in milliseconds
    private const LONG_PRESS_MS = 1000;

    private var _sessionManager as SessionManager;
    private var _viewModel      as ViewModel;
    private var _uiState        as UiState;
    private var _view           as MainView;

    //! Timestamp recorded on each key-down event
    private var _pressTime as Number;

    //! @param sessionManager Shared session manager
    //! @param viewModel      Shared view model (read-only in delegate)
    //! @param uiState        Shared UI navigation state
    //! @param view           The main view (for requestUpdate callbacks)
    function initialize(
        sessionManager as SessionManager,
        viewModel      as ViewModel,
        uiState        as UiState,
        view           as MainView
    ) {
        InputDelegate.initialize();
        _sessionManager = sessionManager;
        _viewModel      = viewModel;
        _uiState        = uiState;
        _view           = view;
        _pressTime      = 0;
    }

    //! Record press timestamp when a key is pushed down.
    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        _pressTime = System.getTimer();
        return false;  // key-down never consumes the event
    }

    //! Act on key release, computing hold duration for long-press detection.
    function onKeyReleased(keyEvent as WatchUi.KeyEvent) as Boolean {
        try {
            var key  = keyEvent.getKey();
            var held = System.getTimer() - _pressTime;

            // ── Button-lock filter ────────────────────────────────
            if (_uiState.isButtonLocked() && key != WatchUi.KEY_DOWN) {
                WatchUi.requestUpdate();
                return true;
            }

            // ── Capture menu navigation ───────────────────────────
            if (_uiState.isMenuOpen()) {
                return _handleMenuKey(key);
            }

            // ── Normal button handling ────────────────────────────
            if (key == WatchUi.KEY_START) {
                if (held >= LONG_PRESS_MS) {
                    _sessionManager.restartNewSession();
                } else {
                    _handleStartStop();
                }
                WatchUi.requestUpdate();
                return true;
            }

            if (key == WatchUi.KEY_ESC) {
                if (held >= LONG_PRESS_MS) {
                    _handleBackLong();
                } else {
                    _sessionManager.markEvent();
                }
                WatchUi.requestUpdate();
                return true;
            }

            if (key == WatchUi.KEY_UP) {
                _uiState.nextScreen();
                WatchUi.requestUpdate();
                return true;
            }

            // KEY_MENU = long-press UP injected by OS
            if (key == WatchUi.KEY_MENU) {
                _uiState.openMenu();
                WatchUi.requestUpdate();
                return true;
            }

            if (key == WatchUi.KEY_DOWN) {
                if (held >= LONG_PRESS_MS) {
                    _uiState.toggleButtonLock();
                } else {
                    _uiState.nextDetail();
                }
                WatchUi.requestUpdate();
                return true;
            }

            if (key == WatchUi.KEY_ENTER) {
                _uiState.nextScreen();
                WatchUi.requestUpdate();
                return true;
            }

        } catch (ex instanceof Lang.Exception) {
            System.println("MainDelegate: key handler exception: " + ex.getErrorMessage());
            WatchUi.requestUpdate();
            return true;
        }

        return false;
    }

    // ── Private handlers ──────────────────────────────────────────

    //! Toggle recording state (start if IDLE, stop if RECORDING).
    private function _handleStartStop() as Void {
        var state = _sessionManager.getState();
        if (state == SessionManager.STATE_IDLE) {
            _sessionManager.startSession();
        } else if (state == SessionManager.STATE_RECORDING) {
            _sessionManager.stopSession();
        }
        // STATE_STOPPING: transition in progress, ignore
    }

    //! BACK long: close menu if open, stop recording with confirmation if active.
    private function _handleBackLong() as Void {
        if (_uiState.isMenuOpen()) {
            _uiState.closeMenu();
            return;
        }
        // If recording, long-press BACK acts as an emergency stop
        if (_sessionManager.getState() == SessionManager.STATE_RECORDING) {
            _sessionManager.stopSession();
        }
    }

    //! Route key events while the capture menu is open.
    private function _handleMenuKey(key as Number) as Boolean {
        if (key == WatchUi.KEY_DOWN || key == WatchUi.KEY_UP) {
            _uiState.nextMenuItem();
            WatchUi.requestUpdate();
            return true;
        }
        if (key == WatchUi.KEY_START || key == WatchUi.KEY_ENTER) {
            _executeMenuItem(_uiState.getMenuIndex());
            _uiState.closeMenu();
            WatchUi.requestUpdate();
            return true;
        }
        if (key == WatchUi.KEY_ESC) {
            _uiState.closeMenu();
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    //! Execute the selected menu action.
    private function _executeMenuItem(index as Number) as Void {
        if (index == UiState.MENU_NEW_SESSION) {
            _sessionManager.restartNewSession();
        } else if (index == UiState.MENU_SYS_INFO) {
            // Navigate to Recording screen for system info
            // (no action needed — just close menu)
        }
        // Other menu items: close menu only
    }

    //! Swipe handler (passthrough — watch uses button navigation).
    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return false;
    }

    //! Tap handler (touchscreen only — fēnix 8 Pro has no touchscreen).
    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        return false;
    }
}
