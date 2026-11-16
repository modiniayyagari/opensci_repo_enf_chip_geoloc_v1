/* Owns DMA capture and ENF session state. */
#include "secure_enf_capture.h"
#include "secure_enf_evidence.h"

#include "xparameters.h"
#include "xaxidma.h"
#include "xgpio.h"

#include "xil_cache.h"
#include "xstatus.h"
#include "xiltimer.h"
#include "sleep.h"
#include "secure_enf_processing.h"

#include <math.h>
#include <stddef.h>
#include <string.h>
#define SECURE_AXI_DMA_BASE_ADDRESS 0x40400000U
#define SECURE_CAPTURE_GPIO_BASE_ADDRESS 0x41210000U
#define SECURE_DDR_CAPTURE_BUFFER_A_ADDR 0x1C000000U
#define SECURE_DDR_CAPTURE_BUFFER_B_ADDR 0x1C010000U
#define SECURE_ENF_WORKSPACE_ADDR 0x1C100000U
#define SECURE_CAPTURE_FRAME_SAMPLES 16000U
#define SECURE_CAPTURE_FRAME_BYTES 64000U
#define SECURE_CAPTURE_TOTAL_SAMPLES 400000U
#define SECURE_CAPTURE_POLL_LIMIT 120000U
#define PL_STATUS_BUSY_MASK 1U
#define PL_STATUS_DONE_MASK 2U
#define PL_STATUS_ERROR_MASK 4U
#define PL_STATUS_COUNT_SHIFT 3U
#define PL_STATUS_COUNT_MASK 0x0007FFFFU

static XAxiDma SecureAxiDma;
static XGpio SecureCaptureGpio;
static u32 SecureCaptureInitDone = 0U;
static u32 SecureCaptureFramesSeen = 0U;
static u32 SecureEnfDspInitDone = 0U;
static u32 SecureAttestationActive = 0U;
static u32 SecureAttestationFramesSeen = 0U;
static u32 SecureAttestationRequestId = 0U;
static u8 SecureAttestationNonce[16];
static u8 SecureAttestationVerifierId[16];
static u64 SecureAttestationValuesNhz[ATTESTATION_FRAME_COUNT];
/* Per-session timing diagnostics are excluded from signed evidence. */
static u64 BenchmarkFrameTotalTicks;
static u64 BenchmarkFrameMinTicks;
static u64 BenchmarkFrameMaxTicks;
static u64 BenchmarkFrameCount;

static void SecureZero(void *Buffer, size_t ByteCount)
{
    volatile u8 *Bytes = (volatile u8 *)Buffer;

    while (ByteCount != 0U) {
        *Bytes = 0U;
        Bytes++;
        ByteCount--;
    }
}

static void SecureMailboxBarrier(void)
{
    __asm__ volatile (
        "dsb sy\n"
        "isb\n"
        :
        :
        : "memory");
}

static void SecureFlushMailbox(AttestationMailbox *Mailbox)
{
    Xil_DCacheFlushRange((UINTPTR)Mailbox, (u32)sizeof(*Mailbox));
    SecureMailboxBarrier();
}

static void SecureInitResponse(AttestationMailbox *Mailbox)
{
    Mailbox->ResponseMagic = ATTESTATION_RESPONSE_MAGIC;
    Mailbox->Status = ATTESTATION_STATUS_ERROR;
    Mailbox->MessageLength = 0U;
    Mailbox->SignatureLength = 0U;
    Mailbox->ErrorCode = 0U;
    Mailbox->BenchmarkTimerHz = 0U;
    Mailbox->BenchmarkFrameCount = 0U;
    Mailbox->BenchmarkReserved = 0U;
    Mailbox->BenchmarkFrameTotalTicks = 0U;
    Mailbox->BenchmarkFrameMinTicks = 0U;
    Mailbox->BenchmarkFrameMaxTicks = 0U;
    Mailbox->BenchmarkCryptoTicks = 0U;
}

static void SecureClearOutputs(AttestationMailbox *Mailbox)
{
    memset(Mailbox->Message, 0, sizeof(Mailbox->Message));
    memset(Mailbox->Signature, 0, sizeof(Mailbox->Signature));
}

static u32 SecureFail(AttestationMailbox *Mailbox, u32 ErrorCode)
{
    if (Mailbox != NULL) {
        Mailbox->ResponseMagic = ATTESTATION_RESPONSE_MAGIC;
        Mailbox->Status = ATTESTATION_STATUS_ERROR;
        Mailbox->MessageLength = 0U;
        Mailbox->SignatureLength = 0U;
        Mailbox->ErrorCode = ErrorCode;
        SecureFlushMailbox(Mailbox);
    }

    return SECURE_SERVICE_ERROR;
}

