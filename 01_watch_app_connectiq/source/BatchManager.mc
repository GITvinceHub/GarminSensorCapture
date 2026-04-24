import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

//! Batch accumulator — buffers IMU samples until dispatch.
//!
//! Implements contracts C-010, C-011 per SPECIFICATION.md §7.2.
//!
//! Dispatch triggers (any of):
//!  - MAX_BATCH_SIZE (25) samples accumulated
//!  - BATCH_TIMEOUT_MS (1000) elapsed since first sample in batch
//!  - URGENT_FLUSH_THRESHOLD sample overflow (defensive)
//!
//! INVARIANT: 0 <= _batch.size() <= MAX_BATCH_SIZE at all times.
class BatchManager {

    typedef BatchCallback as Method(samples as Array<Dictionary>) as Void;

    //! Protocol v1 limit — must match what PacketSerializer and Android expect.
    private const MAX_BATCH_SIZE = 25;

    //! Upper bound on batch accumulation time — also triggers dispatch even
    //! when sample rate is low (so the phone sees fresh data within ~1 s).
    private const BATCH_TIMEOUT_MS = 1000;

    //! Safety net: if something holds _batch above this size, force-flush.
    //! Should never fire under normal operation.
    private const URGENT_FLUSH_THRESHOLD = 80;

    private var _callback       as BatchCallback;
    private var _batch          as Array<Dictionary>;
    private var _batchStartTime as Number;
    private var _timer          as Timer.Timer or Null;
    private var _timerRunning   as Boolean;
    private var _batchesSent    as Number;
    private var _droppedSamples as Number;
    private var _lastBatchSize  as Number;

    function initialize(callback as BatchCallback) {
        _callback       = callback;
        _batch          = [] as Array<Dictionary>;
        _batchStartTime = 0;
        _timer          = null;
        _timerRunning   = false;
        _batchesSent    = 0;
        _droppedSamples = 0;
        _lastBatchSize  = 0;
    }

    //! Reset counters and stop the timer. Called on session start.
    function reset() as Void {
        _batch          = [] as Array<Dictionary>;
        _batchStartTime = 0;
        _stopTimer();
        _batchesSent    = 0;
        _droppedSamples = 0;
        _lastBatchSize  = 0;
    }

    //! C-010 accumulate(sample).
    //! Precondition: sample is a non-null Dictionary with IMU keys.
    //! Postcondition: sample is in _batch, OR the batch was dispatched and
    //!   _batch was reset. INVARIANT 0 <= _batch.size() <= MAX_BATCH_SIZE preserved.
    function accumulate(sample as Dictionary) as Void {
        if (sample == null) { return; }

        if (_batch.size() == 0) {
            _batchStartTime = System.getTimer();
            _startTimer();
        }

        _batch.add(sample);

        if (_batch.size() >= MAX_BATCH_SIZE) {
            _dispatchBatch();
        } else if (_batch.size() >= URGENT_FLUSH_THRESHOLD) {
            System.println("BatchManager: urgent flush at " + _batch.size().toString() + " samples");
            _dispatchBatch();
        }
    }

    function isBatchReady() as Boolean {
        if (_batch.size() == 0)               { return false; }
        if (_batch.size() >= MAX_BATCH_SIZE)  { return true; }
        var elapsed = System.getTimer() - _batchStartTime;
        return elapsed >= BATCH_TIMEOUT_MS;
    }

    function getBatch() as Array<Dictionary> {
        var result = _batch.slice(0, null);
        _batch          = [] as Array<Dictionary>;
        _batchStartTime = 0;
        return result;
    }

    //! Force-dispatch anything in the buffer. Used on session stop.
    function flush() as Void {
        _stopTimer();
        if (_batch.size() > 0) {
            System.println("BatchManager: flush " + _batch.size().toString() + " samples");
            try {
                _dispatchBatch();
            } catch (ex instanceof Lang.Exception) {
                System.println("BatchManager: FATAL in flush: " + ex.getErrorMessage());
                _batch = [] as Array<Dictionary>;
            }
        }
    }

    private function _dispatchBatch() as Void {
        if (_batch.size() == 0) { return; }

        var batchToSend = _batch.slice(0, null);
        _batch          = [] as Array<Dictionary>;
        _batchStartTime = 0;
        _stopTimer();

        _lastBatchSize = batchToSend.size();
        _batchesSent++;
        _callback.invoke(batchToSend);
    }

    private function _startTimer() as Void {
        if (_timerRunning) { return; }
        try {
            _timer = new Timer.Timer();
            (_timer as Timer.Timer).start(
                method(:_onBatchTimeout),
                BATCH_TIMEOUT_MS,
                false
            );
            _timerRunning = true;
        } catch (ex instanceof Lang.Exception) {
            System.println("BatchManager: timer start failed: " + ex.getErrorMessage());
            _timerRunning = false;
            _timer = null;
        }
    }

    private function _stopTimer() as Void {
        if (_timer != null) {
            try { (_timer as Timer.Timer).stop(); }
            catch (ex instanceof Lang.Exception) { }
            _timer = null;
        }
        _timerRunning = false;
    }

    //! C-011 _onBatchTimeout().
    //! Precondition: called by CIQ Timer after BATCH_TIMEOUT_MS.
    //! Postcondition: if _batch non-empty, dispatched; no exception propagates (NFR-012).
    function _onBatchTimeout() as Void {
        _timerRunning = false;
        _timer = null;

        if (_batch.size() > 0) {
            System.println("BatchManager: timeout flush " + _batch.size().toString() + " samples");
            try {
                _dispatchBatch();
            } catch (ex instanceof Lang.Exception) {
                System.println("BatchManager: FATAL in timeout: " + ex.getErrorMessage());
                _batch = [] as Array<Dictionary>;
            }
        }
    }

    function getCurrentBatchSize() as Number    { return _batch.size(); }
    function getBatchesSent()      as Number    { return _batchesSent; }
    function getLastBatchSize()    as Number    { return _lastBatchSize; }
    function getDroppedSampleCount() as Number  { return _droppedSamples; }

    function getQueuePressure() as Number {
        return (_batch.size() * 100) / URGENT_FLUSH_THRESHOLD;
    }
}
