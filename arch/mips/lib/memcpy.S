/*
 * This file is subject to the terms and conditions of the GNU General Public
 * License.  See the file "COPYING" in the main directory of this archive
 * for more details.
 *
 * Unified implementation of memcpy and the __copy_user backend.
 *
 * Copyright (C) 1998, 99, 2000, 01, 2002 Ralf Baechle (ralf@gnu.org)
 * Copyright (C) 1999, 2000, 01, 2002 Silicon Graphics, Inc.
 * Copyright (C) 2002 Broadcom, Inc.
 *   memcpy/copy_user author: Mark Vandevoorde
 * Copyright (C) 2007  Maciej W. Rozycki
 * Copyright (C) 2014 Imagination Technologies Ltd.
 *
 * Mnemonic names for arguments to memcpy/__copy_user
 */

/*
 * Hack to resolve longstanding prefetch issue
 *
 * Prefetching may be fatal on some systems if we're prefetching beyond the
 * end of memory on some systems.  It's also a seriously bad idea on non
 * dma-coherent systems.
 */
#ifdef CONFIG_DMA_NONCOHERENT
#undef CONFIG_CPU_HAS_PREFETCH
#endif
#ifdef CONFIG_MIPS_MALTA
#undef CONFIG_CPU_HAS_PREFETCH
#endif
#ifdef CONFIG_CPU_MIPSR6
#undef CONFIG_CPU_HAS_PREFETCH
#endif

#include <asm/asm.h>
#include <asm/asm-offsets.h>
#include <asm/export.h>
#include <asm/regdef.h>
#include <asm/sgidefs.h>

#define src a1
#define len a2

/*
 * Spec
 *
 * memcpy copies len bytes from src to dst and sets v0 to dst.
 * It assumes that
 *   - src and dst don't overlap
 *   - src is readable
 *   - dst is writable
 * memcpy uses the standard calling convention
 *
 * __copy_user copies up to len bytes from src to dst and sets a2 (len) to
 * the number of uncopied bytes due to an exception caused by a read or write.
 * __copy_user assumes that src and dst don't overlap, and that the call is
 * implementing one of the following:
 *   copy_to_user
 *     - src is readable  (no exceptions when reading src)
 *   copy_from_user
 *     - dst is writable  (no exceptions when writing dst)
 *
 * When an exception happens on a load, the handler must
 # ensure that all of the destination buffer is overwritten to prevent
 * leaking information to user mode programs.
 */

/*
 * Implementation
 */

/*
 * The exception handler for loads requires that:
 *  1- a3 contain the address of the byte just past the end of the source
 *     of the copy,
 *  2- src_entry <= src < a3, and
 *  3- (dst - src) == (dst_entry - src_entry),
 * The _entry suffix denotes values when __copy_user was called.
 *
 * (1) is set up up by uaccess.h and maintained by not writing a3 in copy_user
 * (2) is met by incrementing src by the number of bytes copied
 * (3) is met by not doing loads between a pair of increments of dst and src
 *
 * The exception handlers for stores adjust len (if necessary) and return.
 * These handlers do not need to overwrite any data.
 */

/* Instruction type */
#define LD_INSN 1
#define ST_INSN 2
/* Pretech type */
#define SRC_PREFETCH 1
#define DST_PREFETCH 2
#define LEGACY_MODE 1
#define EVA_MODE    2
#define MEMCPY_MODE 3
#define USEROP   1
#define KERNELOP 2

/*
 * Wrapper to add an entry in the exception table
 * in case the insn causes a memory exception.
 * Arguments:
 * insn    : Load/store instruction
 * type    : Instruction type
 * reg     : Register
 * addr    : Address
 * handler : Exception handler
 */

#define EXC(insn, type, reg, addr, handler)			\
	.if \mode == MEMCPY_MODE;				\
		insn reg, addr;					\
	.elseif \mode == LEGACY_MODE;				\
