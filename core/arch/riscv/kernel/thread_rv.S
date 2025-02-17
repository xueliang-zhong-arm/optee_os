/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Copyright 2022-2023 NXP
 */

#include <asm.S>
#include <generated/asm-defines.h>
#include <keep.h>
#include <kernel/thread.h>
#include <kernel/thread_private.h>
#include <mm/core_mmu.h>
#include <riscv.h>
#include <riscv_macros.S>

.macro get_thread_ctx res, tmp0
	lw	\tmp0, THREAD_CORE_LOCAL_CURR_THREAD(tp)
	la	\res, threads
1:
	beqz	\tmp0, 2f
	addi	\res, \res, THREAD_CTX_SIZE
	addi	\tmp0, \tmp0, -1
	bnez	\tmp0, 1b
2:
.endm

.macro save_regs, mode
	addi	sp, sp, -THREAD_TRAP_REGS_SIZE
.if \mode == TRAP_MODE_USER

	/* Save user thread pointer and load kernel thread pointer */
	store_xregs sp, THREAD_TRAP_REG_TP, REG_TP
	addi	tp, sp, THREAD_TRAP_REGS_SIZE
	/* Now tp is at struct thread_user_mode_rec, which has kernel tp */
	load_xregs tp, THREAD_USER_MODE_REC_X4, REG_TP

	store_xregs sp, THREAD_TRAP_REG_GP, REG_GP

	/*
	 * Set the scratch register to 0 such in case of a recursive
	 * exception thread_trap_vect() knows that it is emitted from kernel.
	 */
	csrrw	gp, CSR_XSCRATCH, zero
	store_xregs sp, THREAD_TRAP_REG_SP, REG_GP
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
.endif
	store_xregs sp, THREAD_TRAP_REG_T3, REG_T3, REG_T6
	store_xregs sp, THREAD_TRAP_REG_T0, REG_T0, REG_T2
	store_xregs sp, THREAD_TRAP_REG_A0, REG_A0, REG_A7
	store_xregs sp, THREAD_TRAP_REG_RA, REG_RA
#if defined(CFG_UNWIND)
	/* To unwind stack we need s0, which is frame pointer. */
	store_xregs sp, THREAD_TRAP_REG_S0, REG_S0
#endif

	csrr	t0, CSR_XSTATUS
	store_xregs sp, THREAD_TRAP_REG_STATUS, REG_T0

	csrr	a0, CSR_XCAUSE
	csrr	a1, CSR_XEPC

	store_xregs sp, THREAD_TRAP_REG_EPC, REG_A1

	mv	a2, sp

	/* a0 = cause
	 * a1 = epc
	 * a2 = sp
	 * a3 = user
	 * thread_trap_handler(cause, epc, sp, user)
	 */
.endm

.macro restore_regs, mode
	load_xregs sp, THREAD_TRAP_REG_EPC, REG_T0
	csrw	CSR_XEPC, t0

	load_xregs sp, THREAD_TRAP_REG_STATUS, REG_T0
	csrw	CSR_XSTATUS, t0

	load_xregs sp, THREAD_TRAP_REG_RA, REG_RA
	load_xregs sp, THREAD_TRAP_REG_A0, REG_A0, REG_A7
	load_xregs sp, THREAD_TRAP_REG_T0, REG_T0, REG_T2
	load_xregs sp, THREAD_TRAP_REG_T3, REG_T3, REG_T6
#if defined(CFG_UNWIND)
	/* To unwind stack we need s0, which is frame pointer. */
	load_xregs sp, THREAD_TRAP_REG_S0, REG_S0
#endif

.if \mode == TRAP_MODE_USER
	addi	gp, sp, THREAD_TRAP_REGS_SIZE
	csrw	CSR_XSCRATCH, gp

	load_xregs sp, THREAD_TRAP_REG_TP, REG_TP
	load_xregs sp, THREAD_TRAP_REG_GP, REG_GP
	load_xregs sp, THREAD_TRAP_REG_SP, REG_SP

.else
	addi	sp, sp, THREAD_TRAP_REGS_SIZE
.endif
.endm

/* size_t __get_core_pos(void); */
FUNC __get_core_pos , : , .identity_map
	lw	a0, THREAD_CORE_LOCAL_HART_ID(tp)
	ret
END_FUNC __get_core_pos

FUNC thread_trap_vect , :
	csrrw	sp, CSR_XSCRATCH, sp
	bnez	sp, 0f
	csrrw	sp, CSR_XSCRATCH, sp
	j	trap_from_kernel
0:
	j	trap_from_user
thread_trap_vect_end:
END_FUNC thread_trap_vect

LOCAL_FUNC trap_from_kernel, :
	save_regs TRAP_MODE_KERNEL
	li	a3, 0
	jal	thread_trap_handler
	restore_regs TRAP_MODE_KERNEL
	XRET
