"""Acquire live PicoScope traces and provide shared capture-session helpers.

Standalone execution writes CSV traces using CONFIG; the HTTP service selects
its own duration and raw-int16 output. Requires a ps3000a device, native driver,
and Python wrapper. Trigger settings do not establish cross-device timing,
and these measurements are not cryptographically authenticated.
"""

# https://www.picotech.com/download/manuals/picoscope-3000-series-a-api-programmers-guide.pdf
# https://www.picotech.com/downloads/sdk-release/pico-software-development-kit-64bit
# https://github.com/picotech/picosdk-python-wrappers

# STEP_1: Dependencies and configuration
import ctypes
import numpy as np
import time
import os
from datetime import datetime
from picosdk.ps3000a import ps3000a as ps
from picosdk.functions import mV2adc, adc2mV, assert_pico_ok

# ======================================================================================
# 1. CONFIGURATION SETTINGS
# Standalone defaults; the HTTP service supplies its own capture duration and paths.
# ======================================================================================
CONFIG = {
    # --- Capture Mode ---
    # Options: 'SINGLE' for one capture, 'MULTIPLE' for an automated sequence.
    "CAPTURE_MODE": "SINGLE",

    # --- Multi-Trace Settings (only used if CAPTURE_MODE is 'MULTIPLE') ---
    "TOTAL_DURATION_MIN": 10,    # Total duration of the experiment in minutes.
    "CAPTURE_INTERVAL_MIN": 5,   # Interval between the start of each capture in minutes.

    # --- Capture Parameters ---
    "CAPTURE_DURATION_S": 1000,  # Standalone duration in seconds; HTTP service uses 220 s.
    "SAMPLING_RATE_HZ": 44100,    # Target sampling rate in Hertz.

    # --- File Parameters ---
    "SAVE_DIRECTORY": "pico_captures",
    "FILENAME_PREFIX": "pico_trace",

    # --- Channel A Settings ---
    "VOLTAGE_RANGE": "20mV",
    "COUPLING_TYPE": "AC",
    "ANALOG_OFFSET_V": 0.0,

    # --- Trigger Settings ---
    "TRIGGER_CHANNEL": "A",
    "TRIGGER_THRESHOLD_MV": 0.0,
    "TRIGGER_DIRECTION": "RISING",

    # --- SDK Constant Mappings (Do not change) ---
    "CHANNELS_MAP": {"A": 0, "B": 1},
    "COUPLING_MAP": {"AC": 0, "DC": 1},
    "DIRECTIONS_MAP": {"RISING": 2, "FALLING": 3},
    "VOLTAGE_RANGES_MAP": {
        "10mV": 0, "20mV": 1, "50mV": 2, "100mV": 3, "200mV": 4,
        "500mV": 5, "1V": 6, "2V": 7, "5V": 8, "10V": 9, "20V": 10
    }
}

# ======================================================================================
# 2. CORE PICOSCOPE FUNCTIONS
# These functions handle the low-level interactions with the device.
# ======================================================================================

# STEP_2: Device and channel configuration
def setup_picoscope(config):
    """Opens and configures the Picoscope device."""
    scope_handle = ctypes.c_int16()
    status = {}

    print("Attempting to open PicoScope device...")
    status["openunit"] = ps.ps3000aOpenUnit(ctypes.byref(scope_handle), None)
    assert_pico_ok(status["openunit"])
    print("Picoscope opened successfully.")

    try:
        # Configure Channel
        status["setChA"] = ps.ps3000aSetChannel(
            scope_handle, config["CHANNELS_MAP"][config["TRIGGER_CHANNEL"]], 1,
            config["COUPLING_MAP"][config["COUPLING_TYPE"]],
            config["VOLTAGE_RANGES_MAP"][config["VOLTAGE_RANGE"]],
            config["ANALOG_OFFSET_V"]
        )
        assert_pico_ok(status["setChA"])
        print(f"Channel {config['TRIGGER_CHANNEL']} configured: Range={config['VOLTAGE_RANGE']}, Coupling={config['COUPLING_TYPE']}.")

        # Configure Trigger
        max_adc = ctypes.c_int16()
        status["maximumValue"] = ps.ps3000aMaximumValue(scope_handle, ctypes.byref(max_adc))
        assert_pico_ok(status["maximumValue"])

        trigger_threshold_adc = mV2adc(
            config["TRIGGER_THRESHOLD_MV"],
            config["VOLTAGE_RANGES_MAP"][config["VOLTAGE_RANGE"]],
            max_adc
        )
        status["setSimpleTrigger"] = ps.ps3000aSetSimpleTrigger(
            scope_handle, 1, config["CHANNELS_MAP"][config["TRIGGER_CHANNEL"]],
            trigger_threshold_adc, config["DIRECTIONS_MAP"][config["TRIGGER_DIRECTION"]],
            0, 1000
        )
        assert_pico_ok(status["setSimpleTrigger"])
        print(f"Trigger configured on Channel {config['TRIGGER_CHANNEL']} at {config['TRIGGER_THRESHOLD_MV']} mV.")
    except Exception:
        # Do not leave an opened unit locked if configuration fails part-way through.
        ps.ps3000aStop(scope_handle)
        ps.ps3000aCloseUnit(scope_handle)
        raise

    return scope_handle, status, max_adc


