/* Secure boot entry and handoff to the fixed Normal World entry. */
#include "secure_platform_init.h"
#include "secure_attestation_key.h"
#include "xil_printf.h"
#define NORMAL_WORLD_VECTOR_BASE 0x00100000U
#define NORMAL_WORLD_FIXED_ENTRY 0x00120000U
#define SECURE_KEY_ADDRESS 0x00020000U
extern void secure_monitor_init(void);
extern void secure_enter_normal_world(u32,u32);
extern u32 secure_read_scr(void);
int main(void){if((secure_read_scr()&1U)!=0U){xil_printf("[SECURE] ERROR: CPU not in Secure state\r\n");for(;;){}}secure_monitor_init();if(SecurePlatformConfigure()!=0){xil_printf("[SECURE] ERROR: TrustZone setup failed\r\n");for(;;){}}xil_printf("[SECURE] key page = 0x%08x\r\n",(unsigned)SECURE_KEY_ADDRESS);xil_printf("[SECURE] Entering Normal World at 0x%08x\r\n",(unsigned)NORMAL_WORLD_FIXED_ENTRY);secure_enter_normal_world(NORMAL_WORLD_FIXED_ENTRY,NORMAL_WORLD_VECTOR_BASE);for(;;){}return 0;}
