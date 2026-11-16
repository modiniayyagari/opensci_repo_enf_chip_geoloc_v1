#include "secure_enf_processing.h"
#include "secure_enf_filter.h"

#include <math.h>

/*
 * PS ENF DSP workspace.
 *
 * This workspace is intentionally static:
 *
 *   - no malloc/free
 *   - fixed memory requirement
 *   - reusable for every 8-second frame
 *
 * Separate buffers mirror the validated ENF reference implementation.
 * Memory optimization
 * can be considered only after numerical parity is established.
 */
typedef struct
{
    /*
     * Raw 12-bit XADC values extracted from the 32-bit DMA words.
     */
    uint16_t decoded_samples[SECURE_ENF_INPUT_FRAME_SAMPLES];

    /*
     * 2000-Hz input after mean removal.
     */
    double mean_removed_samples[SECURE_ENF_INPUT_FRAME_SAMPLES];

    /*
     * 1050-Hz output from the 21/40 rational resampler.
     */
    double resampled_samples[SECURE_ENF_FRAME_SAMPLES];

    /*
     * Normalized 1050-Hz ENF frame.
     */
    double normalized_samples[SECURE_ENF_FRAME_SAMPLES];

    /*
     * 8400-point symmetric Hamming window.
     * Generated once during future DSP initialization.
     */
    double hamming_window[SECURE_ENF_FRAME_SAMPLES];

    /*
     * Zero-padded 32768-point FFT input.
     */
    double fft_input[SECURE_ENF_FFT_LENGTH];

    /*
     * Complex FFT output.
     */
    double fft_real[SECURE_ENF_FFT_LENGTH];
    double fft_imag[SECURE_ENF_FFT_LENGTH];

    /*
     * Only 20 FFT bins are used by the final ENF estimator.
     */
    double search_power[SECURE_ENF_SEARCH_BIN_COUNT];

    /*
     * Radix-2 FFT lookup tables.
     *
     * These correspond to the workspace dynamically allocated
     * by the validated ENF reference implementation.
     */
    size_t bit_reversed_indices[SECURE_ENF_FFT_LENGTH];

    double twiddle_cos[SECURE_ENF_FFT_LENGTH / 2U];
    double twiddle_sin[SECURE_ENF_FFT_LENGTH / 2U];

} secure_enf_workspace_t;


/*
 * Cortex-A9 is a 32-bit processor. These checks ensure our
 * workspace assumptions match the target build.
 */
_Static_assert(sizeof(uint16_t) == 2U,
               "Unexpected uint16_t size");

_Static_assert(sizeof(uint32_t) == 4U,
               "Unexpected uint32_t size");

_Static_assert(sizeof(size_t) == 4U,
               "Expected 32-bit size_t on Cortex-A9");

_Static_assert(sizeof(double) == 8U,
               "Expected IEEE-754 64-bit double");


/*
 * Expected workspace:
 *
 *     1,541,408 bytes
 *
 * approximately 1.47 MiB.
 */
_Static_assert(sizeof(secure_enf_workspace_t) == 1541408U,
               "Unexpected ENF workspace size");


_Static_assert(
    ((SECURE_ENF_INPUT_FRAME_SAMPLES * SECURE_ENF_RESAMPLE_L) +
     (SECURE_ENF_RESAMPLE_M - 1U)) /
        SECURE_ENF_RESAMPLE_M
        == SECURE_ENF_FRAME_SAMPLES,
    "16000 input samples must resample to exactly 8400 samples");

_Static_assert(
    (SECURE_ENF_SEARCH_BIN_FIRST +
     SECURE_ENF_SEARCH_BIN_COUNT) <=
        ((SECURE_ENF_FFT_LENGTH / 2U) + 1U),
    "ENF search bins exceed the one-sided FFT range");
    
/*
 * One persistent workspace is shared by all ENF frames.
 *
 * In the Secure monitor this resides in the dedicated
 * .secure_enf_workspace section in Secure DDR, not on the stack or in OCM.
 */
static secure_enf_workspace_t g_enf_workspace
    __attribute__((section(".secure_enf_workspace"), aligned(64)));

