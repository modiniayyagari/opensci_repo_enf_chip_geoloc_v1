#include "normal_attestation_client.h"
#include "normal_smc.h"
#include "normal_uart_protocol.h"

#include "xil_printf.h"
#include "xstatus.h"

#include <stddef.h>
#include <string.h>

typedef struct {
    u32 RequestId;
    u8 Nonce[ATTESTATION_NONCE_BYTES];
    u8 VerifierId[ATTESTATION_VERIFIER_ID_BYTES];
    int Valid;
} PendingChallenge;

AttestationMailbox SharedAttestationMailbox
    __attribute__((section(".attestation_mailbox"), aligned(64)));

static PendingChallenge Pending;

typedef char CheckResponseMagicOffset[
    (offsetof(AttestationMailbox, ResponseMagic) == 60U) ? 1 : -1];
typedef char CheckMessageOffset[
    (offsetof(AttestationMailbox, Message) == 80U) ? 1 : -1];
typedef char CheckSignatureOffset[
    (offsetof(AttestationMailbox, Signature) == 401U) ? 1 : -1];

static void MemoryBarrier(void)
{
    __asm__ volatile (
        "dsb sy\n"
        "isb\n"
        :
        :
        : "memory");
}

static int MailboxResponseIsValid(u32 service_status)
{
    return (service_status == SECURE_SERVICE_OK) &&
           (SharedAttestationMailbox.ResponseMagic ==
                ATTESTATION_RESPONSE_MAGIC) &&
           (SharedAttestationMailbox.Status == ATTESTATION_STATUS_OK);
}

static int InitializeSecureService(
    u32 service_id,
    const char *failure_message)
{
    u32 service_status;

    memset(&SharedAttestationMailbox, 0, sizeof(SharedAttestationMailbox));
    MemoryBarrier();
    service_status = normal_smc_call(service_id);
    MemoryBarrier();

    if (!MailboxResponseIsValid(service_status)) {
        xil_printf("[NORMAL] ERROR: %s\r\n", failure_message);
        return 0;
    }

    return 1;
}

int NormalAttestationInitialize(void)
{
    int ready = 1;

    ready &= InitializeSecureService(
        SECURE_SERVICE_CAPTURE_INITIALIZE,
        "Secure capture init failed");
    ready &= InitializeSecureService(
        SECURE_SERVICE_DDR_SELF_TEST,
        "Secure DDR self-test failed");
    ready &= InitializeSecureService(
        SECURE_SERVICE_ENF_PROCESSING_INITIALIZE,
        "Secure ENF processing init failed");

    return ready;
}

void NormalAttestationClearPending(void)
{
    memset(&Pending, 0, sizeof(Pending));
}

void NormalAttestationStoreChallenge(
    u32 request_id,
    const u8 nonce[ATTESTATION_NONCE_BYTES],
    const u8 verifier_id[ATTESTATION_VERIFIER_ID_BYTES])
{
    NormalAttestationClearPending();
    Pending.RequestId = request_id;
    memcpy(Pending.Nonce, nonce, sizeof(Pending.Nonce));
    memcpy(Pending.VerifierId, verifier_id, sizeof(Pending.VerifierId));

    /* Capture must wait for a matching GET ENF command. */
    Pending.Valid = 1;
}

int NormalAttestationRequestMatches(u32 request_id)
{
    return (Pending.Valid == 1) && (Pending.RequestId == request_id);
}

static int CallSecureService(u32 service_id, u32 *error_code)
{
    u32 service_status;

    MemoryBarrier();
    service_status = normal_smc_call(service_id);
    MemoryBarrier();

    if (!MailboxResponseIsValid(service_status)) {
        *error_code = SharedAttestationMailbox.ErrorCode;
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

/* xil_printf need not support 64-bit integer conversions. */
static void PrintBenchmarkUnsigned(u64 Value)
{
    char Digits[21];
    u32 Position = sizeof(Digits) - 1U;
    Digits[Position] = '\0';
    do {
        Digits[--Position] = (char)('0' + (Value % 10U));
        Value /= 10U;
    } while (Value != 0U);
    xil_printf(" %s", &Digits[Position]);
}

int NormalAttestationRunPending(u32 *error_code)
{
    if ((error_code == NULL) || (Pending.Valid != 1)) {
        return XST_FAILURE;
    }

    *error_code = 0U;
    memset(&SharedAttestationMailbox, 0, sizeof(SharedAttestationMailbox));
    SharedAttestationMailbox.RequestMagic = ATTESTATION_REQUEST_MAGIC;
    SharedAttestationMailbox.RequestId = Pending.RequestId;
    SharedAttestationMailbox.Mode = ATTESTATION_MODE_ENF;
    memcpy(SharedAttestationMailbox.Nonce,
           Pending.Nonce,
           sizeof(Pending.Nonce));
    memcpy(SharedAttestationMailbox.VerifierId,
           Pending.VerifierId,
           sizeof(Pending.VerifierId));

    /*
     * BEGIN records the challenge, CAPTURE_SESSION performs private capture,
     * and FINALIZE returns authenticated evidence. Raw samples stay entirely
     * within Secure World.
     */
    if (CallSecureService(
            SECURE_SERVICE_ATTESTATION_BEGIN,
            error_code) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    if (CallSecureService(
            SECURE_SERVICE_CAPTURE_SESSION,
            error_code) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    if (CallSecureService(
            SECURE_SERVICE_ATTESTATION_FINALIZE,
            error_code) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    if ((SharedAttestationMailbox.MessageLength !=
            ATTESTATION_ENF_EVIDENCE_BYTES) ||
        (SharedAttestationMailbox.SignatureLength !=
            ATTESTATION_SIGNATURE_BYTES)) {
        *error_code = SharedAttestationMailbox.ErrorCode;
        return XST_FAILURE;
    }

    NormalProtocolSendAuthenticatedHexRecord(
        "ZB_ENF_EVIDENCE",
        Pending.RequestId,
        SharedAttestationMailbox.Message,
        SharedAttestationMailbox.MessageLength);
    NormalProtocolSendAuthenticatedHexRecord(
        "ZB_SIGNATURE",
        Pending.RequestId,
        SharedAttestationMailbox.Signature,
        SharedAttestationMailbox.SignatureLength);

    /* Unsigned timing diagnostics follow the signature and precede DONE. */
    xil_printf("ZB_BENCHMARK");
    PrintBenchmarkUnsigned(Pending.RequestId);
    PrintBenchmarkUnsigned(SharedAttestationMailbox.BenchmarkTimerHz);
    PrintBenchmarkUnsigned(SharedAttestationMailbox.BenchmarkFrameCount);
    PrintBenchmarkUnsigned(SharedAttestationMailbox.BenchmarkFrameTotalTicks);
    PrintBenchmarkUnsigned(SharedAttestationMailbox.BenchmarkFrameMinTicks);
    PrintBenchmarkUnsigned(SharedAttestationMailbox.BenchmarkFrameMaxTicks);
    PrintBenchmarkUnsigned(SharedAttestationMailbox.BenchmarkCryptoTicks);
    xil_printf("\r\n");

    return XST_SUCCESS;
}