END_FUNC trap_from_kernel

LOCAL_FUNC trap_from_user, :
	save_regs TRAP_MODE_USER
	li	a3, 1
	jal	thread_trap_handler
	restore_regs TRAP_MODE_USER
	XRET
END_FUNC trap_from_user

/*
 * void thread_unwind_user_mode(uint32_t ret, uint32_t exit_status0,
 * 		uint32_t exit_status1);
 * See description in thread.h
 */
FUNC thread_unwind_user_mode , :

	/* Store the exit status */
	load_xregs sp, THREAD_USER_MODE_REC_CTX_REGS_PTR, REG_A3, REG_A5
	sw	a1, (a4)
	sw	a2, (a5)

	/* Save user callee regs */
	store_xregs a3, THREAD_CTX_REG_S0, REG_S0, REG_S1
	store_xregs a3, THREAD_CTX_REG_S2, REG_S2, REG_S11
	store_xregs a3, THREAD_CTX_REG_SP, REG_SP, REG_TP

	/* Restore kernel callee regs */
	mv	a1, sp

	load_xregs a1, THREAD_USER_MODE_REC_X1, REG_RA, REG_TP
	load_xregs a1, THREAD_USER_MODE_REC_X8, REG_S0, REG_S1
	load_xregs a1, THREAD_USER_MODE_REC_X18, REG_S2, REG_S11

	add	sp, sp, THREAD_USER_MODE_REC_SIZE

	/*
	 * Zeroize xSCRATCH to indicate to thread_trap_vect()
	 * that we are executing in kernel.
	 */
	csrw	CSR_XSCRATCH, zero

	/* Return from the call of thread_enter_user_mode() */
	ret
END_FUNC thread_unwind_user_mode

/*
 * void thread_exit_user_mode(unsigned long a0, unsigned long a1,
 *			       unsigned long a2, unsigned long a3,
 *			       unsigned long sp, unsigned long pc,
 *			       unsigned long status);
 */
FUNC thread_exit_user_mode , :
	/* Set kernel stack pointer */
	mv	sp, a4

	/* Set xSTATUS */
	csrw	CSR_XSTATUS, a6

	/* Set return address thread_unwind_user_mode() */
	mv	ra, a5
	ret
END_FUNC thread_exit_user_mode

/*
 * uint32_t __thread_enter_user_mode(struct thread_ctx_regs *regs,
 *				     uint32_t *exit_status0,
 *				     uint32_t *exit_status1);
 */
FUNC __thread_enter_user_mode , :
	/*
	 * Create and fill in the struct thread_user_mode_rec
	 */
	addi	sp, sp, -THREAD_USER_MODE_REC_SIZE
	store_xregs sp, THREAD_USER_MODE_REC_CTX_REGS_PTR, REG_A0, REG_A2
	store_xregs sp, THREAD_USER_MODE_REC_X1, REG_RA, REG_TP
	store_xregs sp, THREAD_USER_MODE_REC_X8, REG_S0, REG_S1
	store_xregs sp, THREAD_USER_MODE_REC_X18, REG_S2, REG_S11

	/*
	 * Save the kernel stack pointer in the thread context
	 */

	/* Get pointer to current thread context */
	get_thread_ctx s0, s1

	/*
	 * Save kernel stack pointer to ensure that
	 * thread_exit_user_mode() uses correct stack pointer.
	 */

	store_xregs s0, THREAD_CTX_KERN_SP, REG_SP
	/*
	 * Save kernel stack pointer in xSCRATCH to ensure that
	 * thread_trap_vect() uses correct stack pointer.
	 */
	csrw	CSR_XSCRATCH, sp

	/* Set user status */
	load_xregs a0, THREAD_CTX_REG_STATUS, REG_S0
	csrw	CSR_XSTATUS, s0

	/*
	 * Save the values for a1 and a2 in struct thread_core_local to be
	 * restored later just before the xRET.
	 */
	store_xregs tp, THREAD_CORE_LOCAL_X10, REG_A1, REG_A2

	/* Load the rest of the general purpose registers */
	load_xregs a0, THREAD_CTX_REG_RA, REG_RA, REG_TP
	load_xregs a0, THREAD_CTX_REG_T0, REG_T0, REG_T2
	load_xregs a0, THREAD_CTX_REG_S0, REG_S0, REG_S1
	load_xregs a0, THREAD_CTX_REG_S2, REG_S2, REG_S11
	load_xregs a0, THREAD_CTX_REG_T3, REG_T3, REG_T6
	load_xregs a0, THREAD_CTX_REG_A0, REG_A0, REG_A7

	/* Set exception program counter */
	csrw		CSR_XEPC, ra

	/* Jump into user mode */
	XRET
END_FUNC __thread_enter_user_mode

