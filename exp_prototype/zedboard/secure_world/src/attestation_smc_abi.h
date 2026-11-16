/* Shared SMC ABI with the Normal World application. */
#ifndef ATTESTATION_SMC_ABI_H
#define ATTESTATION_SMC_ABI_H
#include "xil_types.h"
#define SECURE_SERVICE_CAPTURE_INITIALIZE 9U
#define SECURE_SERVICE_DDR_SELF_TEST 11U
#define SECURE_SERVICE_ENF_PROCESSING_INITIALIZE 14U
#define SECURE_SERVICE_ATTESTATION_BEGIN 17U
#define SECURE_SERVICE_CAPTURE_SESSION 18U
#define SECURE_SERVICE_ATTESTATION_FINALIZE 19U
#define SECURE_SERVICE_OK 0U
#define SECURE_SERVICE_ERROR 0xFFFFFFFFU
#define ATTESTATION_MAILBOX_ADDRESS 0x00118000U
#define ATTESTATION_REQUEST_MAGIC 0x545A3351U
#define ATTESTATION_RESPONSE_MAGIC 0x545A3352U
#define ATTESTATION_STATUS_OK 0U
#define ATTESTATION_STATUS_ERROR 0xFFFFFFFFU
#define ATTESTATION_MODE_ENF 2U
#define ATTESTATION_NONCE_BYTES 16U
#define ATTESTATION_MESSAGE_CAPACITY 321U
#define ATTESTATION_EVIDENCE_BYTES 288U
#define ATTESTATION_SIGNATURE_BYTES 64U
#define ATTESTATION_FRAME_COUNT 25U
typedef struct {
 u32 RequestMagic, RequestId, Mode;
 u8 Nonce[16], VerifierId[16];
 /* Retained only to preserve offsets used by the current Secure World. */
 u32 CompatibilityChunkSampleCount, CompatibilityEnfIndex;
 u32 CompatibilityEnfWholeHz, CompatibilityEnfFractionNanohz;
 u32 ResponseMagic, Status, MessageLength, SignatureLength, ErrorCode;
 u8 Message[ATTESTATION_MESSAGE_CAPACITY];
 u8 Signature[ATTESTATION_SIGNATURE_BYTES];
 /* Unsigned diagnostic metadata; never part of canonical evidence. */
 u64 BenchmarkTimerHz;
 u32 BenchmarkFrameCount;
 u32 BenchmarkReserved;
 u64 BenchmarkFrameTotalTicks;
 u64 BenchmarkFrameMinTicks;
 u64 BenchmarkFrameMaxTicks;
 u64 BenchmarkCryptoTicks;
} AttestationMailbox;
#endif
