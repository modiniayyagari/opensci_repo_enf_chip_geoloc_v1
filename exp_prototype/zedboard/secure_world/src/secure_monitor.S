/* Secure Monitor vectors and world-switch implementation. */
/*
 * Cortex-A9 TrustZone Secure Monitor bring-up support.
 *
 * Secure and Normal World still execute on Cortex-A9 CPU0, with Monitor
 * mode as the SMC gateway. The C dispatcher runs in Secure Monitor mode
 * on a dedicated protected stack for the bare-metal attestation service.
 */

    .syntax unified
    .arch armv7-a
    .arch_extension sec
    .arm

    .extern secure_service_dispatch

/* Dedicated 16-KiB Secure Monitor-mode stack. */
    .section .bss, "aw", %nobits
    .balign 8
    .global secure_monitor_stack_bottom
secure_monitor_stack_bottom:
    .space 16384
    .global secure_monitor_stack_top
secure_monitor_stack_top:

    .text

/*
 * MVBAR requires the Monitor vector table base to be 32-byte aligned.
 * Keep the eight vector instructions together at the start of a dedicated
 * executable section.
 */
    .section .monitor_vectors, "ax", %progbits
    .balign 32
    .global secure_monitor_vectors
    .type   secure_monitor_vectors, %object
secure_monitor_vectors:
    b       .Lunused_vector       /* +0x00: unused */
    b       .Lunused_vector       /* +0x04: unused */
    b       secure_smc_handler        /* +0x08: SMC */
    b       .Lunused_vector       /* +0x0c: unused */
    b       .Lunused_vector       /* +0x10: unused */
    b       .Lunused_vector       /* +0x14: unused */
    b       .Lunused_vector       /* +0x18: unused */
    b       .Lunused_vector       /* +0x1c: unused */
    .size   secure_monitor_vectors, . - secure_monitor_vectors

.Lunused_vector:
    b       .Lunused_vector

    .text
    .balign 4

/* void secure_monitor_init(void); */
    .global secure_monitor_init
    .type   secure_monitor_init, %function
secure_monitor_init:
    ldr     r0, =secure_monitor_vectors
    mcr     p15, 0, r0, c12, c0, 1   /* MVBAR = vector table address */
    dsb     sy
    isb
    bx      lr
    .size   secure_monitor_init, . - secure_monitor_init

/*
 * void secure_enter_normal_world(uint32_t entry_address, uint32_t vector_base);
 *
 * r0 = stable Normal-world fixed entry at 0x00120000
 * r1 = Normal-world vector-table base at 0x00100000
 *
 * The fixed entry branches to the link-resolved Xilinx _start address, so
 * the Secure handoff no longer depends on the Normal ELF layout.
 */
    .balign 4
    .global secure_enter_normal_world
    .type   secure_enter_normal_world, %function
secure_enter_normal_world:
    smc     #0
.Lunexpected_smc_return:
    b       .Lunexpected_smc_return
    .size   secure_enter_normal_world, . - secure_enter_normal_world

    .balign 4
    .type   secure_smc_handler, %function
secure_smc_handler:
    /*
     * Determine which world issued the SMC.
     *
     * SCR.NS == 0:
     *     initial Secure -> Normal handoff
     *
     * SCR.NS == 1:
     *     service request from Normal World
     */
    mrc     p15, 0, r12, c1, c1, 0   /* Read SCR */
    tst     r12, #1
    bne     .Lnormal_world_smc


    /*
     * ========================================================
     * Initial Secure -> Normal handoff
     * ========================================================
     *
     * r0 = Normal execution entry
     * r1 = Normal vector-table base
     */

    /*
     * Initialize the banked Monitor stack before its first use.
     * It remains SP_mon for later Normal-originated SMC calls.
     */
    ldr     sp, =secure_monitor_stack_top

    /*
     * Preserve vector base.
     */
    mov     r3, r1

    /*
     * Permit Normal VFP/NEON access.
     */
    mrc     p15, 0, r2, c1, c1, 2
    orr     r2, r2, #0xC00
    mcr     p15, 0, r2, c1, c1, 2
    isb

    /*
     * Select Normal world and allow later SMC calls
     * from the Normal state.
     */
    orr     r12, r12, #1             /* SCR.NS = 1 */
    bic     r12, r12, #(1 << 7)      /* SCR.SCD = 0 */
    mcr     p15, 0, r12, c1, c1, 0
    isb

    /*
     * Initialize Normal CP15 state.
     */
    mov     r2, #0
    mcr     p15, 0, r2, c1, c0, 0   /* SCTLR(NS) = 0 */

    mcr     p15, 0, r3, c12, c0, 0  /* VBAR(NS) */

    dsb     sy
    isb

    /*
     * Enter Normal SVC mode, ARM state,
     * IRQ/FIQ masked.
     */
    mov     r1, #0xd3
    msr     spsr_cxsf, r1

    mov     lr, r0
    movs    pc, lr


    /*
     * ========================================================
     * Normal-world secure-service request
     * ========================================================
     *
     * On entry:
     *
     * r0 = service ID
     *
     * LR_mon and SPSR_mon already contain the state needed
     * to return to the instruction after the Normal-world SMC.
     *
     * Do not alter SCR.NS here.
     * Do not change SPSR_mon.
     * Do not change LR_mon.
     */

.Lnormal_world_smc:
    /*
     * r0 is intentionally not saved:
     * input  = service ID
     * output = service return value
     *
     * Save the interrupted Normal-world r1-r12 and LR_mon.
     * SPSR_mon and SCR.NS are left unchanged.
     */
    stmdb   sp!, {r1-r12, lr}

    /*
     * Thirteen registers consume 52 bytes. Add four bytes so
     * SP is 8-byte aligned at the AAPCS C call boundary.
     */
    sub     sp, sp, #4

    bl      secure_service_dispatch

    add     sp, sp, #4
    ldmia   sp!, {r1-r12, lr}

    /* Return to the instruction following the Normal SMC. */
    movs    pc, lr

    .size   secure_smc_handler, . - secure_smc_handler

/* uint32_t secure_read_scr(void); */
    .balign 4
    .global secure_read_scr
    .type   secure_read_scr, %function
secure_read_scr:
    mrc     p15, 0, r0, c1, c1, 0
    bx      lr
    .size   secure_read_scr, . - secure_read_scr

/* uint32_t secure_read_cpsr(void); */
    .balign 4
    .global secure_read_cpsr
    .type   secure_read_cpsr, %function
secure_read_cpsr:
    mrs     r0, cpsr
    bx      lr
    .size   secure_read_cpsr, . - secure_read_cpsr

    .section .note.GNU-stack, "", %progbits