static int g_enf_hamming_initialized = 0;

static int g_enf_fft_initialized = 0;

/*
 * Align the first FIR coefficient index so that it has
 * the required interpolation phase.
 */
static size_t secure_enf_align_resample_phase_start(
    size_t minimum_index,
    size_t phase,
    size_t stride)
{
    const size_t remainder = minimum_index % stride;

    if (remainder == phase)
    {
        return minimum_index;
    }

    if (remainder < phase)
    {
        return minimum_index + (phase - remainder);
    }

    return minimum_index + (stride - (remainder - phase));
}


/*
 * MATLAB-compatible 21/40 rational resampler.
 *
 * Fixed configuration:
 *
 *     input  = 16000 samples @ 2000 Hz
 *     output =  8400 samples @ 1050 Hz
 *     FIR    =   801 coefficients
 */
static int secure_enf_resample_21_40(
    const double *input_samples,
    size_t input_count,
    double *output_samples,
    size_t output_capacity,
    size_t *output_count)
{
    size_t calculated_output_count;
    size_t group_delay;
    size_t max_input_offset;
    size_t output_index;

    if ((input_samples == NULL) ||
        (output_samples == NULL) ||
        (output_count == NULL) ||
        (input_count == 0U))
    {
        return SECURE_ENF_STATUS_INVALID_ARGUMENT;
    }

    /*
     * Same output-count rule as the validated ENF reference implementation:
     *
     * ceil(input_count * 21 / 40)
     */
    calculated_output_count =
        ((input_count * SECURE_ENF_RESAMPLE_L) +
         (SECURE_ENF_RESAMPLE_M - 1U)) /
        SECURE_ENF_RESAMPLE_M;

    if (output_capacity < calculated_output_count)
    {
        return SECURE_ENF_STATUS_INVALID_ARGUMENT;
    }

    /*
     * 801-tap symmetric FIR:
     *
     * group delay = (801 - 1) / 2 = 400
     */
    group_delay = (SECURE_ENF_RESAMPLE_FILTER_TAPS - 1U) / 2U;

    max_input_offset =
        (input_count - 1U) * SECURE_ENF_RESAMPLE_L;

    for (output_index = 0U;
         output_index < calculated_output_count;
         ++output_index)
    {
        const size_t center =
            group_delay +
            (output_index * SECURE_ENF_RESAMPLE_M);

        const size_t phase =
            center % SECURE_ENF_RESAMPLE_L;

        size_t filter_start = phase;

        const size_t filter_stop =
            (center < (SECURE_ENF_RESAMPLE_FILTER_TAPS - 1U))
                ? center
                : (SECURE_ENF_RESAMPLE_FILTER_TAPS - 1U);

        double accumulator = 0.0;

        /*
         * Handle the end boundary of the finite input frame.
         */
        if (center > max_input_offset)
        {
            const size_t minimum_index =
                center - max_input_offset;

            filter_start =
                secure_enf_align_resample_phase_start(
                    minimum_index,
                    phase,
                    SECURE_ENF_RESAMPLE_L);
        }

        if (filter_start <= filter_stop)
        {
            size_t filter_index;

            for (filter_index = filter_start;
                 filter_index <= filter_stop;
                 filter_index += SECURE_ENF_RESAMPLE_L)
            {
                const size_t input_index =
                    (center - filter_index) /
                    SECURE_ENF_RESAMPLE_L;

                const double input_value =
                    input_samples[input_index];

                const double filter_value =
                    g_secure_enf_resample_filter[filter_index];

                if ((!isfinite(input_value)) ||
                    (!isfinite(filter_value)))
                {
                    return SECURE_ENF_STATUS_INVALID_DATA;
                }

                accumulator +=
                    input_value * filter_value;
            }
        }

        if (!isfinite(accumulator))
        {
            return SECURE_ENF_STATUS_PROCESSING_FAILED;
        }

        output_samples[output_index] = accumulator;
    }

    *output_count = calculated_output_count;

    return SECURE_ENF_STATUS_OK;
}

