/* Configures TrustZone protection before entering Normal World. */
#include "secure_platform_init.h"
#include "xil_io.h"
#define SLCR_LOCK 0xF8000004U
#define SLCR_UNLOCK 0xF8000008U
#define UNLOCK_KEY 0x0000DF0DU
#define LOCK_KEY 0x0000767BU
#define DDR_SECURITY 0xF8000430U
#define OCM_SECURITY0 0xF8000400U
#define OCM_SECURITY1 0xF8000404U
#define APB_SECURITY6 0xE0200018U
int SecurePlatformConfigure(void){u32 value;Xil_Out32(OCM_SECURITY0,0U);Xil_Out32(OCM_SECURITY1,0U);if(Xil_In32(OCM_SECURITY0)||Xil_In32(OCM_SECURITY1))return -1;Xil_Out32(SLCR_UNLOCK,UNLOCK_KEY);value=Xil_In32(DDR_SECURITY);value|=1U;value&=~(1U<<7);Xil_Out32(DDR_SECURITY,value);value=Xil_In32(DDR_SECURITY);Xil_Out32(SLCR_LOCK,LOCK_KEY);if(!(value&1U)||(value&(1U<<7)))return -1;Xil_Out32(APB_SECURITY6,1U<<7);return 0;}