static u32 SecureOk(AttestationMailbox *Mailbox)
{
    Mailbox->ResponseMagic = ATTESTATION_RESPONSE_MAGIC;
    Mailbox->Status = ATTESTATION_STATUS_OK;
    Mailbox->ErrorCode = 0U;
    SecureFlushMailbox(Mailbox);

    return SECURE_SERVICE_OK;
}

/*
 * Secure World controls XADC/PL/DMA capture. Normal World requests capture
 * through SMC, while the DDR capture buffer is protected by the configured
 * TrustZone memory policy.
 */
u32 SecureCaptureInitialize(AttestationMailbox *Mailbox)
{
    XAxiDma_Config *DmaConfig;
    XGpio_Config *GpioConfig;

    if (Mailbox == NULL) {
        return SECURE_SERVICE_ERROR;
    }

    SecureInitResponse(Mailbox);
    SecureCaptureInitDone = 0U;
    SecureCaptureFramesSeen = 0U;

    DmaConfig = XAxiDma_LookupConfig(SECURE_AXI_DMA_BASE_ADDRESS);
    if (DmaConfig == NULL) {
        return SecureFail(Mailbox, 101U);
    }

    if (XAxiDma_CfgInitialize(&SecureAxiDma, DmaConfig) != XST_SUCCESS) {
        return SecureFail(Mailbox, 102U);
    }

    if (XAxiDma_HasSg(&SecureAxiDma) || (DmaConfig->HasS2Mm == 0)) {
        return SecureFail(Mailbox, 103U);
    }

    GpioConfig = XGpio_LookupConfig(SECURE_CAPTURE_GPIO_BASE_ADDRESS);
    if (GpioConfig == NULL) {
        return SecureFail(Mailbox, 104U);
    }

    if (XGpio_CfgInitialize(
            &SecureCaptureGpio,
            GpioConfig,
            GpioConfig->BaseAddress) != XST_SUCCESS) {
        return SecureFail(Mailbox, 104U);
    }

    XGpio_SetDataDirection(&SecureCaptureGpio, 1, 0x00000000U);
    XGpio_SetDataDirection(&SecureCaptureGpio, 2, 0xFFFFFFFFU);
    XGpio_DiscreteWrite(&SecureCaptureGpio, 1, 0x00000000U);

    SecureCaptureInitDone = 1U;
    return SecureOk(Mailbox);
}

u32 SecureDdrSelfTest(AttestationMailbox *Mailbox)
{
    volatile u32 *Buffer;
    u32 Index;

    if (Mailbox == NULL) {
        return SECURE_SERVICE_ERROR;
    }

    SecureInitResponse(Mailbox);
    Buffer = (volatile u32 *)(UINTPTR)SECURE_DDR_CAPTURE_BUFFER_A_ADDR;

    for (Index = 0U; Index < 16U; Index++) {
        Buffer[Index] = 0xA6000000U | Index;
    }

    SecureMailboxBarrier();

    for (Index = 0U; Index < 16U; Index++) {
        if (Buffer[Index] != (0xA6000000U | Index)) {
            return SecureFail(Mailbox, 200U);
        }
    }

    return SecureOk(Mailbox);
}

u32 SecureEnfProcessingInitialize(AttestationMailbox *Mailbox)
{
    if (Mailbox == NULL) {
        return SECURE_SERVICE_ERROR;
    }

    SecureInitResponse(Mailbox);
    SecureEnfDspInitDone = 0U;

    if (secure_enf_init() != SECURE_ENF_STATUS_OK) {
        return SecureFail(Mailbox, 401U);
    }

    SecureEnfDspInitDone = 1U;
    return SecureOk(Mailbox);
}

u32 SecureAttestationBegin(AttestationMailbox *Mailbox)
{
    static const u8 DefaultVerifier[16] = "VERIF_CITYA";
    u32 Index; int VerifierPresent = 0;
    if (Mailbox == NULL) return SECURE_SERVICE_ERROR;
    SecureInitResponse(Mailbox);
    if (Mailbox->RequestMagic != ATTESTATION_REQUEST_MAGIC) return SecureFail(Mailbox, 601U);
    SecureAttestationActive = 0U; SecureAttestationRequestId = Mailbox->RequestId;
    for (Index=0U; Index<16U; Index++) { SecureAttestationNonce[Index]=Mailbox->Nonce[Index]; SecureAttestationVerifierId[Index]=Mailbox->VerifierId[Index]; if(Mailbox->VerifierId[Index]!=0U) VerifierPresent=1; }
    if (!VerifierPresent) memcpy(SecureAttestationVerifierId, DefaultVerifier, 16U);
    memset(SecureAttestationValuesNhz,0,sizeof(SecureAttestationValuesNhz)); SecureAttestationFramesSeen=0U; SecureCaptureFramesSeen=0U; SecureAttestationActive=1U;
    BenchmarkFrameTotalTicks = 0U;
    BenchmarkFrameMinTicks = ~(u64)0;
    BenchmarkFrameMaxTicks = 0U;
    BenchmarkFrameCount = 0U;
    return SecureOk(Mailbox);
}