static int secure_enf_normalize_resampled_frame(
    const double *input_samples,
    size_t sample_count,
    double normalization_peak,
    double *output_samples,
    double *input_peak,
    double *normalization_scale)
{
    size_t index;
    double peak = 0.0;
    double scale;

    if ((input_samples == NULL) ||
        (output_samples == NULL) ||
        (input_peak == NULL) ||
        (normalization_scale == NULL) ||
        (sample_count == 0U) ||
        (!isfinite(normalization_peak)) ||
        (normalization_peak <= 0.0))
    {
        return SECURE_ENF_STATUS_INVALID_ARGUMENT;
    }

    /*
     * Find the maximum absolute value of the
     * 1050-Hz resampled frame.
     */
    for (index = 0U; index < sample_count; ++index)
    {
        const double value = input_samples[index];
        const double magnitude = fabs(value);

        if (!isfinite(value))
        {
            return SECURE_ENF_STATUS_INVALID_DATA;
        }

        if (magnitude > peak)
        {
            peak = magnitude;
        }
    }

    if ((!isfinite(peak)) || (peak <= 0.0))
    {
        return SECURE_ENF_STATUS_INVALID_DATA;
    }

    /*
     * Same normalization used by the ENF reference implementation:
     *
     *     scale = 0.95 / peak
     */
    scale = normalization_peak / peak;

    if (!isfinite(scale))
    {
        return SECURE_ENF_STATUS_PROCESSING_FAILED;
    }

    for (index = 0U; index < sample_count; ++index)
    {
        output_samples[index] =
            input_samples[index] * scale;

        if (!isfinite(output_samples[index]))
        {
            return SECURE_ENF_STATUS_PROCESSING_FAILED;
        }
    }

    *input_peak = peak;
    *normalization_scale = scale;

    return SECURE_ENF_STATUS_OK;
}

static int secure_enf_generate_hamming_window(void)
{
    size_t index;
    const double pi = acos(-1.0);

    if (!isfinite(pi))
    {
        return SECURE_ENF_STATUS_PROCESSING_FAILED;
    }

    for (index = 0U; index < SECURE_ENF_FRAME_SAMPLES; ++index)
    {
        const double angle =
            (2.0 * pi * (double)index) /
            (double)(SECURE_ENF_FRAME_SAMPLES - 1U);

        const double value =
            0.54 - (0.46 * cos(angle));

        if (!isfinite(value))
        {
            return SECURE_ENF_STATUS_PROCESSING_FAILED;
        }

        g_enf_workspace.hamming_window[index] = value;
    }

    return SECURE_ENF_STATUS_OK;
}

static int secure_enf_prepare_fft_input(void)
{
    size_t index;

    /*
     * Zero-pad the complete 32768-point FFT input.
     */
    for (index = 0U; index < SECURE_ENF_FFT_LENGTH; ++index)
    {
        g_enf_workspace.fft_input[index] = 0.0;
    }

    /*
     * Window the 8400 normalized samples.
     *
     * Samples 0 ... 8399:
     *
     *     normalized sample * symmetric Hamming window
     *
     * Samples 8400 ... 32767 remain zero.
     */
    for (index = 0U; index < SECURE_ENF_FRAME_SAMPLES; ++index)
    {
        const double sample =
            g_enf_workspace.normalized_samples[index];

        const double window =
            g_enf_workspace.hamming_window[index];

        const double value =
            sample * window;

        if ((!isfinite(sample)) ||
            (!isfinite(window)) ||
            (!isfinite(value)))
        {
            return SECURE_ENF_STATUS_INVALID_DATA;
        }

        g_enf_workspace.fft_input[index] = value;
    }

    return SECURE_ENF_STATUS_OK;
}

static size_t secure_enf_fft_log2_size(size_t value)
{
    size_t result = 0U;

    while (value > 1U)
    {
        value >>= 1U;
        ++result;
    }

    return result;
}


static size_t secure_enf_fft_reverse_bits(
    size_t value,
    size_t width)
{
    size_t reversed = 0U;
    size_t index;

    for (index = 0U; index < width; ++index)
    {
        reversed =
            (reversed << 1U) |
            (value & 1U);

        value >>= 1U;
    }

    return reversed;
}


