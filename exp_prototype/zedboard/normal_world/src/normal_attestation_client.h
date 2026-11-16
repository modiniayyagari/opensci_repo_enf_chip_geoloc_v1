#ifndef NORMAL_ATTESTATION_CLIENT_H
#define NORMAL_ATTESTATION_CLIENT_H
#include "attestation_smc_abi.h"
int NormalAttestationInitialize(void);
void NormalAttestationClearPending(void);
void NormalAttestationStoreChallenge(u32 request_id, const u8 nonce[16], const u8 verifier_id[16]);
int NormalAttestationRequestMatches(u32 request_id);
int NormalAttestationRunPending(u32 *error_code);
#endif
