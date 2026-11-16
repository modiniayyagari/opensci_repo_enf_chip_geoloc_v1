/* Serializes and signs canonical board ENF evidence. */
#include "secure_enf_evidence.h"
#include "attestation_smc_abi.h"
#define BOARD_EVIDENCE_DOMAIN "ENF_BOARD_EVIDENCE"
#define BOARD_EVIDENCE_DOMAIN_BYTES 18U
#define BOARD_EVIDENCE_VERSION 1U
#include "sha256.h"
#include "secure_attestation_key.h"
#include "uECC.h"
#include "xstatus.h"
#include "xiltimer.h"
#include <stddef.h>
#include <string.h>

typedef struct { uECC_HashContext Uecc; sha256_context Sha; u8 Tmp[128]; } SecureEnfHash;
static void HashInit(const uECC_HashContext *Base){ sha256_init(&((SecureEnfHash *)(void *)Base)->Sha); }
static void HashUpdate(const uECC_HashContext *Base,const u8 *Message,unsigned Size){ sha256_hash(&((SecureEnfHash *)(void *)Base)->Sha,Message,(size_t)Size); }
static void HashFinish(const uECC_HashContext *Base,u8 *Result){ sha256_done(&((SecureEnfHash *)(void *)Base)->Sha,Result); }
static void HashContextInit(SecureEnfHash *Context){ memset(Context,0,sizeof(*Context)); Context->Uecc.init_hash=HashInit; Context->Uecc.update_hash=HashUpdate; Context->Uecc.finish_hash=HashFinish; Context->Uecc.block_size=64U; Context->Uecc.result_size=32U; Context->Uecc.tmp=Context->Tmp; }
static void PutU16Be(u8 *p,u16 v){p[0]=(u8)(v>>8);p[1]=(u8)v;}
static void PutU32Be(u8 *p,u32 v){p[0]=(u8)(v>>24);p[1]=(u8)(v>>16);p[2]=(u8)(v>>8);p[3]=(u8)v;}
static void PutU64Be(u8 *p,u64 v){u32 i;for(i=0U;i<8U;i++){p[i]=(u8)(v>>(56U-(i*8U)));}}
int SecureBuildAndSignEnfEvidence(u32 RequestId,const u8 Nonce[16],const u8 VerifierId[16],const u64 EnfValuesNhz[25],u8 Message[288],u8 Signature[64],u64 *CryptoTicksOut)
{
    static const u8 BoardId[16]="ZB_CITYA"; SecureEnfHash UeccHash; sha256_context Hash; u8 Digest[32]; uECC_Curve Curve; u32 i; int Status;
    XTime CryptoStart, CryptoEnd;
    if (CryptoTicksOut != NULL) *CryptoTicksOut = 0U;
    if(!Nonce||!VerifierId||!EnfValuesNhz||!Message||!Signature)return XST_FAILURE;
    memset(Message,0,ATTESTATION_EVIDENCE_BYTES); memcpy(Message,BOARD_EVIDENCE_DOMAIN,BOARD_EVIDENCE_DOMAIN_BYTES); PutU16Be(&Message[18],BOARD_EVIDENCE_VERSION); PutU32Be(&Message[20],RequestId); memcpy(&Message[24],Nonce,16U); memcpy(&Message[40],BoardId,16U); memcpy(&Message[56],VerifierId,16U); PutU32Be(&Message[72],2000U); PutU32Be(&Message[76],200U); PutU16Be(&Message[80],25U); PutU16Be(&Message[82],0U); PutU32Be(&Message[84],1000000000U);
    for(i=0U;i<25U;i++)PutU64Be(&Message[88U+i*8U],EnfValuesNhz[i]);
    /* Measure hashing and signing after canonical serialization is complete. */
    XTime_GetTime(&CryptoStart);
    sha256_init(&Hash); sha256_hash(&Hash,Message,ATTESTATION_EVIDENCE_BYTES); sha256_done(&Hash,Digest); Curve=uECC_secp256r1(); if(!Curve){memset(Digest,0,sizeof(Digest));return XST_FAILURE;} HashContextInit(&UeccHash); Status=uECC_sign_deterministic(SecureAttestationPrivateKey,Digest,sizeof(Digest),&UeccHash.Uecc,Signature,Curve);
    XTime_GetTime(&CryptoEnd);
    if ((Status == 1) && (CryptoTicksOut != NULL))
        *CryptoTicksOut = (u64)(CryptoEnd - CryptoStart);
    memset(Digest,0,sizeof(Digest)); memset(&UeccHash,0,sizeof(UeccHash)); return Status==1?XST_SUCCESS:XST_FAILURE;
}