/*
 * Generate the bit-reversal and twiddle tables once.
 *
 * The FFT tables use the static Secure World workspace rather than malloc().
 */
static int secure_enf_fft_initialize(void)
{
    size_t index;
    const size_t log2_length =
        secure_enf_fft_log2_size(SECURE_ENF_FFT_LENGTH);

    const double pi = acos(-1.0);

    if (!isfinite(pi))
    {
        return SECURE_ENF_STATUS_PROCESSING_FAILED;
    }

    /*
     * Bit-reversal table.
     */
    for (index = 0U;
         index < SECURE_ENF_FFT_LENGTH;
         ++index)
    {
        g_enf_workspace.bit_reversed_indices[index] =
            secure_enf_fft_reverse_bits(
                index,
                log2_length);
    }

    /*
     * Twiddle factors:
     *
     *     exp(-j * 2*pi*k/N)
     */
    for (index = 0U;
         index < (SECURE_ENF_FFT_LENGTH / 2U);
         ++index)
    {
        const double angle =
            (-2.0 * pi * (double)index) /
            (double)SECURE_ENF_FFT_LENGTH;

        const double cosine = cos(angle);
        const double sine = sin(angle);

        if ((!isfinite(cosine)) ||
            (!isfinite(sine)))
        {
            return SECURE_ENF_STATUS_PROCESSING_FAILED;
        }

        g_enf_workspace.twiddle_cos[index] = cosine;
        g_enf_workspace.twiddle_sin[index] = sine;
    }

    return SECURE_ENF_STATUS_OK;
}


/*
 * Execute the same iterative radix-2 FFT used by
 * the validated ENF reference implementation.
 *
 * Input:
 *     g_enf_workspace.fft_input
 *
 * Output:
 *     g_enf_workspace.fft_real
 *     g_enf_workspace.fft_imag
 */
static int secure_enf_fft_execute(void)
{
    size_t index;
    size_t stage_size;

    /*
     * Initial bit-reversed copy.
     */
    for (index = 0U;
         index < SECURE_ENF_FFT_LENGTH;
         ++index)
    {
        const size_t reversed =
            g_enf_workspace.bit_reversed_indices[index];

        if (reversed >= SECURE_ENF_FFT_LENGTH)
        {
            return SECURE_ENF_STATUS_PROCESSING_FAILED;
        }

        g_enf_workspace.fft_real[index] =
            g_enf_workspace.fft_input[reversed];

        g_enf_workspace.fft_imag[index] = 0.0;
    }

    /*
     * Iterative radix-2 FFT butterfly stages.
     */
    for (stage_size = 2U;
         stage_size <= SECURE_ENF_FFT_LENGTH;
         stage_size <<= 1U)
    {
        const size_t half_size =
            stage_size / 2U;

        const size_t twiddle_step =
            SECURE_ENF_FFT_LENGTH / stage_size;

        size_t block_start;

        for (block_start = 0U;
             block_start < SECURE_ENF_FFT_LENGTH;
             block_start += stage_size)
        {
            size_t k;

            for (k = 0U;
                 k < half_size;
                 ++k)
            {
                const size_t even_index =
                    block_start + k;

                const size_t odd_index =
                    even_index + half_size;

                const size_t twiddle_index =
                    k * twiddle_step;

                const double twiddle_real =
                    g_enf_workspace.twiddle_cos[
                        twiddle_index];

                const double twiddle_imag =
                    g_enf_workspace.twiddle_sin[
                        twiddle_index];

                const double odd_real =
                    g_enf_workspace.fft_real[
                        odd_index];

                const double odd_imag =
                    g_enf_workspace.fft_imag[
                        odd_index];

                const double temp_real =
                    (twiddle_real * odd_real) -
                    (twiddle_imag * odd_imag);

                const double temp_imag =
                    (twiddle_real * odd_imag) +
                    (twiddle_imag * odd_real);

                const double even_real =
                    g_enf_workspace.fft_real[
                        even_index];

                const double even_imag =
                    g_enf_workspace.fft_imag[
                        even_index];

                g_enf_workspace.fft_real[
                    odd_index] =
                    even_real - temp_real;

                g_enf_workspace.fft_imag[
                    odd_index] =
                    even_imag - temp_imag;

                g_enf_workspace.fft_real[
                    even_index] =
                    even_real + temp_real;

                g_enf_workspace.fft_imag[
                    even_index] =
                    even_imag + temp_imag;
            }
        }
    }

    return SECURE_ENF_STATUS_OK;
}