u32 SecureCaptureSession(AttestationMailbox *Mailbox)
{
    u32 *CurrentBuffer;
    u32 *NextBuffer;
    u32 FrameIndex;
    u32 PollIndex;
    u32 PlStatus;
    u32 CapturedCount;
    u32 ExpectedCount;
    double EnfHz;
    double EnfNanohzDouble;
    XTime FrameStart, FrameEnd;
    u64 FrameTicks;
    int FrameStatus;

    if (Mailbox == NULL) {
        return SECURE_SERVICE_ERROR;
    }

    SecureInitResponse(Mailbox);
    if (SecureCaptureInitDone != 1U) {
        return SecureFail(Mailbox, 602U);
    }
    if (SecureEnfDspInitDone != 1U) {
        return SecureFail(Mailbox, 603U);
    }
    if (SecureAttestationActive != 1U) {
        return SecureFail(Mailbox, 604U);
    }
    if (SecureAttestationFramesSeen != 0U) {
        return SecureFail(Mailbox, 605U);
    }

    CurrentBuffer = (u32 *)(UINTPTR)SECURE_DDR_CAPTURE_BUFFER_A_ADDR;
    Xil_DCacheFlushRange((UINTPTR)CurrentBuffer, SECURE_CAPTURE_FRAME_BYTES);
    Xil_DCacheInvalidateRange(
        (UINTPTR)CurrentBuffer,
        SECURE_CAPTURE_FRAME_BYTES);
    SecureMailboxBarrier();

    PlStatus = XGpio_DiscreteRead(&SecureCaptureGpio, 2);
    if (((PlStatus & PL_STATUS_ERROR_MASK) != 0U) ||
        ((PlStatus & PL_STATUS_BUSY_MASK) != 0U)) {
        return SecureFail(Mailbox, 606U);
    }

    if (XAxiDma_SimpleTransfer(
            &SecureAxiDma,
            (UINTPTR)CurrentBuffer,
            SECURE_CAPTURE_FRAME_BYTES,
            XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS) {
        return SecureFail(Mailbox, 606U);
    }

    /* START is pulsed exactly once for the complete 200-second capture. */
    XGpio_DiscreteWrite(&SecureCaptureGpio, 1, 0x00000001U);
    XGpio_DiscreteWrite(&SecureCaptureGpio, 1, 0x00000000U);

    for (FrameIndex = 0U;
         FrameIndex < ATTESTATION_FRAME_COUNT;
         FrameIndex++) {
        for (PollIndex = 0U;
             PollIndex < SECURE_CAPTURE_POLL_LIMIT;
             PollIndex++) {
            PlStatus = XGpio_DiscreteRead(&SecureCaptureGpio, 2);
            if ((PlStatus & PL_STATUS_ERROR_MASK) != 0U) {
                return SecureFail(Mailbox, 606U);
            }
            if (!XAxiDma_Busy(&SecureAxiDma, XAXIDMA_DEVICE_TO_DMA)) {
                break;
            }
            usleep(100U);
        }
        if (XAxiDma_Busy(&SecureAxiDma, XAXIDMA_DEVICE_TO_DMA)) {
            return SecureFail(Mailbox, 606U);
        }

        PlStatus = XGpio_DiscreteRead(&SecureCaptureGpio, 2);
        CapturedCount =
            (PlStatus >> PL_STATUS_COUNT_SHIFT) &
            PL_STATUS_COUNT_MASK;
        ExpectedCount = (FrameIndex + 1U) * SECURE_CAPTURE_FRAME_SAMPLES;
        if (((PlStatus & PL_STATUS_ERROR_MASK) != 0U) ||
            (CapturedCount < ExpectedCount)) {
            return SecureFail(Mailbox, 606U);
        }
        if ((FrameIndex + 1U == ATTESTATION_FRAME_COUNT) &&
            (((PlStatus & PL_STATUS_DONE_MASK) == 0U) ||
             (CapturedCount != SECURE_CAPTURE_TOTAL_SAMPLES))) {
            return SecureFail(Mailbox, 606U);
        }

        /*
         * Transfer ownership of the alternate Secure-DDR buffer to DMA
         * before the CPU starts ENF processing on the completed buffer.
         */
        if (FrameIndex + 1U < ATTESTATION_FRAME_COUNT) {
            NextBuffer =
                (CurrentBuffer ==
                 (u32 *)(UINTPTR)SECURE_DDR_CAPTURE_BUFFER_A_ADDR)
                    ? (u32 *)(UINTPTR)SECURE_DDR_CAPTURE_BUFFER_B_ADDR
                    : (u32 *)(UINTPTR)SECURE_DDR_CAPTURE_BUFFER_A_ADDR;
            Xil_DCacheFlushRange(
                (UINTPTR)NextBuffer,
                SECURE_CAPTURE_FRAME_BYTES);
            Xil_DCacheInvalidateRange(
                (UINTPTR)NextBuffer,
                SECURE_CAPTURE_FRAME_BYTES);
            SecureMailboxBarrier();
            if (XAxiDma_SimpleTransfer(
                    &SecureAxiDma,
                    (UINTPTR)NextBuffer,
                    SECURE_CAPTURE_FRAME_BYTES,
                    XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS) {
                return SecureFail(Mailbox, 606U);
            }
        }
        else {
            NextBuffer = NULL;
        }

        Xil_DCacheInvalidateRange(
            (UINTPTR)CurrentBuffer,
            SECURE_CAPTURE_FRAME_BYTES);
        SecureMailboxBarrier();

        EnfHz = 0.0;
        XTime_GetTime(&FrameStart);
        FrameStatus = secure_enf_process_frame(
                CurrentBuffer,
                SECURE_CAPTURE_FRAME_SAMPLES,
                &EnfHz);
        XTime_GetTime(&FrameEnd);
        FrameTicks = (u64)(FrameEnd - FrameStart);
        if (FrameStatus == SECURE_ENF_STATUS_OK) {
            BenchmarkFrameTotalTicks += FrameTicks;
            if (FrameTicks < BenchmarkFrameMinTicks) BenchmarkFrameMinTicks = FrameTicks;
            if (FrameTicks > BenchmarkFrameMaxTicks) BenchmarkFrameMaxTicks = FrameTicks;
            BenchmarkFrameCount++;
        }
        if (FrameStatus != SECURE_ENF_STATUS_OK) {
            return SecureFail(Mailbox, 607U);
        }
        EnfNanohzDouble = floor((EnfHz * 1000000000.0) + 0.5);
        if ((!isfinite(EnfHz)) || (EnfHz < 0.0) ||
            (!isfinite(EnfNanohzDouble)) ||
            (EnfNanohzDouble < 0.0)) {
            return SecureFail(Mailbox, 608U);
        }

        SecureAttestationValuesNhz[FrameIndex] = (u64)EnfNanohzDouble;
        SecureAttestationFramesSeen++;
        SecureCaptureFramesSeen++;
        CurrentBuffer = NextBuffer;
    }

    if ((SecureAttestationFramesSeen != ATTESTATION_FRAME_COUNT) ||
        (CapturedCount != SECURE_CAPTURE_TOTAL_SAMPLES)) {
        return SecureFail(Mailbox, 609U);
    }

    return SecureOk(Mailbox);
}
u32 SecureAttestationFinalize(AttestationMailbox *Mailbox)
{
    u64 CryptoTicks = 0U;
    if(Mailbox==NULL)return SECURE_SERVICE_ERROR; SecureInitResponse(Mailbox); SecureClearOutputs(Mailbox); if(SecureAttestationActive!=1U)return SecureFail(Mailbox,604U); if(SecureAttestationFramesSeen!=25U)return SecureFail(Mailbox,609U);
    if(SecureBuildAndSignEnfEvidence(SecureAttestationRequestId,SecureAttestationNonce,SecureAttestationVerifierId,SecureAttestationValuesNhz,Mailbox->Message,Mailbox->Signature,&CryptoTicks)!=XST_SUCCESS)return SecureFail(Mailbox,610U);
    Mailbox->BenchmarkTimerHz = (u64)COUNTS_PER_SECOND;
    Mailbox->BenchmarkFrameCount = (u32)BenchmarkFrameCount;
    Mailbox->BenchmarkReserved = 0U;
    Mailbox->BenchmarkFrameTotalTicks = BenchmarkFrameTotalTicks;
    Mailbox->BenchmarkFrameMinTicks = BenchmarkFrameMinTicks;
    Mailbox->BenchmarkFrameMaxTicks = BenchmarkFrameMaxTicks;
    Mailbox->BenchmarkCryptoTicks = CryptoTicks;
    Mailbox->MessageLength=ATTESTATION_EVIDENCE_BYTES; Mailbox->SignatureLength=ATTESTATION_SIGNATURE_BYTES; SecureAttestationActive=0U; return SecureOk(Mailbox);
}
