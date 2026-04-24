//! BatchManager.mc
//! Simple FIFO buffer for sensor samples (pure data structure, no timers, no I/O).
//!
//! Responsibility:
//!   - Accept samples pushed from SensorManager (very hot path — O(1)).
//!   - Let the dispatch Timer pull up to N samples at a time.
//!   - Cap buffer to MAX_BUFFER to protect memory if the phone is disconnected.
//!
//! Contracts:
//!   C-010 push(sample): 0 <= size() <= MAX_BUFFER (oldest dropped on overflow).
//!   pop(n): returns Array of up to n samples (oldest first), removes them.
using Toybox.Lang;

class BatchManager {

    //! Hard cap — dispatch Timer drains 25 every 250 ms = 100/s sustained throughput.
    //! 200 gives us ~2 s headroom if a couple of ticks are delayed.
    public static const MAX_BUFFER = 200;

    private var _buffer;       // Array< Dictionary<String, Number> >
    private var _overflowCount; // how many samples have been dropped due to overflow

    function initialize() {
        _buffer = [];
        _overflowCount = 0;
    }

    //! Push a new sample. Oldest sample is dropped if we hit MAX_BUFFER.
    //! MUST stay O(1) and tiny — called from SensorManager 100 times/s.
    function push(sample) {
        if (_buffer.size() >= MAX_BUFFER) {
            // Drop oldest (buffer overflow → ef flag at serialization time).
            _buffer = _buffer.slice(1, null);
            _overflowCount += 1;
        }
        _buffer.add(sample);
    }

    //! Remove and return up to n oldest samples. Returns [] when empty.
    function pop(n) {
        var size = _buffer.size();
        if (size == 0 || n <= 0) {
            return [];
        }
        var take = (size < n) ? size : n;
        var out = _buffer.slice(0, take);
        _buffer = _buffer.slice(take, null);
        return out;
    }

    function size() {
        return _buffer.size();
    }

    function clear() {
        _buffer = [];
    }

    //! Read-and-reset: number of samples dropped due to buffer overflow.
    function consumeOverflowCount() {
        var n = _overflowCount;
        _overflowCount = 0;
        return n;
    }
}