static int secure_enf_compute_search_power(void)
{
    size_t index;
    double window_energy = 0.0;
    double power_scale;

    /*
     * Calculate the Hamming-window energy exactly as
     * the validated ENF reference implementation does.
     */
    for (index = 0U;
         index < SECURE_ENF_FRAME_SAMPLES;
         ++index)
    {
        const double window =
            g_enf_workspace.hamming_window[index];

        if (!isfinite(window))
        {
            return SECURE_ENF_STATUS_INVALID_DATA;
        }

        window_energy += window * window;
    }

    if ((!isfinite(window_energy)) ||
        (window_energy <= 0.0))
    {
        return SECURE_ENF_STATUS_PROCESSING_FAILED;
    }

    /*
     * Same one-sided FFT power scaling used by
     * the validated ENF reference implementation.
     */
    power_scale =
        2.0 /
        (SECURE_ENF_SAMPLE_RATE_HZ * window_energy);

    if ((!isfinite(power_scale)) ||
        (power_scale <= 0.0))
    {
        return SECURE_ENF_STATUS_PROCESSING_FAILED;
    }

    /*
     * Evaluate only the 20 ENF search bins:
     *
     *     1862 ... 1881
     */
    for (index = 0U;
         index < SECURE_ENF_SEARCH_BIN_COUNT;
         ++index)
    {
        const size_t bin_index =
            SECURE_ENF_SEARCH_BIN_FIRST + index;

        const double real_value =
            g_enf_workspace.fft_real[bin_index];

        const double imag_value =
            g_enf_workspace.fft_imag[bin_index];

        const double power =
            ((real_value * real_value) +
             (imag_value * imag_value)) *
            power_scale;

        if ((!isfinite(real_value)) ||
            (!isfinite(imag_value)) ||
            (!isfinite(power)))
        {
            return SECURE_ENF_STATUS_PROCESSING_FAILED;
        }

        g_enf_workspace.search_power[index] = power;
    }

    return SECURE_ENF_STATUS_OK;
}

static int secure_enf_estimate_frequency(
    double *enf_hz)
{
    size_t index;
    double numerator = 0.0;
    double denominator = 0.0;

    if (enf_hz == NULL)
    {
        return SECURE_ENF_STATUS_INVALID_ARGUMENT;
    }

    /*
     * Match the validated ENF reference estimator:
     *
     *     weight = power^3
     *
     *     ENF =
     *       sum(frequency * weight)
     *       -----------------------
     *            sum(weight)
     */
    for (index = 0U;
         index < SECURE_ENF_SEARCH_BIN_COUNT;
         ++index)
    {
        const size_t bin_index =
            SECURE_ENF_SEARCH_BIN_FIRST + index;

        const double frequency_hz =
            ((double)bin_index *
             SECURE_ENF_SAMPLE_RATE_HZ) /
            (double)SECURE_ENF_FFT_LENGTH;

        const double power =
            g_enf_workspace.search_power[index];

        const double weight =
            power * power * power;

        if ((!isfinite(frequency_hz)) ||
            (!isfinite(power)) ||
            (!isfinite(weight)))
        {
            return SECURE_ENF_STATUS_INVALID_DATA;
        }

        numerator += frequency_hz * weight;
        denominator += weight;
    }

    if ((!isfinite(numerator)) ||
        (!isfinite(denominator)) ||
        (denominator <= 0.0))
    {
        return SECURE_ENF_STATUS_PROCESSING_FAILED;
    }

    *enf_hz = numerator / denominator;

    if (!isfinite(*enf_hz))
    {
        return SECURE_ENF_STATUS_PROCESSING_FAILED;
    }

    return SECURE_ENF_STATUS_OK;
}

