/*
 * arch/arm/mach-tegra/sleep.S
 *
 * Copyright (c) 2010-2011, NVIDIA Corporation.
 * Copyright (c) 2011, Google, Inc.
 *
 * Author: Colin Cross <ccross@android.com>
 *         Gary King <gking@nvidia.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

#include <linux/const.h>
#include <linux/init.h>
#include <linux/linkage.h>

#include <asm/assembler.h>
#include <asm/cache.h>
#include <asm/domain.h>
#include <asm/memory.h>
#include <asm/page.h>
#include <asm/ptrace.h>
#include <asm/asm-offsets.h>
#include <asm/glue-cache.h>
#include <asm/glue-proc.h>
#include <asm/system.h>

#include <mach/iomap.h>
#include <mach/io.h>

#include "asm_macros.h"
#include "sleep.h"

#define CLK_RESET_CCLK_BURST		0x20
#define CLK_RESET_CCLK_DIVIDER		0x24

#define TEGRA_PMC_VIRT		(TEGRA_PMC_BASE - IO_APB_PHYS + IO_APB_VIRT)
#define TEGRA_CLK_RESET_VIRT	(TEGRA_CLK_RESET_BASE - IO_PPSB_PHYS + IO_PPSB_VIRT)

/*
 * ARM security extensions are required when compiling TRUSTED_FOUNDATIONS code,
 * and this explicit arch_extension line fixes the build on compilers where the
 * as-instr Makefile function fails. The Android cross-compiler is an example.
 */
#ifdef CONFIG_TRUSTED_FOUNDATIONS
.arch_extension sec
#endif

/*
 * tegra_pen_lock
 *
 * spinlock implementation with no atomic test-and-set and no coherence
 * using Peterson's algorithm on strongly-ordered registers
 * used to synchronize a cpu waking up from wfi with entering lp2 on idle
 *
 * SCRATCH37 = r1 = !turn (inverted from Peterson's algorithm)
 * on cpu 0:
 * SCRATCH38 = r2 = flag[0]
 * SCRATCH39 = r3 = flag[1]
 * on cpu1:
 * SCRATCH39 = r2 = flag[1]
 * SCRATCH38 = r3 = flag[0]
 *
 * must be called with MMU on
 * corrupts r0-r3, r12
 */
ENTRY(tegra_pen_lock)
	mov32	r3, TEGRA_PMC_VIRT
	cpu_id	r0
	add	r1, r3, #PMC_SCRATCH37
	cmp	r0, #0
	addeq	r2, r3, #PMC_SCRATCH38
	addeq	r3, r3, #PMC_SCRATCH39
	addne	r2, r3, #PMC_SCRATCH39
	addne	r3, r3, #PMC_SCRATCH38

	mov	r12, #1
	str	r12, [r2]		@ flag[cpu] = 1
	dsb
	str	r12, [r1]		@ !turn = cpu
1:	dsb
	ldr	r12, [r3]
	cmp	r12, #1			@ flag[!cpu] == 1?
	ldreq	r12, [r1]
	cmpeq	r12, r0			@ !turn == cpu?
	beq	1b			@ while !turn == cpu && flag[!cpu] == 1

	mov	pc, lr			@ locked
ENDPROC(tegra_pen_lock)

ENTRY(tegra_pen_unlock)
	dsb
	mov32	r3, TEGRA_PMC_VIRT
	cpu_id	r0
	cmp	r0, #0
	addeq	r2, r3, #PMC_SCRATCH38
	addne	r2, r3, #PMC_SCRATCH39
	mov	r12, #0
	str	r12, [r2]
	mov	pc, lr
ENDPROC(tegra_pen_unlock)

/*
 * tegra_cpu_wfi
 *
 * puts current CPU in wfi
 * CPU core clock-gates itself during wfi
 *
 * corrupts r0-r3
 * must be called with MMU on
 */
ENTRY(tegra_cpu_wfi)
	dsb
	wfi
	mov	pc, lr
ENDPROC(tegra_cpu_wfi)

/*
 * tegra_cpu_exit_coherency
 *
 * Exits SMP coherency.
 * corrupts r4-r5
 */
ENTRY(tegra_cpu_exit_coherency)
	exit_smp r4, r5
	mov	pc, lr
