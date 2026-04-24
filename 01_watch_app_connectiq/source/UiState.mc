import Toybox.Lang;

//! UI navigation state — pure data, no drawing or logic.
//!
//! Implements FR-020..FR-028 navigation model per SPECIFICATION.md §4.3:
//!  - 14 screens (SCREEN_SUMMARY..SCREEN_PIPELINE), UP cycles forward.
//!  - 4 sub-pages per screen, DOWN cycles forward.
//!  - Button lock (DOWN long-press) gates every key except DOWN.
//!  - Capture menu overlay (UP long-press).
class UiState {

    // ── Screen indices (14 total) per FR-020 ──────────────────────
    static const SCREEN_SUMMARY   = 0;
    static const SCREEN_IMU       = 1;
    static const SCREEN_GPS       = 2;
    static const SCREEN_HR        = 3;
    static const SCREEN_META      = 4;
    static const SCREEN_RECORDING = 5;
    static const SCREEN_BLE       = 6;
    static const SCREEN_STORAGE   = 7;
    static const SCREEN_FILESIZE  = 8;
    static const SCREEN_BUFFER    = 9;
    static const SCREEN_INTEGRITY = 10;
    static const SCREEN_SYNCTIME  = 11;
    static const SCREEN_POWER     = 12;
    static const SCREEN_PIPELINE  = 13;
    static const SCREEN_COUNT     = 14;

    //! Backward-compat alias.
    static const SCREEN_HOME = 0;

    //! Detail sub-pages (4 per screen per FR-022).
    static const IMU_DETAIL_OVERVIEW = 0;
    static const IMU_DETAIL_ACC      = 1;
    static const IMU_DETAIL_GYRO     = 2;
    static const IMU_DETAIL_MAG      = 3;
    static const IMU_DETAIL_COUNT    = 4;

    //! Capture menu items.
    static const MENU_NEW_SESSION = 0;
    static const MENU_SYS_INFO    = 1;
    static const MENU_SENSORS     = 2;
    static const MENU_CLOSE       = 3;
    static const MENU_COUNT       = 4;

    private var _screenIndex  as Number;
    private var _detailIndex  as Number;
    private var _buttonLocked as Boolean;
    private var _menuOpen     as Boolean;
    private var _menuIndex    as Number;

    function initialize() {
        _screenIndex  = SCREEN_SUMMARY;
        _detailIndex  = 0;
        _buttonLocked = false;
        _menuOpen     = false;
        _menuIndex    = 0;
    }

    //! FR-021 — UP short → next screen (circular).
    function nextScreen() as Void {
        _screenIndex = (_screenIndex + 1) % SCREEN_COUNT;
        _detailIndex = 0;
    }

    //! FR-022 — DOWN short → next sub-page (circular).
    function nextDetail() as Void {
        _detailIndex = (_detailIndex + 1) % _getMaxDetail();
    }

    function resetDetail() as Void { _detailIndex = 0; }

    //! All 14 screens expose exactly 4 sub-pages (overview + 3 detail).
    private function _getMaxDetail() as Number { return 4; }

    function getScreenIndex() as Number { return _screenIndex; }
    function getDetailIndex() as Number { return _detailIndex; }

    //! FR-028 — DOWN long → toggle button lock.
    function toggleButtonLock() as Void { _buttonLocked = !_buttonLocked; }
    function isButtonLocked()    as Boolean { return _buttonLocked; }

    //! FR-027 — UP long → open capture menu.
    function openMenu() as Void {
        _menuOpen  = true;
        _menuIndex = 0;
    }
    function closeMenu() as Void { _menuOpen = false; }
    function isMenuOpen()  as Boolean { return _menuOpen; }

    function nextMenuItem() as Void {
        _menuIndex = (_menuIndex + 1) % MENU_COUNT;
    }
    function getMenuIndex() as Number { return _menuIndex; }
}