int secure_enf_init(void)
{
    int status;

    if (g_enf_hamming_initialized == 0)
    {
        status = secure_enf_generate_hamming_window();

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }

        g_enf_hamming_initialized = 1;
    }

    if (g_enf_fft_initialized == 0)
    {
        status = secure_enf_fft_initialize();

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }

        g_enf_fft_initialized = 1;
    }

    return SECURE_ENF_STATUS_OK;
}

int secure_enf_process_frame(
    const uint32_t *dma_samples,
    size_t sample_count,
    double *enf_hz)
{
    size_t index;
    double sum = 0.0;
    double mean;

    if ((dma_samples == NULL) ||
        (enf_hz == NULL) ||
        (sample_count != SECURE_ENF_INPUT_FRAME_SAMPLES))
    {
        return SECURE_ENF_STATUS_INVALID_ARGUMENT;
    }

    /*
     * Defensive initialization.
     *
     * In the live application secure_enf_init() will normally
     * already have been called during startup.
     */
    {
        const int status = secure_enf_init();

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }
    }    

    /*
     * Extract the valid 12-bit XADC value from each
     * 32-bit AXI-DMA word.
     */
    for (index = 0U; index < sample_count; ++index)
    {
        g_enf_workspace.decoded_samples[index] =
            (uint16_t)(dma_samples[index] & 0x0FFFU);

        sum += (double)g_enf_workspace.decoded_samples[index];
    }

    /*
     * Remove the mean from this 8-second frame.
     *
     * This matches the validated 16000-sample ENF reference calculation.
     */
    mean = sum / (double)sample_count;

    for (index = 0U; index < sample_count; ++index)
    {
        g_enf_workspace.mean_removed_samples[index] =
            (double)g_enf_workspace.decoded_samples[index] - mean;
    }

        /*
     * Resample:
     *
     *     16000 samples @ 2000 Hz
     *          â†“ 21 / 40
     *      8400 samples @ 1050 Hz
     */
    {
        size_t resampled_count = 0U;
        int status;

        status = secure_enf_resample_21_40(
            g_enf_workspace.mean_removed_samples,
            sample_count,
            g_enf_workspace.resampled_samples,
            SECURE_ENF_FRAME_SAMPLES,
            &resampled_count);

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }

        if (resampled_count != SECURE_ENF_FRAME_SAMPLES)
        {
            return SECURE_ENF_STATUS_PROCESSING_FAILED;
        }
    }

        /*
     * Normalize the 8400-sample resampled frame
     * to a peak magnitude of 0.95.
     */
    {
        double resampled_peak = 0.0;
        double normalization_scale = 0.0;
        int status;

        status = secure_enf_normalize_resampled_frame(
            g_enf_workspace.resampled_samples,
            SECURE_ENF_FRAME_SAMPLES,
            SECURE_ENF_NORMALIZATION_PEAK,
            g_enf_workspace.normalized_samples,
            &resampled_peak,
            &normalization_scale);

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }

        /*
         * These diagnostic values are intentionally not transmitted.
         */
        (void)resampled_peak;
        (void)normalization_scale;
    }

    /*
     * Apply the Hamming window and zero-pad the
     * 8400-sample ENF frame to 32768 FFT samples.
     */
    {
        const int status = secure_enf_prepare_fft_input();

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }
    }

    /*
     * Execute the 32768-point radix-2 FFT.
     */
    {
        const int status = secure_enf_fft_execute();

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }
    }

    /*
     * Calculate power for the 20 FFT bins used by
     * the ENF estimator.
     */
    {
        const int status =
            secure_enf_compute_search_power();

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }
    }

    /*
     * Estimate ENF using the cubic-power weighted
     * frequency centroid across the 20 search bins.
     */
    {
        const int status =
            secure_enf_estimate_frequency(enf_hz);

        if (status != SECURE_ENF_STATUS_OK)
        {
            return status;
        }
    }

    return SECURE_ENF_STATUS_OK;
}
