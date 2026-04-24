import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

//! Accumulates IMU samples and triggers batch dispatch.
//!
//! Batch is dispatched when EITHER:
//!  - MAX_BATCH_SIZE (25) samples accumulated
//!  - BATCH_TIMEOUT_MS (1000ms) elapsed since first sample in batch
//!  - Buffer occupancy > URGENT_FLUSH_THRESHOLD → immediate flush
class BatchManager {

    //! Callback type: called when a batch is ready to send
    typedef BatchCallback as Method(samples as Array<Dictionary>) as Void;

    //! Maximum samples per batch (protocol v1 limit)
    private const MAX_BATCH_SIZE = 25;

    //! Time limit for batch accumulation in milliseconds
    private const BATCH_TIMEOUT_MS = 1000;

    //! If internal buffer grows beyond this, force immediate flush
    private const URGENT_FLUSH_THRESHOLD = 80;

    //! Callback for batch delivery
    private var _callback as BatchCallback;

    //! Current accumulation buffer
    private var _batch as Array<Dictionary>;

    //! Timestamp of the first sample added to current batch
    private var _batchStartTime as Number;

    //! Periodic timeout timer
    private var _timer as Timer.Timer or Null;

    //! Whether the timer is running
    private var _timerRunning as Boolean;

    //! Total batches sent
    private var _batchesSent as Number;

    //! Samples dropped due to urgent overflow (never happens currently but tracked)
    private var _droppedSamples as Number;

    //! Size of the batch most recently dispatched
    private var _lastBatchSize as Number;

    //! @param callback Function called when a complete batch is ready
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

    //! Reset state (called at session start).
    function reset() as Void {
        _batch          = [] as Array<Dictionary>;
        _batchStartTime = 0;
        _stopTimer();
        _batchesSent    = 0;
        _droppedSamples = 0;
        _lastBatchSize  = 0;
    }

    //! Add a sample to the current batch.
    //! Triggers flush if batch is ready.
    //! @param sample Sensor sample dictionary
    function accumulate(sample as Dictionary) as Void {
        if (_batch.size() == 0) {
            // First sample — record start time, start timer
            _batchStartTime = System.getTimer();
            _startTimer();
        }

        _batch.add(sample);

        // Check flush conditions
        if (_batch.size() >= MAX_BATCH_SIZE) {
            _dispatchBatch();
        } else if (_batch.size() >= URGENT_FLUSH_THRESHOLD) {
            // Emergency: buffer dangerously full
            System.println("BatchManager: urgent flush at " + _batch.size() + " samples");
            _dispatchBatch();
        }
    }

    //! Check if the current batch meets the dispatch criteria.
    //! @return true if ready to send
    function isBatchReady() as Boolean {
        if (_batch.size() == 0) {
            return false;
        }
        if (_batch.size() >= MAX_BATCH_SIZE) {
            return true;
        }
        var elapsed = System.getTimer() - _batchStartTime;
        return elapsed >= BATCH_TIMEOUT_MS;
    }

    //! Get current batch samples and clear.
    //! @return Array of sample dictionaries
    function getBatch() as Array<Dictionary> {
        var result = _batch.slice(0, null);
        _batch = [] as Array<Dictionary>;
        _batchStartTime = 0;
        return result;
    }

    //! Force dispatch of whatever is in the batch buffer.
    //! Called at session stop or urgent overflow.
    function flush() as Void {
        _stopTimer();
        if (_batch.size() > 0) {
            System.println("BatchManager: flush " + _batch.size() + " samples");
            _dispatchBatch();
        }
    }

    //! Internal: dispatch current batch via callback.
    private function _dispatchBatch() as Void {
        if (_batch.size() == 0) {
            return;
        }

        var batchToSend = _batch.slice(0, null);
        _batch          = [] as Array<Dictionary>;
        _batchStartTime = 0;
        _stopTimer();

        _lastBatchSize = batchToSend.size();
        _batchesSent++;
        _callback.invoke(batchToSend);
    }

    //! Start the timeout timer for batch dispatch.
    private function _startTimer() as Void {
        if (_timerRunning) {
            return;
        }
        _timer = new Timer.Timer();
        (_timer as Timer.Timer).start(
            method(:_onBatchTimeout),
            BATCH_TIMEOUT_MS,
            false  // one-shot
        );
        _timerRunning = true;
    }

    //! Stop and discard the timeout timer.
    private function _stopTimer() as Void {
        if (_timer != null) {
            (_timer as Timer.Timer).stop();
            _timer = null;
        }
        _timerRunning = false;
    }

    //! Timer callback: batch timeout reached, dispatch whatever we have.
    function _onBatchTimeout() as Void {
        _timerRunning = false;
        _timer = null;

        if (_batch.size() > 0) {
            System.println("BatchManager: timeout flush " + _batch.size() + " samples");
            _dispatchBatch();
        }
    }

    //! @return Number of samples currently in the accumulation buffer
    function getCurrentBatchSize() as Number {
        return _batch.size();
    }

    //! @return Total number of batches dispatched this session
    function getBatchesSent() as Number {
        return _batchesSent;
    }

    //! @return Size of the most recently dispatched batch
    function getLastBatchSize() as Number {
        return _lastBatchSize;
    }

    //! @return Total samples dropped due to overflow
    function getDroppedSampleCount() as Number {
        return _droppedSamples;
    }

    //! @return Current buffer fill as a percentage of the urgent flush threshold
    function getQueuePressure() as Number {
        return (_batch.size() * 100) / URGENT_FLUSH_THRESHOLD;
    }
}

