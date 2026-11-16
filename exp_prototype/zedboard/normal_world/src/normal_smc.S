    .syntax unified
    .arch armv7-a
    .arch_extension sec
    .arm
    .section .normal_world_entry, "ax", %progbits
    .balign 4
    .extern _start
    .global normal_world_fixed_entry
    .type normal_world_fixed_entry, %function
normal_world_fixed_entry:
    /* Secure World uses this fixed address while the Xilinx start may move. */
    b _start
    .size normal_world_fixed_entry, . - normal_world_fixed_entry
    .text
    .balign 4
    .global normal_smc_call
    .type normal_smc_call, %function
normal_smc_call:
    /* r0 carries both the service ID and the service return value. */
    smc #0
    bx lr
    .size normal_smc_call, . - normal_smc_call
    .section .note.GNU-stack, "", %progbits