/*
 * Implement based on the transport method used to communicate between
 * untrusted domain and trusted domain. It could be an SBI/ECALL-based to
 * a security monitor running in M-Mode and panic or messaging-based across
 * domains where we return to a messaging callback which parses and handles
 * messages.
 */
LOCAL_FUNC thread_return_from_nsec_call , :
	/* Implement */
	j	.
END_FUNC thread_return_from_nsec_call


FUNC thread_std_smc_entry , :
	jal	__thread_std_smc_entry

	/* Save return value */
	mv	s0, a0

	/* Disable all interrupts */
	csrc	CSR_XSTATUS, CSR_XSTATUS_IE

	/* Switch to temporary stack */
	jal	thread_get_tmp_sp
	mv	sp, a0

	/*
	 * We are returning from thread_alloc_and_run()
	 * set thread state as free
	 */
	jal	thread_state_free

	/* Restore __thread_std_smc_entry() return value */
	mv	a1, s0
	li	a2, 0
	li	a3, 0
	li	a4, 0
	li	a0, TEESMC_OPTEED_RETURN_CALL_DONE

	/* Return to untrusted domain */
	jal	thread_return_from_nsec_call
END_FUNC thread_std_smc_entry

/* void thread_resume(struct thread_ctx_regs *regs) */
FUNC thread_resume , :
	/*
	 * Restore all registers assuming that GP
	 * and TP were not changed.
	 */
	load_xregs a0, THREAD_CTX_REG_RA, REG_RA, REG_SP
	load_xregs a0, THREAD_CTX_REG_T0, REG_T0, REG_T2
	load_xregs a0, THREAD_CTX_REG_S0, REG_S0, REG_S1
	load_xregs a0, THREAD_CTX_REG_S2, REG_S2, REG_S11
	load_xregs a0, THREAD_CTX_REG_T3, REG_T3, REG_T6
	load_xregs a0, THREAD_CTX_REG_A0, REG_A0, REG_A7
	store_xregs tp, THREAD_CORE_LOCAL_X10, REG_A0, REG_A1
	ret
END_FUNC thread_resume

/* void thread_rpc(uint32_t rv[THREAD_RPC_NUM_ARGS]) */
FUNC thread_rpc , :
	 /* Use stack for temporary storage */
	addi	sp, sp, -REGOFF(4)

	/* Read xSTATUS */
	csrr	a1, CSR_XSTATUS

	/* Mask all maskable exceptions before switching to temporary stack */
	csrc	CSR_XSTATUS, CSR_XSTATUS_IE

	/* Save return address xSTATUS and pointer to rv */
	STR	a0, REGOFF(0)(sp)
	STR	a1, REGOFF(1)(sp)
	STR	s0, REGOFF(2)(sp)
	STR	ra, REGOFF(3)(sp)
	addi	s0, sp, REGOFF(4)

	/* Save thread state */
	jal	thread_get_ctx_regs
	store_xregs a0, THREAD_CTX_REG_SP, REG_SP
	store_xregs a0, THREAD_CTX_REG_S0, REG_S0, REG_S1
	store_xregs a0, THREAD_CTX_REG_S2, REG_S2, REG_S11

	/* Get to tmp stack */
	jal	thread_get_tmp_sp

	/* Get pointer to rv */
	LDR	s1, REGOFF(0)(sp)

	/* xSTATUS to restore */
	LDR	a1, REGOFF(1)(sp)
	/* Switch to tmp stack */
	mv	sp, a0

	/* Early load rv[] into s2-s4 */
	lw	s2, 0(s1)
	lw	s3, 4(s1)
	lw	s4, 8(s1)

	li	a0, THREAD_FLAGS_COPY_ARGS_ON_RETURN
	la	a2, .thread_rpc_return
	jal	thread_state_suspend

	mv	a4, a0	/* thread index */
	mv	a1, s2	/* rv[0] */
	mv	a2, s3	/* rv[1] */
	mv	a3, s4	/* rv[2] */
	li	a0, TEESMC_OPTEED_RETURN_CALL_DONE

	/* Return to untrusted domain */
	jal	thread_return_from_nsec_call
.thread_rpc_return:
	/*
	 * Jumps here from thread_resume() above when RPC has returned.
	 * At this point has the stack pointer been restored to the value
	 * stored in THREAD_CTX above.
	 */

	/* Get pointer to rv[] */
	LDR	a4, REGOFF(0)(sp)

	/* Store a0-a3 into rv[] */
	sw	a0, 0(a4)
	sw	a1, 4(a4)
	sw	a2, 8(a4)
	sw	a3, 12(a4)

	/* Pop saved XSTATUS from stack */
	LDR	s0, REGOFF(1)(sp)
	csrw	CSR_XSTATUS, s0

	/* Pop return address and s0 from stack */
	LDR	ra, REGOFF(3)(sp)
	LDR	s0, REGOFF(2)(sp)

	addi	sp, sp, REGOFF(4)
	ret
END_FUNC thread_rpc
