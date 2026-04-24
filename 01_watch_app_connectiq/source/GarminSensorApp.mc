//! GarminSensorApp.mc
//! Application entry point.
//! Responsibility: instantiate SessionManager, provide initial view/delegate.
//! Keep this file tiny — delegates all behaviour to SessionManager.
using Toybox.Application;
using Toybox.WatchUi;
using Toybox.System;
using Toybox.Lang;

class GarminSensorApp extends Application.AppBase {

    //! Shared reference so MainView / MainDelegate can reach the session.
    public var sessionManager;

    function initialize() {
        AppBase.initialize();
        sessionManager = null;
    }

    //! onStart is invoked when the app starts up.
    function onStart(state) {
        try {
            sessionManager = new SessionManager();
        } catch (ex instanceof Lang.Exception) {
            System.println("App: onStart FATAL " + ex.getErrorMessage());
        }
    }

    //! onStop is invoked when the app exits. Make sure any active session is closed.
    function onStop(state) {
        try {
            if (sessionManager != null) {
                sessionManager.shutdown();
                sessionManager = null;
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("App: onStop FATAL " + ex.getErrorMessage());
        }
    }

    //! Return the initial view + delegate pair to the CIQ runtime.
    function getInitialView() {
        var view = new MainView(sessionManager);
        var delegate = new MainDelegate(sessionManager, view);
        return [view, delegate];
    }

    //! Global accessor used by other modules to reach the app instance.
    static function getApp() {
        return Application.getApp();
    }
}