def calculate_timebase(scope_handle, config):
    """Calculates the best timebase for the desired sampling rate."""
    total_samples = int(config["CAPTURE_DURATION_S"] * config["SAMPLING_RATE_HZ"])
    target_interval_ns = 1e9 / config["SAMPLING_RATE_HZ"]
    
    timebase = 0
    time_interval_ns = ctypes.c_float(0)

    while True:
        status = ps.ps3000aGetTimebase2(scope_handle, timebase, total_samples, ctypes.byref(time_interval_ns), 1, None, 0)
        if status == 0 and time_interval_ns.value >= target_interval_ns:
            break
        timebase += 1
        if timebase > 2**20:
            raise ValueError("Could not find a suitable timebase.")
            
    print(f"Found suitable timebase: {timebase}")
    print(f"Actual sampling interval: {time_interval_ns.value:.2f} ns (~{(1e9 / time_interval_ns.value / 1000):.2f} kHz)")
    
    return timebase, time_interval_ns, total_samples


def create_capture_session(scope_handle, config, timebase_info, max_adc, full_path=None):
    """Builds reusable state for split-phase capture without starting the scope."""
    timebase, time_interval_ns, total_samples = timebase_info

    if full_path is None:
        timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        filename = f"{config['FILENAME_PREFIX']}_{timestamp}.csv"
        full_path = os.path.join(config['SAVE_DIRECTORY'], filename)

    return {
        "scope_handle": scope_handle,
        "config": config,
        "max_adc": max_adc,
        "timebase": timebase,
        "time_interval_ns": time_interval_ns,
        "expected_samples": total_samples,
        "full_path": os.path.abspath(full_path),
        "status": {},
        "timestamps": {},
        "actual_samples": None,
    }


# STEP_3: Capture preparation
def prepare_capture(config, full_path=None):
    """Opens/configures the PicoScope and returns a READY capture session."""
    os.makedirs(config['SAVE_DIRECTORY'], exist_ok=True)
    scope_handle = None
    try:
        scope_handle, status, max_adc = setup_picoscope(config)
        timebase_info = calculate_timebase(scope_handle, config)
        session = create_capture_session(
            scope_handle, config, timebase_info, max_adc, full_path
        )
        session["status"].update(status)
        return session
    except Exception:
        if scope_handle is not None:
            close_picoscope(scope_handle)
        raise


def start_capture(session):
    """Starts block capture and returns only after RunBlock succeeds."""
    config = session["config"]
    print(f"\nStarting data capture... (This will take {config['CAPTURE_DURATION_S']} seconds)")
    session["status"]["runBlock"] = ps.ps3000aRunBlock(
        session["scope_handle"], 0, session["expected_samples"],
        session["timebase"], 1, None, 0, None, None
    )
    assert_pico_ok(session["status"]["runBlock"])
    session["timestamps"]["capture_began"] = datetime.now()
    session["timestamps"]["capture_started_utc"] = datetime.utcnow()
    session["timestamps"]["capture_started_perf_counter_ns"] = time.perf_counter_ns()
    return session["timestamps"]["capture_started_utc"]


