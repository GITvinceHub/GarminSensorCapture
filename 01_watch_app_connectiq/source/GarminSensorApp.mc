import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! Main application entry point for GarminSensorCapture.
//! Owns the SessionManager (all sensor sub-systems) and the
//! UiState + ViewModel helpers that drive the 6-screen UI.
class GarminSensorApp extends Application.AppBase {

    //! Reference to the session manager (owns all subsystems)
    private var _sessionManager as SessionManager;

    //! Constructor — called once when the app starts
    function initialize() {
        AppBase.initialize();
        _sessionManager = new SessionManager();
    }

    //! Called when the app becomes active (foreground)
    //! @param state Optional state dictionary from previous invocation
    function onStart(state as Dictionary?) as Void {
        _sessionManager.setup();
    }

    //! Called when the app is being stopped (exit or background)
    //! @param state Optional state dictionary to persist
    function onStop(state as Dictionary?) as Void {
        _sessionManager.cleanup();
    }

    //! Return the initial view and delegate pair.
    //! UiState and ViewModel are created here and shared between view + delegate.
    //! @return Array of [View, InputDelegate]
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var uiState   = new UiState();
        var viewModel = new ViewModel();
        var view      = new MainView(_sessionManager, viewModel, uiState);
        var delegate  = new MainDelegate(_sessionManager, viewModel, uiState, view);
        return [view, delegate];
    }
}