ENDPROC(tegra_cpu_exit_coherency)

#ifdef CONFIG_PM_SLEEP
/*
 * tegra_sleep_cpu_finish(unsigned long int)
 *
 * enters suspend in LP2 by turning off the mmu and jumping to
 * tegra?_tear_down_cpu
 */
ENTRY(tegra_sleep_cpu_finish)
	bl	tegra_cpu_exit_coherency

#ifdef CONFIG_ARCH_TEGRA_2x_SOC
	mov32	r1, tegra2_tear_down_cpu
#else
	mov32	r1, tegra3_tear_down_cpu
#endif
	add	r1, r1, r0
	b	tegra_turn_off_mmu
ENDPROC(tegra_sleep_cpu_finish)

/*
 * tegra_turn_off_mmu
 *
 * r0 = v2p
 * r1 = physical address to jump to with mmu off
 */
ENTRY(tegra_turn_off_mmu)
	/*
	 * change page table pointer to tegra_pgd_phys, so that IRAM
	 * and MMU shut-off will be mapped virtual == physical
	 */
	mrc	p15, 0, r2, c2, c0, 0	@ TTB 0
	mov32	r3, ~PAGE_MASK
	and	r2, r2, r3
	ldr	r3, tegra_pgd_phys_address
	ldr	r3, [r3]
	orr	r3, r3, r2
	mov	r2, #0
	mcr	p15, 0, r2, c13, c0, 1	@ reserved context
	isb
	mcr	p15, 0, r3, c2, c0, 0	@ TTB 0
	isb

	mov	r2, #0
	mcr	p15, 0, r2, c8, c3, 0	@ invalidate TLB
	mcr	p15, 0, r2, c7, c5, 6	@ flush BTAC
	mcr	p15, 0, r2, c7, c5, 0	@ flush instruction cache

	mov32	r3, tegra_shut_off_mmu
	add	r3, r3, r0
	mov	r0, r1
	mov	pc, r3
ENDPROC(tegra_turn_off_mmu)

tegra_pgd_phys_address:
	.word	tegra_pgd_phys

/*
 * tegra_shut_off_mmu
 *
 * r0 = physical address to jump to with mmu off
 *
 * called with VA=PA mapping
 * turns off MMU, icache, dcache and branch prediction
 */
	.align	L1_CACHE_SHIFT
tegra_shut_off_mmu:
	mrc	p15, 0, r3, c1, c0, 0
	movw	r2, #CR_I | CR_Z | CR_C | CR_M
	bic	r3, r3, r2
	dsb
	mcr	p15, 0, r3, c1, c0, 0
	isb
	mov	pc, r0

/*
 * tegra_cpu_clk32k
 *
 * In LP2 the normal cpu clock pllx will be turned off. Switch the CPU to pllp
 */
ENTRY(tegra_cpu_pllp)
	/* in LP2 idle (SDRAM active), set the CPU burst policy to PLLP */
	mov32	r5, TEGRA_CLK_RESET_BASE
	mov	r0, #(2 << 28)			@ burst policy = run mode
	orr	r0, r0, #(4 << 4)		@ use PLLP in run mode burst
	str	r0, [r5, #CLK_RESET_CCLK_BURST]
	mov	r0, #0
	str	r0, [r5, #CLK_RESET_CCLK_DIVIDER]
	mov	pc, lr
ENDPROC(tegra_cpu_pllp)
#endif

#ifdef CONFIG_TRUSTED_FOUNDATIONS
/*
 * tegra_generic_smc
 *
 * r0 = smc type
 * r1 = smc subtype
 * r2 = argument passed to smc
 *
 * issues SMC (secure monitor call) instruction with
 * the specified parameters.
 */
ENTRY(tegra_generic_smc)
	adr	r3, __tegra_smc_stack
	stmia	r3, {r4-r12, lr}
	mov	r3, #0
	mov	r4, #0
	dsb
	smc	#0
	adr	r3, __tegra_smc_stack
	ldmia	r3, {r4-r12, pc}
ENDPROC(tegra_generic_smc)
	.type   __tegra_smc_stack, %object
__tegra_smc_stack:
	.long   0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	.size   __tegra_smc_stack, . - __tegra_smc_stack
#endif
