/* Canonical evidence signing interface. */
#ifndef SECURE_ENF_EVIDENCE_H
#define SECURE_ENF_EVIDENCE_H
#include "xil_types.h"
int SecureBuildAndSignEnfEvidence(u32,const u8[16],const u8[16],const u64[25],u8[288],u8[64],u64 *CryptoTicksOut);
#endif
