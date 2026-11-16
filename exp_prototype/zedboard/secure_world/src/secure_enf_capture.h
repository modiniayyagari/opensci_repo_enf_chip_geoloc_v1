/* Active Secure services. */
#ifndef SECURE_ENF_CAPTURE_H
#define SECURE_ENF_CAPTURE_H
#include "attestation_smc_abi.h"
u32 SecureCaptureInitialize(AttestationMailbox*);u32 SecureDdrSelfTest(AttestationMailbox*);u32 SecureEnfProcessingInitialize(AttestationMailbox*);u32 SecureAttestationBegin(AttestationMailbox*);u32 SecureCaptureSession(AttestationMailbox*);u32 SecureAttestationFinalize(AttestationMailbox*);
#endif