9:		insn reg, addr;					\
		.section __ex_table,"a";			\
		PTR	9b, handler;				\
		.previous;					\
	/* This is assembled in EVA mode */			\
	.else;							\
		/* If loading from user or storing to user */	\
		.if ((\from == USEROP) && (type == LD_INSN)) || \
		    ((\to == USEROP) && (type == ST_INSN));	\
9:			__BUILD_EVA_INSN(insn##e, reg, addr);	\
			.section __ex_table,"a";		\
			PTR	9b, handler;			\
			.previous;				\
		.else;						\
			/*					\
			 *  Still in EVA, but no need for	\
			 * exception handler or EVA insn	\
			 */					\
			insn reg, addr;				\
		.endif;						\
	.endif

/*
 * Only on the 64-bit kernel we can made use of 64-bit registers.
 */
#ifdef CONFIG_64BIT
#define USE_DOUBLE
#endif

#ifdef USE_DOUBLE

#define LOADK ld /* No exception */
#define LOAD(reg, addr, handler)	EXC(ld, LD_INSN, reg, addr, handler)
#define LOADL(reg, addr, handler)	EXC(ldl, LD_INSN, reg, addr, handler)
#define LOADR(reg, addr, handler)	EXC(ldr, LD_INSN, reg, addr, handler)
#define STOREL(reg, addr, handler)	EXC(sdl, ST_INSN, reg, addr, handler)
#define STORER(reg, addr, handler)	EXC(sdr, ST_INSN, reg, addr, handler)
#define STORE(reg, addr, handler)	EXC(sd, ST_INSN, reg, addr, handler)
#define ADD    daddu
#define SUB    dsubu
#define SRL    dsrl
#define SRA    dsra
#define SLL    dsll
#define SLLV   dsllv
#define SRLV   dsrlv
#define NBYTES 8
#define LOG_NBYTES 3

#else

#define LOADK lw /* No exception */
#define LOAD(reg, addr, handler)	EXC(lw, LD_INSN, reg, addr, handler)
#define LOADL(reg, addr, handler)	EXC(lwl, LD_INSN, reg, addr, handler)
#define LOADR(reg, addr, handler)	EXC(lwr, LD_INSN, reg, addr, handler)
#define STOREL(reg, addr, handler)	EXC(swl, ST_INSN, reg, addr, handler)
#define STORER(reg, addr, handler)	EXC(swr, ST_INSN, reg, addr, handler)
#define STORE(reg, addr, handler)	EXC(sw, ST_INSN, reg, addr, handler)
#define ADD    addu
#define SUB    subu
#define SRL    srl
#define SLL    sll
#define SRA    sra
#define SLLV   sllv
#define SRLV   srlv
#define NBYTES 4
#define LOG_NBYTES 2

#endif /* USE_DOUBLE */

#define LOADB(reg, addr, handler)	EXC(lb, LD_INSN, reg, addr, handler)
#define STOREB(reg, addr, handler)	EXC(sb, ST_INSN, reg, addr, handler)

#define _PREF(hint, addr, type)						\
	.if \mode != EVA_MODE;						\
		PREF(hint, addr);					\
	.else;								\
		.if ((\from == USEROP) && (type == SRC_PREFETCH)) ||	\
		    ((\to == USEROP) && (type == DST_PREFETCH));	\
			/*						\
			 * PREFE has only 9 bits for the offset		\
			 * compared to PREF which has 16, so it may	\
			 * need to use the $at register but this	\
			 * register should remain intact because it's	\
			 * used later on. Therefore use $v1.		\
			 */						\
			PREFE(hint, addr);				\
		.else;							\
			PREF(hint, addr);				\
		.endif;							\
	.endif

#define PREFS(hint, addr) _PREF(hint, addr, SRC_PREFETCH)
#define PREFD(hint, addr) _PREF(hint, addr, DST_PREFETCH)

#ifdef CONFIG_CPU_LITTLE_ENDIAN
#define LDFIRST LOADR
#define LDREST	LOADL
#define STFIRST STORER
#define STREST	STOREL
#define SHIFT_DISCARD SLLV
#else
#define LDFIRST LOADL
#define LDREST	LOADR
#define STFIRST STOREL
#define STREST	STORER
#define SHIFT_DISCARD SRLV
#endif

#define FIRST(unit) ((unit)*NBYTES)
#define REST(unit)  (FIRST(unit)+NBYTES-1)
#define UNIT(unit)  FIRST(unit)

#define ADDRMASK (NBYTES-1)

	.text

	.align	5

	/*
	 * Macro to build the __copy_user common code
	 * Arguments:
	 * mode : LEGACY_MODE, EVA_MODE or MEMCPY_MODE
	 * from : Source operand. USEROP or KERNELOP
	 * to   : Destination operand. USEROP or KERNELOP
	 */
	.macro __BUILD_COPY_USER mode, from, to, dst, uncopied

	/*
	 * Note: dst & src may be unaligned, len may be 0
	 * Temps
	 */
#define rem ta2

	R10KCBARRIER(0(ra))
	/*
	 * The "issue break"s below are very approximate.
	 * Issue delays for dcache fills will perturb the schedule, as will
	 * load queue full replay traps, etc.
	 *
	 * If len < NBYTES use byte operations.
	 */
	PREFS(	0, 0(src) )
	PREFD(	1, 0(\dst) )
	sltu	t2, len, NBYTES
	and	t1, \dst, ADDRMASK
	PREFS(	0, 1*32(src) )
	PREFD(	1, 1*32(\dst) )
	and	t0, src, ADDRMASK
	bnez	t2, .Lcopy_bytes_checklen\@
	PREFS(	0, 2*32(src) )
	PREFD(	1, 2*32(\dst) )
#ifndef CONFIG_CPU_MIPSR6
	bnez	t1, .Ldst_unaligned\@
	bnez	t0, .Lsrc_unaligned_dst_aligned\@
#else
	or	t0, t0, t1
	bnez	t0, .Lcopy_unaligned_bytes\@
#endif
	/*
	 * src and dst are aligned; need to compute rem
	 */
.Lboth_aligned\@:
	SRL	t0, len, LOG_NBYTES+3	 # +3 for 8 units/iter
	and	rem, len, (8*NBYTES-1)	 # rem = len % (8*NBYTES)
	beqz	t0, .Lcleanup_both_aligned\@ # len < 8*NBYTES
	PREFS(	0, 3*32(src) )
	PREFD(	1, 3*32(\dst) )
1:
	R10KCBARRIER(0(ra))
	LOAD(t0, UNIT(0)(src), .Ll_exc\@)
	LOAD(t1, UNIT(1)(src), .Ll_exc_copy\@)
	LOAD(t2, UNIT(2)(src), .Ll_exc_copy\@)
	LOAD(t3, UNIT(3)(src), .Ll_exc_copy\@)
	SUB	len, len, 8*NBYTES
	LOAD(ta0, UNIT(4)(src), .Ll_exc_copy\@)
	LOAD(ta1, UNIT(5)(src), .Ll_exc_copy\@)
	STORE(t0, UNIT(0)(\dst),	.Ls_exc_p8u\@)
	STORE(t1, UNIT(1)(\dst),	.Ls_exc_p7u\@)
	LOAD(t0, UNIT(6)(src), .Ll_exc_copy\@)
	LOAD(t1, UNIT(7)(src), .Ll_exc_copy\@)
	ADD	src, src, 8*NBYTES
	ADD	\dst, \dst, 8*NBYTES
	STORE(t2, UNIT(-6)(\dst), .Ls_exc_p6u\@)
	STORE(t3, UNIT(-5)(\dst), .Ls_exc_p5u\@)
	STORE(ta0, UNIT(-4)(\dst), .Ls_exc_p4u\@)
	STORE(ta1, UNIT(-3)(\dst), .Ls_exc_p3u\@)
	STORE(t0, UNIT(-2)(\dst), .Ls_exc_p2u\@)
	STORE(t1, UNIT(-1)(\dst), .Ls_exc_p1u\@)
	PREFS(	0, 8*32(src) )
	PREFD(	1, 8*32(\dst) )
	bne	len, rem, 1b

	/*
	 * len == rem == the number of bytes left to copy < 8*NBYTES
	 */
.Lcleanup_both_aligned\@:
	sltu	t0, len, 4*NBYTES
	beqz	len, .Ldone\@
	and	rem, len, (NBYTES-1)	# rem = len % NBYTES
	bnez	t0, .Lless_than_4units\@
	/*
	 * len >= 4*NBYTES
	 */
	LOAD( t0, UNIT(0)(src),	.Ll_exc\@)
	LOAD( t1, UNIT(1)(src),	.Ll_exc_copy\@)
	LOAD( t2, UNIT(2)(src),	.Ll_exc_copy\@)
	LOAD( t3, UNIT(3)(src),	.Ll_exc_copy\@)
	SUB	len, len, 4*NBYTES
	ADD	src, src, 4*NBYTES
	R10KCBARRIER(0(ra))
	STORE(t0, UNIT(0)(\dst),	.Ls_exc_p4u\@)
	STORE(t1, UNIT(1)(\dst),	.Ls_exc_p3u\@)
	STORE(t2, UNIT(2)(\dst),	.Ls_exc_p2u\@)
	STORE(t3, UNIT(3)(\dst),	.Ls_exc_p1u\@)
	ADD	\dst, \dst, 4*NBYTES
	beqz	len, .Ldone\@
.Lless_than_4units\@:
	/*
	 * rem = len % NBYTES
	 */
	beq	rem, len, .Lcopy_bytes\@
1:
	R10KCBARRIER(0(ra))
	LOAD(t0, 0(src), .Ll_exc\@)
	ADD	src, src, NBYTES
	SUB	len, len, NBYTES
	STORE(t0, 0(\dst), .Ls_exc_p1u\@)
	ADD	\dst, \dst, NBYTES
	bne	rem, len, 1b

#ifndef CONFIG_CPU_MIPSR6
	/*
	 * src and dst are aligned, need to copy rem bytes (rem < NBYTES)
	 * A loop would do only a byte at a time with possible branch
	 * mispredicts.	 Can't do an explicit LOAD dst,mask,or,STORE
	 * because can't assume read-access to dst.  Instead, use
	 * STREST dst, which doesn't require read access to dst.
	 *
	 * This code should perform better than a simple loop on modern,
	 * wide-issue mips processors because the code has fewer branches and
	 * more instruction-level parallelism.
	 */
#define bits t2
	ADD	t1, \dst, len	# t1 is just past last byte of dst
	beqz	len, .Ldone\@
	li	bits, 8*NBYTES
	SLL	rem, len, 3	# rem = number of bits to keep
	LOAD(t0, 0(src), .Ll_exc\@)
	SUB	bits, bits, rem # bits = number of bits to discard
	SHIFT_DISCARD t0, t0, bits
	STREST(t0, -1(t1), .Ls_exc\@)
	move	len, zero
	move	\uncopied, zero
	jr	ra
.Ldst_unaligned\@:
	/*
	 * dst is unaligned
	 * t0 = src & ADDRMASK
	 * t1 = dst & ADDRMASK; T1 > 0
	 * len >= NBYTES
	 *
	 * Copy enough bytes to align dst
	 * Set match = (src and dst have same alignment)
	 */
#define match rem
	LDFIRST(t3, FIRST(0)(src), .Ll_exc\@)
	ADD	t2, zero, NBYTES
	LDREST(t3, REST(0)(src), .Ll_exc_copy\@)
	SUB	t2, t2, t1	# t2 = number of bytes copied
	xor	match, t0, t1
	R10KCBARRIER(0(ra))
	STFIRST(t3, FIRST(0)(\dst), .Ls_exc\@)
	SUB	len, len, t2
	beqz	len, .Ldone\@
	ADD	\dst, \dst, t2
	ADD	src, src, t2
	beqz	match, .Lboth_aligned\@

.Lsrc_unaligned_dst_aligned\@:
	SRL	t0, len, LOG_NBYTES+2	 # +2 for 4 units/iter
	PREFS(	0, 3*32(src) )
	and	rem, len, (4*NBYTES-1)	 # rem = len % 4*NBYTES
	beqz	t0, .Lcleanup_src_unaligned\@
	PREFD(	1, 3*32(\dst) )
1:
/*
 * Avoid consecutive LD*'s to the same register since some mips
 * implementations can't issue them in the same cycle.
 * It's OK to load FIRST(N+1) before REST(N) because the two addresses
 * are to the same unit (unless src is aligned, but it's not).
 */
	R10KCBARRIER(0(ra))
	LDFIRST(t0, FIRST(0)(src), .Ll_exc\@)
	LDFIRST(t1, FIRST(1)(src), .Ll_exc_copy\@)
	SUB	len, len, 4*NBYTES
	LDREST(t0, REST(0)(src), .Ll_exc_copy\@)
	LDREST(t1, REST(1)(src), .Ll_exc_copy\@)
	LDFIRST(t2, FIRST(2)(src), .Ll_exc_copy\@)
	LDFIRST(t3, FIRST(3)(src), .Ll_exc_copy\@)
	LDREST(t2, REST(2)(src), .Ll_exc_copy\@)
	LDREST(t3, REST(3)(src), .Ll_exc_copy\@)
	PREFS(	0, 9*32(src) )		# 0 is PREF_LOAD  (not streamed)
	ADD	src, src, 4*NBYTES
#ifdef CONFIG_CPU_SB1
	nop				# improves slotting
#endif
	STORE(t0, UNIT(0)(\dst),	.Ls_exc_p4u\@)
	STORE(t1, UNIT(1)(\dst),	.Ls_exc_p3u\@)
	STORE(t2, UNIT(2)(\dst),	.Ls_exc_p2u\@)
	STORE(t3, UNIT(3)(\dst),	.Ls_exc_p1u\@)
	PREFD(	1, 9*32(\dst) )		# 1 is PREF_STORE (not streamed)
	ADD	\dst, \dst, 4*NBYTES
	bne	len, rem, 1b

.Lcleanup_src_unaligned\@:
	and	rem, len, NBYTES-1  # rem = len % NBYTES
	beqz	len, .Ldone\@
	beq	rem, len, .Lcopy_bytes\@
1:
	R10KCBARRIER(0(ra))
	LDFIRST(t0, FIRST(0)(src), .Ll_exc\@)
	LDREST(t0, REST(0)(src), .Ll_exc_copy\@)
	ADD	src, src, NBYTES
	SUB	len, len, NBYTES
	STORE(t0, 0(\dst), .Ls_exc_p1u\@)
	ADD	\dst, \dst, NBYTES
	bne	len, rem, 1b

#endif /* !CONFIG_CPU_MIPSR6 */
.Lcopy_bytes_checklen\@:
	beqz	len, .Ldone\@
.Lcopy_bytes\@:
	/* 0 < len < NBYTES  */
	R10KCBARRIER(0(ra))
#define COPY_BYTE(N)			\
	LOADB(t0, N(src), .Ll_exc\@);	\
	SUB	len, len, 1;		\
	STOREB(t0, N(\dst), .Ls_exc_p1\@);\
	beqz	len, .Ldone\@

	COPY_BYTE(0)
	COPY_BYTE(1)
#ifdef USE_DOUBLE
	COPY_BYTE(2)
	COPY_BYTE(3)
	COPY_BYTE(4)
	COPY_BYTE(5)
#endif
	LOADB(t0, NBYTES-2(src), .Ll_exc\@)
	SUB	len, len, 1
	STOREB(t0, NBYTES-2(\dst), .Ls_exc_p1\@)
	move	\uncopied, len
	jr	ra
.Ldone\@:
	move	\uncopied, len
	jr	ra

#ifdef CONFIG_CPU_MIPSR6
.Lcopy_unaligned_bytes\@:
1:
	COPY_BYTE(0)
	COPY_BYTE(1)
	COPY_BYTE(2)
	COPY_BYTE(3)
	COPY_BYTE(4)
	COPY_BYTE(5)
	COPY_BYTE(6)
	COPY_BYTE(7)
	ADD	src, src, 8
	ADD	\dst, \dst, 8
	b	1b
#endif /* CONFIG_CPU_MIPSR6 */

	/* memcpy shouldn't generate exceptions */
	.if	\mode != MEMCPY_MODE

.Ll_exc_copy\@:
	/*
	 * Copy bytes from src until faulting load address (or until a
	 * lb faults)
	 *
	 * When reached by a faulting LDFIRST/LDREST, THREAD_BUADDR($28)
	 * may be more than a byte beyond the last address.
	 * Hence, the lb below may get an exception.
	 *
	 * Assumes src < THREAD_BUADDR($28)
	 */
	LOADK	t0, THREAD_BUADDR($28)
1:
	LOADB(t1, 0(src), .Ll_exc\@)
	ADD	src, src, 1
	sb	t1, 0(\dst)	# can't fault -- we're copy_from_user
	ADD	\dst, \dst, 1
	bne	src, t0, 1b
.Ll_exc\@:
	LOADK	t0, THREAD_BUADDR($28)	# t0 is just past last good address
	SUB	len, a3, t0		# len number of uncopied bytes
	move    \uncopied, len
	jr	ra

#define SEXC(n)							\
.Ls_exc_p ## n ## u\@:						\
	ADD	\uncopied, len, n*NBYTES;			\
	jr	ra;						\

SEXC(8)
SEXC(7)
SEXC(6)
SEXC(5)
SEXC(4)
SEXC(3)
SEXC(2)
SEXC(1)

.Ls_exc_p1\@:
	ADD	\uncopied, len, 1
	jr	ra
.Ls_exc\@:
	move	\uncopied, len
	jr	ra

	.endif	/* \mode != MEMCPY_MODE */
	.endm

/*
 * memcpy() - Copy memory
 * @a0 - destination
 * @a1 - source
 * @a2 - length
 *
 * Copy @a2 bytes of memory from @a1 to @a0.
 *
 * Returns: the destination pointer
 */
	.align	5
LEAF(memcpy)					/* a0=dst a1=src a2=len */
EXPORT_SYMBOL(memcpy)
#if _MIPS_SIM == _MIPS_SIM_PABI32
	move	ta3, a0
# define dst	ta3
#else
	move	v0, a0
# define dst	a0
#endif
.L__memcpy:
	/* Legacy Mode, user <-> user */
	__BUILD_COPY_USER MEMCPY_MODE USEROP USEROP dst len
#undef dst
	END(memcpy)

/*
 * __copy_user() - Copy memory
 * @a0 - destination
 * @a1 - source
 * @a2 - length
 *
 * Copy @a2 bytes of memory from @a1 to @a0.
 *
 * Returns: the number of uncopied bytes in @a2
 */
	.align	5
LEAF(__copy_user)
EXPORT_SYMBOL(__copy_user)
	/* Legacy Mode, user <-> user */
	__BUILD_COPY_USER LEGACY_MODE USEROP USEROP a0 v0
	END(__copy_user)

#ifdef CONFIG_EVA

/*
 * For EVA we need distinct symbols for reading and writing to user space.
 * This is because we need to use specific EVA instructions to perform the
 * virtual <-> physical translation when a virtual address is actually in user
 * space
 */

/*
 * __copy_from_user (EVA)
 */

LEAF(__copy_from_user_eva)
EXPORT_SYMBOL(__copy_from_user_eva)
	__BUILD_COPY_USER EVA_MODE USEROP KERNELOP a0 v0
END(__copy_from_user_eva)



/*
 * __copy_to_user (EVA)
 */

LEAF(__copy_to_user_eva)
EXPORT_SYMBOL(__copy_to_user_eva)
__BUILD_COPY_USER EVA_MODE KERNELOP USEROP a0 v0
END(__copy_to_user_eva)

/*
 * __copy_in_user (EVA)
 */

LEAF(__copy_in_user_eva)
EXPORT_SYMBOL(__copy_in_user_eva)
__BUILD_COPY_USER EVA_MODE USEROP USEROP a0 v0
END(__copy_in_user_eva)

#endif
