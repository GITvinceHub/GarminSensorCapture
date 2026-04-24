import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! Application entry point for GarminSensorCapture.
//! Implements contracts at the application lifecycle layer per SPECIFICATION.md §7.
//!
//! Owns:
//!  - SessionManager (orchestrator for all subsystems)
//!  - Initial MainView + MainDelegate pair
//!
//! Version: 2.0.0 (rewritten from SPECIFICATION.md v1.4.0 — SDD/BDD/DbC)
class GarminSensorApp extends Application.AppBase {

    private var _sessionManager as SessionManager;

    //! Constructor — called once by the CIQ runtime on app launch.
    //! No I/O is done here; all wiring is deferred to onStart().
    function initialize() {
        AppBase.initialize();
        _sessionManager = new SessionManager();
    }

    //! Called when the app becomes active.
    //! @param state Optional state dict passed by the CIQ runtime.
    function onStart(state as Dictionary?) as Void {
        try {
            _sessionManager.setup();
        } catch (ex instanceof Lang.Exception) {
            System.println("GarminSensorApp: setup failed: " + ex.getErrorMessage());
        }
    }

    //! Called when the app is exiting or being backgrounded.
    //! @param state Optional state dict for persistence.
    function onStop(state as Dictionary?) as Void {
        try {
            _sessionManager.cleanup();
        } catch (ex instanceof Lang.Exception) {
            System.println("GarminSensorApp: cleanup failed: " + ex.getErrorMessage());
        }
    }

    //! Build the initial view/delegate pair.
    //! UiState + ViewModel are shared between MainView and MainDelegate so input
    //! events mutate the same navigation state that the view renders from.
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var uiState   = new UiState();
        var viewModel = new ViewModel();
        var view      = new MainView(_sessionManager, viewModel, uiState);
        var delegate  = new MainDelegate(_sessionManager, viewModel, uiState, view);
        return [view, delegate];
    }
}
