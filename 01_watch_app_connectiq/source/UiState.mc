import Toybox.Lang;

//! Manages all UI navigation state for the 6-screen watch interface.
//! Holds: active screen, detail sub-page within a screen, button-lock flag,
//! and capture-menu visibility. Stateless data only — no drawing or logic.
class UiState {

    //! Screen index constants (must match _drawXxx dispatch in MainView)
    static const SCREEN_HOME      = 0;
    static const SCREEN_IMU       = 1;
    static const SCREEN_GPS       = 2;
    static const SCREEN_HR        = 3;
    static const SCREEN_META      = 4;
    static const SCREEN_RECORDING = 5;
    static const SCREEN_COUNT     = 6;

    //! Detail page count for IMU screen (DOWN cycles through them)
    static const IMU_DETAIL_OVERVIEW = 0;
    static const IMU_DETAIL_ACC      = 1;
    static const IMU_DETAIL_GYRO     = 2;
    static const IMU_DETAIL_MAG      = 3;
    static const IMU_DETAIL_COUNT    = 4;

    //! Capture menu items
    static const MENU_NEW_SESSION  = 0;
    static const MENU_SYS_INFO     = 1;
    static const MENU_SENSORS      = 2;
    static const MENU_CLOSE        = 3;
    static const MENU_COUNT        = 4;

    //! Active screen index (0 .. SCREEN_COUNT-1)
    private var _screenIndex as Number;

    //! Active detail sub-page within the current screen
    private var _detailIndex as Number;

    //! True if buttons are locked (only DOWN unlocks)
    private var _buttonLocked as Boolean;

    //! True if the capture menu overlay is open
    private var _menuOpen as Boolean;

    //! Currently highlighted menu item
    private var _menuIndex as Number;

    function initialize() {
        _screenIndex  = SCREEN_HOME;
        _detailIndex  = 0;
        _buttonLocked = false;
        _menuOpen     = false;
        _menuIndex    = 0;
    }

    //! Advance to the next screen (circular).
    function nextScreen() as Void {
        _screenIndex = (_screenIndex + 1) % SCREEN_COUNT;
        _detailIndex = 0;
    }

    //! Step to the next detail sub-page in the current screen.
    function nextDetail() as Void {
        var maxDetail = _getMaxDetail();
        _detailIndex = (_detailIndex + 1) % maxDetail;
    }

    //! Reset detail index (e.g. when entering a screen).
    function resetDetail() as Void {
        _detailIndex = 0;
    }

    //! How many detail pages does the current screen have?
    private function _getMaxDetail() as Number {
        if (_screenIndex == SCREEN_IMU) {
            return IMU_DETAIL_COUNT;
        }
        return 1;  // other screens have no sub-pages yet
    }

    function getScreenIndex() as Number { return _screenIndex; }
    function getDetailIndex() as Number { return _detailIndex; }

    //! Toggle button lock on/off.
    function toggleButtonLock() as Void {
        _buttonLocked = !_buttonLocked;
    }

    function isButtonLocked() as Boolean { return _buttonLocked; }

    //! Open the capture menu (reset to first item).
    function openMenu() as Void {
        _menuOpen  = true;
        _menuIndex = 0;
    }

    //! Close the capture menu.
    function closeMenu() as Void {
        _menuOpen = false;
    }

    function isMenuOpen() as Boolean { return _menuOpen; }

    //! Advance to the next menu item (circular).
    function nextMenuItem() as Void {
        _menuIndex = (_menuIndex + 1) % MENU_COUNT;
    }

    function getMenuIndex() as Number { return _menuIndex; }
}
