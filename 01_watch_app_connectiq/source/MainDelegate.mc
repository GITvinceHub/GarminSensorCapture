import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.System;

//! Physical button handler.
//!
//! Implements FR-021..FR-028 button mapping per SPECIFICATION.md §4.3 / §12.3.
//! NFR-012: onKey / onKeyReleased wrapped in try/catch.
//!
//!   START short  → start / stop                 FR-023
//!   START long   → new session (stop + start)   FR-024
//!   BACK short   → mark event                   FR-025
//!   BACK long    → emergency stop / close menu  FR-026
//!   UP short     → next screen                  FR-021
//!   UP long      → open capture menu            FR-027
//!   DOWN short   → next sub-page                FR-022
//!   DOWN long    → toggle button lock           FR-028
//!
//! Button lock: when enabled, every key except DOWN is silently eaten.
class MainDelegate extends WatchUi.InputDelegate {

    private const LONG_PRESS_MS = 1000;

    private var _sessionManager as SessionManager;
    private var _viewModel      as ViewModel;
    private var _uiState        as UiState;
    private var _view           as MainView;
    private var _pressTime      as Number;

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

    //! Capture press time AND consume key-down so the OS does not inject
    //! a secondary KEY_MENU event on long UP press.
    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        try {
            _pressTime = System.getTimer();
        } catch (ex instanceof Lang.Exception) {
            System.println("MainDelegate: onKey exception: " + ex.getErrorMessage());
        }
        return true;
    }

    //! NFR-012: wrapped in outer try/catch — no exception propagates to CIQ.
    function onKeyReleased(keyEvent as WatchUi.KeyEvent) as Boolean {
        try {
            var key  = keyEvent.getKey();
            var held = System.getTimer() - _pressTime;
            if (held < 0 || held > 10000) { held = 0; }

            // Button-lock filter — only DOWN escapes.
            if (_uiState.isButtonLocked() && key != WatchUi.KEY_DOWN) {
                WatchUi.requestUpdate();
                return true;
            }

            // Menu overlay handling.
            if (_uiState.isMenuOpen()) {
                return _handleMenuKey(key);
            }

            if (key == WatchUi.KEY_START) {
                if (held >= LONG_PRESS_MS) {
                    _sessionManager.restartNewSession();  // FR-024
                } else {
                    _handleStartStop();                   // FR-023
                }
                WatchUi.requestUpdate();
                return true;
            }

            if (key == WatchUi.KEY_ESC) {
                if (held >= LONG_PRESS_MS) {
                    _handleBackLong();                    // FR-026
                } else {
                    _sessionManager.markEvent();          // FR-025
                }
                WatchUi.requestUpdate();
                return true;
            }

            if (key == WatchUi.KEY_UP) {
                if (held >= LONG_PRESS_MS) {
                    _uiState.openMenu();                  // FR-027
                } else {
                    _uiState.nextScreen();                // FR-021
                }
                WatchUi.requestUpdate();
                return true;
            }

            // Fallback: some firmware still injects KEY_MENU on long UP.
            if (key == WatchUi.KEY_MENU) {
                _uiState.openMenu();
                WatchUi.requestUpdate();
                return true;
            }

            if (key == WatchUi.KEY_DOWN) {
                if (held >= LONG_PRESS_MS) {
                    _uiState.toggleButtonLock();          // FR-028
                } else {
                    _uiState.nextDetail();                // FR-022
                }
                WatchUi.requestUpdate();
                return true;
            }

            // KEY_ENTER — simulator fires this for the START button.
            if (key == WatchUi.KEY_ENTER) {
                if (held >= LONG_PRESS_MS) {
                    _sessionManager.restartNewSession();
                } else {
                    _handleStartStop();
                }
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

    //! START short → toggle IDLE ↔ RECORDING.
    private function _handleStartStop() as Void {
        var state = _sessionManager.getState();
        if (state == SessionManager.STATE_IDLE) {
            _sessionManager.startSession();
        } else if (state == SessionManager.STATE_RECORDING) {
            _sessionManager.stopSession();
        }
        // STATE_STOPPING: in-flight transition, ignore.
    }

    //! BACK long → close menu if open, else emergency stop if recording.
    private function _handleBackLong() as Void {
        if (_uiState.isMenuOpen()) {
            _uiState.closeMenu();
            return;
        }
        if (_sessionManager.getState() == SessionManager.STATE_RECORDING) {
            _sessionManager.stopSession();
        }
    }

    //! Routes key events while the capture menu overlay is open.
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

    private function _executeMenuItem(index as Number) as Void {
        if (index == UiState.MENU_NEW_SESSION) {
            _sessionManager.restartNewSession();
        }
        // Other menu items close the menu only.
    }

    //! No swipe navigation — button-driven UX.
    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return false;
    }

    //! fēnix 8 Pro has no touchscreen; pass through.
    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        return false;
    }
}