# STEP_4: Acquisition completion and sample serialization
def complete_capture(session, output_format="csv"):
    """Waits for readiness, retrieves samples, and saves CSV or raw int16 data."""
    config = session["config"]
    scope_handle = session["scope_handle"]
    total_samples = session["expected_samples"]

    ready = ctypes.c_int16(0)
    while ready.value == 0:
        session["status"]["isReady"] = ps.ps3000aIsReady(
            scope_handle, ctypes.byref(ready)
        )
        assert_pico_ok(session["status"]["isReady"])
        if ready.value == 0:
            time.sleep(0.1)  # Poll every 100ms

    capture_end_time = datetime.now()
    session["timestamps"]["capture_ended"] = capture_end_time
    session["timestamps"]["capture_completed_utc"] = datetime.utcnow()
    session["timestamps"]["capture_completed_perf_counter_ns"] = time.perf_counter_ns()
    print("Capture complete. Retrieving data...")

    bufferA = (ctypes.c_int16 * total_samples)()
    session["status"]["setDataBuffers"] = ps.ps3000aSetDataBuffers(
        scope_handle, 0, ctypes.byref(bufferA), None, total_samples, 0, 0
    )
    assert_pico_ok(session["status"]["setDataBuffers"])

    c_total_samples = ctypes.c_int32(total_samples)
    session["status"]["getValues"] = ps.ps3000aGetValues(
        scope_handle, 0, ctypes.byref(c_total_samples), 1, 0, 0, None
    )
    assert_pico_ok(session["status"]["getValues"])
    actual_samples = c_total_samples.value
    if not 0 <= actual_samples <= total_samples:
        raise ValueError(
            f"PicoScope returned invalid sample count {actual_samples} "
            f"for buffer capacity {total_samples}"
        )
    session["actual_samples"] = actual_samples

    if output_format == "raw_int16_le":
        session["timestamps"]["trace_save_started_utc"] = datetime.utcnow()
        session["timestamps"]["trace_save_started_perf_counter_ns"] = time.perf_counter_ns()

        # np.ctypeslib.as_array is a view of the exact samples returned in
        # bufferA. astype(copy=False) preserves that zero-copy path on this
        # little-endian host while explicitly requiring little-endian int16.
        raw_adc_samples = np.ctypeslib.as_array(bufferA)[:actual_samples]
        little_endian_samples = raw_adc_samples.astype(
            np.dtype("<i2"), copy=False
        )
        little_endian_samples.tofile(session["full_path"])

        session["timestamps"]["trace_save_completed_utc"] = datetime.utcnow()
        session["timestamps"]["trace_save_completed_perf_counter_ns"] = time.perf_counter_ns()
        trace_size_bytes = os.path.getsize(session["full_path"])
        expected_size_bytes = actual_samples * np.dtype("<i2").itemsize
        if trace_size_bytes != expected_size_bytes:
            raise ValueError(
                f"raw trace size mismatch: expected {expected_size_bytes} bytes, "
                f"found {trace_size_bytes} bytes"
            )
        session["trace_size_bytes"] = trace_size_bytes
        session["trace_format"] = "raw_int16_le"
    elif output_format == "csv":
        adc_to_mv_data = adc2mV(
            bufferA,
            config["VOLTAGE_RANGES_MAP"][config["VOLTAGE_RANGE"]],
            session["max_adc"]
        )[:actual_samples]
        # Preserve the PicoScope-selected interval: sample i is at i * interval.
        time_s = (
            np.arange(actual_samples, dtype=np.float64)
            * session["time_interval_ns"].value
            / 1e9
        )

        session["timestamps"]["csv_saving_began"] = datetime.now()
        session["timestamps"]["csv_save_started_utc"] = datetime.utcnow()
        session["timestamps"]["csv_save_started_perf_counter_ns"] = time.perf_counter_ns()
        data_to_save = np.column_stack((time_s, adc_to_mv_data))
        np.savetxt(
            session["full_path"], data_to_save, delimiter=",",
            header="Time (s),Voltage (mV)", comments=""
        )
        session["timestamps"]["csv_saving_ended"] = datetime.now()
        session["timestamps"]["csv_save_completed_utc"] = datetime.utcnow()
        session["timestamps"]["csv_save_completed_perf_counter_ns"] = time.perf_counter_ns()
        session["trace_size_bytes"] = os.path.getsize(session["full_path"])
        session["trace_format"] = "csv"
    else:
        raise ValueError(f"unsupported capture output format: {output_format}")

    print(f"Success! Data saved to: '{session['full_path']}'")
    return session


def capture_and_save_trace(scope_handle, config, timebase_info, max_adc, profiling_results, timestamps_log):
    """Runs a single capture, saves the data, and records profiling and timestamp stats."""
    session = create_capture_session(
        scope_handle, config, timebase_info, max_adc
    )
    start_capture(session)
    capture_start_time = session["timestamps"]["capture_began"]
    complete_capture(session)
    capture_end_time = session["timestamps"]["capture_ended"]
    save_start_time = session["timestamps"]["csv_saving_began"]
    save_end_time = session["timestamps"]["csv_saving_ended"]

    # Store profiling and timestamp results
    profiling_results.append({
        'capture_duration': capture_end_time - capture_start_time,
        'save_duration': save_end_time - save_start_time
    })
    timestamps_log['traces'].append(session["timestamps"])
    return session


def close_picoscope(scope_handle):
    """Stops and closes the connection to the Picoscope."""
    stop_status = ps.ps3000aStop(scope_handle)
    close_status = ps.ps3000aCloseUnit(scope_handle)
    assert_pico_ok(stop_status)
    assert_pico_ok(close_status)
    print("\nPicoscope stopped and closed.")


