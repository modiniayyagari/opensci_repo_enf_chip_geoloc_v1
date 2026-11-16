/* Dispatches the active SMC ABI only. */
#include "secure_service_dispatch.h"
#include "secure_enf_capture.h"
#include "attestation_smc_abi.h"
u32 secure_service_dispatch(u32 id)
{
 AttestationMailbox *mailbox=(AttestationMailbox *)(UINTPTR)ATTESTATION_MAILBOX_ADDRESS;
 switch(id){
 case SECURE_SERVICE_CAPTURE_INITIALIZE:return SecureCaptureInitialize(mailbox);
 case SECURE_SERVICE_DDR_SELF_TEST:return SecureDdrSelfTest(mailbox);
 case SECURE_SERVICE_ENF_PROCESSING_INITIALIZE:return SecureEnfProcessingInitialize(mailbox);
 case SECURE_SERVICE_ATTESTATION_BEGIN:return SecureAttestationBegin(mailbox);
 case SECURE_SERVICE_CAPTURE_SESSION:return SecureCaptureSession(mailbox);
 case SECURE_SERVICE_ATTESTATION_FINALIZE:return SecureAttestationFinalize(mailbox);
 default:return SECURE_SERVICE_ERROR;
 }
}
