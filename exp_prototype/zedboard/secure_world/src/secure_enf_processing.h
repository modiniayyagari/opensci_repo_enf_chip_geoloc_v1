#ifndef SECURE_ENF_PROCESSING_H
#define SECURE_ENF_PROCESSING_H

#include <stddef.h>
#include <stdint.h>

/*
 * Raw XADC acquisition configuration.
 *
 * One DMA chunk contains exactly 8 seconds of samples.
 */
#define SECURE_ENF_INPUT_SAMPLE_RATE_HZ       2000U
#define SECURE_ENF_INPUT_FRAME_SAMPLES        16000U

/*
 * Rational resampler:
 *
 *     2000 Hz * 21 / 40 = 1050 Hz
 */
#define SECURE_ENF_RESAMPLE_L                 21U
#define SECURE_ENF_RESAMPLE_M                 40U
#define SECURE_ENF_RESAMPLE_FILTER_TAPS       801U

/*
 * ENF processing frame after resampling.
 *
 *     8400 / 1050 = 8 seconds
 */
#define SECURE_ENF_SAMPLE_RATE_HZ             1050.0
#define SECURE_ENF_FRAME_SAMPLES              8400U

/*
 * ENF FFT configuration.
 */
#define SECURE_ENF_FFT_LENGTH                 32768U
#define SECURE_ENF_SEARCH_BIN_FIRST           1862U
#define SECURE_ENF_SEARCH_BIN_COUNT           20U

/*
 * Same normalization used by the validated ENF reference implementation.
 */
#define SECURE_ENF_NORMALIZATION_PEAK         0.95

typedef enum
{
    SECURE_ENF_STATUS_OK = 0,
    SECURE_ENF_STATUS_INVALID_ARGUMENT = -1,
    SECURE_ENF_STATUS_INVALID_DATA = -2,
    SECURE_ENF_STATUS_PROCESSING_FAILED = -3
} secure_enf_status_t;

/*
 * Initialize reusable ENF DSP state.
 *
 * Generates:
 *   - 8400-point symmetric Hamming window
 *   - FFT bit-reversal table
 *   - FFT sine/cosine twiddle tables
 *
 * Call once during application startup before processing
 * any live DMA frame.
 */
int secure_enf_init(void);

/*
 * Process exactly one 8-second DMA frame.
 *
 * dma_samples:
 *     16000 32-bit DMA words.
 *
 * The valid XADC sample is contained in the lower 12 bits
 * of each DMA word.
 *
 * enf_hz:
 *     Receives one ENF estimate.
 */
int secure_enf_process_frame(
    const uint32_t *dma_samples,
    size_t sample_count,
    double *enf_hz
);

#endif