# STEP_5: Diagnostic output
def print_profiling_summary(config_duration, profiling_results):
    """Prints the final summary of all timed durations."""
    print("\n" + "="*50)
    print("--- Code Profiling Summary (Durations) ---")
    print(f"Time taken to configure and arm the scope: {config_duration}")
    print("-" * 50)
    
    if not profiling_results:
        print("No captures were performed.")
    else:
        for i, result in enumerate(profiling_results):
            print(f"Trace #{i + 1}:")
            print(f"  Time taken to capture the trace:       {result['capture_duration']}")
            print(f"  Time taken to save the CSV file:       {result['save_duration']}")
    print("="*50)

def print_timestamp_log(timestamps_log):
    """Prints the final summary of all event timestamps."""
    
    def format_time(dt):
        """Helper to format datetime objects consistently."""
        if dt is None:
            return "N/A"
        return dt.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]

    print("\n" + "="*50)
    print("--- Event Timestamp Log ---")
    print(f"Script began:                             {format_time(timestamps_log['script_began'])}")
    print(f"Scope was configured and armed and ready: {format_time(timestamps_log['scope_configured_and_armed'])}")
    print("-" * 50)

    if not timestamps_log['traces']:
        print("No trace timestamps were recorded.")
    else:
        for i, trace in enumerate(timestamps_log['traces']):
            print(f"Trace #{i + 1}:")
            print(f"  Capture began:                      {format_time(trace.get('capture_began'))}")
            print(f"  Capture ended:                      {format_time(trace.get('capture_ended'))}")
            print(f"  CSV File saving began:              {format_time(trace.get('csv_saving_began'))}")
            print(f"  CSV file saving ended:              {format_time(trace.get('csv_saving_ended'))}")
    
    print("-" * 50)
    print(f"Script ended:                             {format_time(timestamps_log['script_ended'])}")
    print("="*50)


# ======================================================================================
# 3. MAIN EXECUTION BLOCK
# ======================================================================================
# STEP_6: Standalone acquisition entrypoint
def main():
    """Main function to run the capture script."""
    
    # Initialize logging dictionaries
    profiling_results = []
    timestamps_log = {
        'script_began': datetime.now(),
        'scope_configured_and_armed': None,
        'traces': [],
        'script_ended': None
    }
    
    print("--- Picoscope Automated Capture Tool ---")
    
    # Create save directory
    os.makedirs(CONFIG['SAVE_DIRECTORY'], exist_ok=True)
    
    # Profile the setup and configuration time
    config_start_time = datetime.now()
    scope_handle, status, max_adc = setup_picoscope(CONFIG)
    timebase_info = calculate_timebase(scope_handle, CONFIG)
    config_end_time = datetime.now()
    config_duration = config_end_time - config_start_time
    timestamps_log['scope_configured_and_armed'] = config_end_time
    
    mode = CONFIG.get("CAPTURE_MODE", "SINGLE").upper()

    if mode == 'SINGLE':
        print("\nStarting single trace capture mode.")
        capture_and_save_trace(scope_handle, CONFIG, timebase_info, max_adc, profiling_results, timestamps_log)
        
    elif mode == 'MULTIPLE':
        total_duration_min = CONFIG['TOTAL_DURATION_MIN']
        interval_min = CONFIG['CAPTURE_INTERVAL_MIN']
        
        if interval_min * 60 <= CONFIG['CAPTURE_DURATION_S']:
            print(f"Error: CAPTURE_INTERVAL_MIN ({interval_min} min) must be longer than CAPTURE_DURATION_S ({CONFIG['CAPTURE_DURATION_S']/60:.2f} min).")
        else:
            capture_interval_s = interval_min * 60
            num_captures = int((total_duration_min * 60) / capture_interval_s)
            
            print(f"\nStarting automated capture sequence for {total_duration_min} minutes.")
            print(f"Will perform {num_captures} captures, one every {interval_min} minutes.")
            
            for i in range(num_captures):
                print(f"\n--- Running Capture {i + 1} of {num_captures} ---")
                capture_loop_start_time = time.time()
                capture_and_save_trace(scope_handle, CONFIG, timebase_info, max_adc, profiling_results, timestamps_log)
                capture_loop_end_time = time.time()
                
                elapsed_time = capture_loop_end_time - capture_loop_start_time
                
                if i < num_captures - 1:
                    sleep_time = capture_interval_s - elapsed_time
                    if sleep_time > 0:
                        print(f"Waiting for {sleep_time:.2f} seconds until the next capture...")
                        time.sleep(sleep_time)
                    else:
                        print("Warning: Capture took longer than the interval. Starting next one immediately.")
    
    else:
        print(f"Error: Invalid CAPTURE_MODE '{mode}' in CONFIG. Use 'SINGLE' or 'MULTIPLE'.")

    # Record script end time and print summaries
    timestamps_log['script_ended'] = datetime.now()
    print_profiling_summary(config_duration, profiling_results)
    print_timestamp_log(timestamps_log)
    
    # Cleanup
    close_picoscope(scope_handle)

if __name__ == "__main__":
    main()

