/* -*- mode: asm -*-
**
** head.S -- This file contains the initial boot code for the
**	     Linux/68k kernel.
**
** Copyright 1993 by Hamish Macdonald
**
** 68040 fixes by Michael Rausch
** 68060 fixes by Roman Hodek
**
** Atari support by Andreas Schwab, using ideas of Robert de Vries
** and Bjoern Brauel
**
** 94/11/14 Andreas Schwab: put kernel at PAGESIZE
** 94/11/18 Andreas Schwab: remove identity mapping of STRAM for Atari
** ++ Bjoern & Roman: ATARI-68040 support for the Medusa
** 96/04/26 G|nther Kelleter: fixed identity mapping for Falcon with
** 			      Magnum- and FX-alternate ram
**
** This file is subject to the terms and conditions of the GNU General Public
** License. See the file README.legal in the main directory of this archive
** for more details.
**
*/

/*
 * Linux startup code.
 *
 * At this point, the boot loader has:
 * Disabled interrupts
 * Disabled caches
 * Put us in supervisor state.
 *
 * The kernel setup code takes the following steps:
 *   Raise interrupt level
 *   Set up initial kernel memory mapping.
 *	This sets up a mapping of the 4M of memory the kernel
 *	is located in.	It also does a mapping of any initial
 *	machine specific areas.
 * Note that the kernel is located at virtual address 0x1000 == _start
 *   Enable cache memories
 *   Jump to kernel startup
 *
 * Register d6 contains the CPU flags and d4 the machine type
 * from the boot_info information for most of this file.
 * The upper word of d6 contains a bit for '040 or '060, since these two
 * are quite similar for initial mm setup. Another bit in d6 allows
 * distinction of the '060. The lower word of d6 contains the cache mode
 * that should be applied to pages containing descriptors. This mode is
 * non-cached/non-serialized for the '040 and cacheable/write-through for
 * the '060.
 *
 * General register usage:
 *   a6 - start of unused memory
 *	  new pages can be allocated from here
 *   a5 - mmu root table
 *   a4 - mmu pointer table
 *   a3 - mmu page tables
 *   a2 - points to the page table entry for a6
 *	  cache status can be changed (used for '0[46]0)
 *	  you must increase a2 if alloc a new page
 *   d7 - used for debug output and some macros
 *   d6 - cpu type and cache mode
 *   d5 - physical start address of kernel
 *   d4 - machine type
 */

#include <linux/autoconf.h>
#include <linux/linkage.h>
#include <asm/bootinfo.h>
#include <asm/pgtable.h>

.globl SYMBOL_NAME(kernel_pg_dir), SYMBOL_NAME(kpt)
.globl SYMBOL_NAME(availmem), SYMBOL_NAME(is_medusa)
.globl SYMBOL_NAME(m68k_pgtable_cachemode)
.globl SYMBOL_NAME(kernel_pmd_table), SYMBOL_NAME(swapper_pg_dir)

D6B_0460 = 16		/* indicates 680[46]0 in d6 */
D6B_060  = 17		/* indicates 68060 in d6 */
D6F_040  = 1<<D6B_0460
D6F_060  = (1<<D6B_0460)+(1<<D6B_060)

/* Translation control register */
TC_ENABLE = 0x8000
TC_PAGE8K = 0x4000
TC_PAGE4K = 0x0000

/* Transparent translation registers */
TTR_ENABLE	= 0x8000	/* enable transparent translation */
TTR_ANYMODE	= 0x4000	/* user and kernel mode access */
TTR_KERNELMODE	= 0x2000	/* only kernel mode access */
TTR_USERMODE	= 0x0000	/* only user mode access */
TTR_CI		= 0x0400	/* inhibit cache */
TTR_RW		= 0x0200	/* read/write mode */
TTR_RWM		= 0x0100	/* read/write mask */
TTR_FCB2	= 0x0040	/* function code base bit 2 */
TTR_FCB1	= 0x0020	/* function code base bit 1 */
TTR_FCB0	= 0x0010	/* function code base bit 0 */
TTR_FCM2	= 0x0004	/* function code mask bit 2 */
TTR_FCM1	= 0x0002	/* function code mask bit 1 */
TTR_FCM0	= 0x0001	/* function code mask bit 0 */

/* Cache Control registers */
CC6_ENABLE_D	= 0x80000000	/* enable data cache (680[46]0) */
CC6_FREEZE_D	= 0x40000000	/* freeze data cache (68060) */
CC6_ENABLE_SB	= 0x20000000	/* enable store buffer (68060) */
CC6_PUSH_DPI	= 0x10000000	/* disable CPUSH invalidation (68060) */
CC6_HALF_D	= 0x08000000	/* half-cache mode for data cache (68060) */
CC6_ENABLE_B	= 0x00800000	/* enable branch cache (68060) */
CC6_CLRA_B	= 0x00400000	/* clear all entries in branch cache (68060) */
CC6_CLRU_B	= 0x00200000	/* clear user entries in branch cache (68060) */
CC6_ENABLE_I	= 0x00008000	/* enable instruction cache (680[46]0) */
CC6_FREEZE_I	= 0x00004000	/* freeze instruction cache (68060) */
CC6_HALF_I	= 0x00002000	/* half-cache mode for instruction cache (68060) */
CC3_ALLOC_WRITE	= 0x00002000	/* write allocate mode(68030) */
CC3_ENABLE_DB	= 0x00001000	/* enable data burst (68030) */
CC3_CLR_D	= 0x00000800	/* clear data cache (68030) */
CC3_CLRE_D	= 0x00000400	/* clear entry in data cache (68030) */
CC3_FREEZE_D	= 0x00000200	/* freeze data cache (68030) */
CC3_ENABLE_D	= 0x00000100	/* enable data cache (68030) */
CC3_ENABLE_IB	= 0x00000010	/* enable instruction burst (68030) */
CC3_CLR_I	= 0x00000008	/* clear instruction cache (68030) */
CC3_CLRE_I	= 0x00000004	/* clear entry in instruction cache (68030) */
CC3_FREEZE_I	= 0x00000002	/* freeze instruction cache (68030) */
CC3_ENABLE_I	= 0x00000001	/* enable instruction cache (68030) */

/* Miscellaneous definitions */
PAGESIZE	= 4096

ROOT_TABLE_SIZE	= 128
PTR_TABLE_SIZE	= 128
PAGE_TABLE_SIZE	= 64
ROOT_INDEX_SHIFT = 25
PTR_INDEX_SHIFT  = 18
PAGE_INDEX_SHIFT = 12

TABLENR_4MB	= 16	/* # of page tables needed to page 4 MB */
TABLENR_16MB	= 64	/* same for 16 MB */

#define putc(ch) moveq &ch,%d7; jbsr Lserial_putc
#define putr() putc(13); putc(10)
#define putn(nr) movel nr,%d7; jbsr Lserial_putnum

#define is_not_amiga(lab) moveq &MACH_AMIGA,%d7; cmpl %d4,%d7; jne lab
#define is_not_atari(lab) moveq &MACH_ATARI,%d7; cmpl %d4,%d7; jne lab

#define is_040_or_060(lab) btst &D6B_0460,%d6; jne lab
#define is_not_040_or_060(lab) btst &D6B_0460,%d6; jeq lab
#define is_060(lab) btst &D6B_060,%d6; jne lab
#define is_not_060(lab) btst &D6B_060,%d6; jeq lab

.text
ENTRY(_stext)
/*
 * Version numbers of the bootinfo interface
 * The area from _stext to _start will later be used as kernel pointer table
 */
	bras	1f	/* Jump over bootinfo version numbers */

	.long	BOOTINFOV_MAGIC
	.long	MACH_AMIGA, AMIGA_BOOTI_VERSION
	.long	MACH_ATARI, ATARI_BOOTI_VERSION
	.long	0
1:	jra	SYMBOL_NAME(_start)

.equ	SYMBOL_NAME(kernel_pmd_table),SYMBOL_NAME(_stext)
.equ	SYMBOL_NAME(kernel_pg_dir),SYMBOL_NAME(kernel_pmd_table)
.equ	SYMBOL_NAME(swapper_pg_dir),SYMBOL_NAME(kernel_pg_dir)+(ROOT_TABLE_SIZE<<2)
.equ	Lavail_pmd_table,SYMBOL_NAME(swapper_pg_dir)+(ROOT_TABLE_SIZE<<2)

.equ	.,SYMBOL_NAME(_stext)+PAGESIZE

ENTRY(_start)

/*
 * Setup initial stack pointer
 */
	lea	%pc@(SYMBOL_NAME(_stext):w),%sp

/*
 * Copy bootinfo from position after BSS to final resting place
 */
	lea	%pc@(SYMBOL_NAME(_end)),%a0
	lea	%pc@(SYMBOL_NAME(boot_info)),%a1
	movel	%pc@(SYMBOL_NAME(bisize)),%d0
	subql	#1,%d0
1:	moveb	%a0@+,%a1@+
	dbra	%d0,1b

/*
 * Record the CPU and machine type.
 */
	lea	%pc@(SYMBOL_NAME(boot_info)),%a0
	movel	%a0@(BI_machtype),%d4
	movel	%a0@(BI_cputype),%d0

	btst	#CPUB_68060,%d0
	jeq	1f
	/* '060: d6 := BIT0460|BIT060, cache mode 0x60 (no-cache/non-ser) */
	movel	#D6F_060+_PAGE_NOCACHE,%d6
	jra	2f
1:	btst	#CPUB_68040,%d0
	jeq	1f
	/* '040: d6 := BIT0460, cache mode 0x00 (write-through) */
	movel	#D6F_040+_PAGE_CACHE040W,%d6
	jra	2f
1:	/* '020 or '030: d6 := no CPU bit, cache mode unused */
	moveq	#0,%d6

2:	lea	%pc@(SYMBOL_NAME(m68k_pgtable_cachemode)),%a0
	moveq	#0,%d0
	movew	%d6,%d0
	movel	%d0,%a0@		/* save cache mode for page tables */

/*
 * raise interrupt level with MASTER bit set, copy isp to msp (if not 68060)
 */
#ifdef FROM_PL9
	movew	#0x3700,%sr
	is_060(1f)
	movec	%isp,%d0
	movel	%d0,%sp
1:
#else
	movew	#0x2700,%sr
#endif

/*
 * Initialize serial port
 */
	jbsr Lserial_init

	putr()
	putc('A')

/*
 * Get address at end of kernel code/data/bss and
 * mask off at a page boundary.
 */
	lea	%pc@(SYMBOL_NAME(_end)),%a0
	addw	#PAGESIZE-1,%a0
	movel	%a0,%d0
	andl	#-PAGESIZE,%d0
	movel	%d0,%a6

	putc('B')

/*
 * Save physical start address of kernel
 */
	lea	%pc@(SYMBOL_NAME(_stext)-PAGESIZE:w),%a0
	movel	%a0,%d5
#ifdef HACKER_KERNEL
	lea	%pc@(Lkernel_start),%a0
	movel	%d5,%a0@
#endif

/*
 * initialize the kernel root table.
 */
	lea	%pc@(SYMBOL_NAME(kernel_pg_dir):w),%a5
	movel	%a5,%a0
	moveq	#ROOT_TABLE_SIZE-1,%d1
1:	clrl	%a0@+
	dbra	%d1,1b

	/*
	 * Initialize root table descriptor pointing to the kernel pointer
	 * table.
	 */
	lea	%pc@(Lavail_pmd_table:w),%a4
	moveq	#_PAGE_TABLE,%d0
	addl	%a4,%d0
	movel	%d0,%a5@

	putc('C')

/*
 * Initialize the pointer tables referred to above.  They either point
 * to page tables in the case of the 680[46]0 or contain early
 * termination page descriptors in the case of the 68851 or 68030.
 *
 * Each pointer table entry points to a 64 entry page table.  16 of these
 * page tables are grouped to form a single 1024 entry page table which
 * fits in a single 4096 byte page.
 *
 * Some register usages:
 *    a0 -> pointer table descriptor address
 *    a1 -> pointer table descriptor
 *    d1 -> counter
 *    d2 -> pointer table descriptor increment (varies according to CPU)
 */

	/* clear the kernel pointer table */
	movel	%a4,%a0
	moveq	#PTR_TABLE_SIZE-1,%d1
1:	clrl	%a0@+
	dbra	%d1,1b

	movel	%a4,%a0
	moveq	#15,%d1

	/*
	 * base value of pointer table descriptor is either
	 * the address of the first page table (680[46]0)
	 * or the base address of physical memory (68030).
	 */
	is_040_or_060(1f)

	/* 680[23]0 */
	movel	%d5,%a1				/* base address */
	addql	#_PAGE_PRESENT,%a1		/* descriptor type */
	movel	#PAGE_TABLE_SIZE*PAGESIZE,%d2	/* increment */
	jra	2f

1:	/* 680[46]0 */
	movel	%a6,%a3			/* base address */
	addw	#PAGESIZE,%a6		/* allocate page for 16 page tables */
	lea	%pc@(SYMBOL_NAME(kpt)),%a1
	movel	%a3,%a1@		/* save address of page table */
	movel	%a3,%a1
	addql	#_PAGE_TABLE,%a1	/* descriptor type */
	movel	#PAGE_TABLE_SIZE<<2,%d2 /* increment */

2:	movel	%a1,%a0@+
	addl	%d2,%a1
	dbra	%d1,2b

	putc('D')

/*
 * If we are running on a 680[46]0, we have a kernel page table and
 * must initialize it.	Make the entries point to the first
 * 4M of physical memory (the memory we are residing in).
 * Set the cache mode bits to Cacheable, Copyback.  Set the Global bits
 * in the descriptors also.
 */
	is_not_040_or_060(Lnot040)

	putc('F')

	movel	%a3,%a0
	movel	%d5,%a1
	addw	#_PAGE_GLOBAL040+_PAGE_CACHE040+_PAGE_PRESENT,%a1
	movew	#(PAGE_TABLE_SIZE*TABLENR_4MB)-1,%d1
	movel	#PAGESIZE,%d2
1:	movel	%a1,%a0@+
	addl	%d2,%a1
	dbra	%d1,1b

	/*
	 * on the 68040, pages used to hold mmu tables should
	 * be initialized as noncachable; the '060 allows write-through.
	 * Do this for the root table page (which also contains
	 * all pointer tables utilized thus far) and the
	 * kernel page table.
	 */
	movel	%a5,%d0
	subl	%d5,%d0
	moveq	#PAGE_INDEX_SHIFT,%d2
	lsrl	%d2,%d0
	lea	%a3@(%d0:l:4),%a2
	movel	%a2@,%d1
	andw	#_CACHEMASK040,%d1
	orw	%d6,%d1
	movel	%d1,%a2@

	movel	%a3,%d0
	subl	%d5,%d0
	lsrl	%d2,%d0
	lea	%a3@(%d0:l:4),%a2
	movel	%a2@,%d1
	andw	#_CACHEMASK040,%d1
	orw	%d6,%d1
	movel	%d1,%a2@+
	/*
	 * %a2 points now to the page table entry for available pages at %a6,
	 * hence caching modes for new pages can easily set unless increasing
	 * of %a2 are forgotten.
	 */
Lnot040:
/*
 * Do any machine specific page table initializations.
 */
#ifdef CONFIG_AMIGA
	is_not_amiga(Lnotami)

/*
 * Setup a mapping of the first 16M of physical address space at virtual
 * address 0x80000000, using early termination page descriptors for the
 * 68030, and proper page tables for the 680[46]0.  Set this area as
 * non-cacheable.
 */

	putc('H')

	is_040_or_060(Lspami68040)

	/*
	 * for the 68030, just setup a translation to map in the first
	 * 32M of physical address space at virtual address 0x80000000
         * using an early termination page descriptor.
	 */

	putc('I')

	moveq	#_PAGE_NOCACHE030+_PAGE_PRESENT,%d0
	movel	%d0,%a5@(0x40<<2)

	jra	Lmapphys

Lspami68040:

	/*
	 * for the 680[46]0, use another pointer table, and allocate 4 more
	 * page tables.  Initialize the pointer table to point to the
	 * page tables.  Then initialize the page tables to point to
	 * the first 16M of memory, with no caching (noncachable/serialized).
	 */

	/* clear the amiga pointer table */
	lea	%a4@(PTR_TABLE_SIZE<<2),%a4
	moveq	#PTR_TABLE_SIZE-1,%d1
1:	clrl	%a0@+
	dbra	%d1,1b

	/* allocate 4 pages for 64 page tables */
	movel	%a6,%a3
	addw	#4*PAGESIZE,%a6

	/* initialize the pointer table */
	movel	%a4,%a0
	movel	%a3,%a1
	addql	#_PAGE_TABLE,%a1	/* base descriptor */
	movel	#PAGE_TABLE_SIZE<<2,%d2 /* increment */
	moveq	#TABLENR_16MB-1,%d1

1:	movel	%a1,%a0@+
	addl	%d2,%a1
	dbra	%d1,1b

	/* ensure that the root table points to the pointer table */
	movel	%a4,%a0
	addql	#_PAGE_TABLE,%a0
	movel	%a0,%a5@(0x40<<2)

	/*
	 * initialize the page tables
	 * descriptor bits include noncachable/serialized and global bits.
	 */
	movel	%a3,%a0
	movew	#_PAGE_GLOBAL040+_PAGE_NOCACHE_S+_PAGE_PRESENT,%a1
	movel	#PAGESIZE,%d2
	movew	#(PAGE_TABLE_SIZE*TABLENR_16MB)-1,%d1

1:	movel	%a1,%a0@+
	addl	%d2,%a1
	dbra	%d1,1b

	/*
	 * Finally, since we just allocated 4 page tables, make sure that
	 * the virtual mapping of the 4 page tables indicates
	 * noncachable/serialized.
	 */
	moveq	#3,%d0
1:	movel	%a2@,%d1	/* a2 already points to root table offset */
	andw	#_CACHEMASK040,%d1
	orw	%d6,%d1
	movel	%d1,%a2@+
	dbra	%d0,1b

	jra	Lmapphys

Lnotami:
#endif

#ifdef CONFIG_ATARI
	is_not_atari(Lnotatari)

	move.w	#PAGESIZE,%sp

/* On the Atari, we map the I/O region (phys. 0x00ffxxxx) by mapping
   the last 16 MB of virtual address space to the first 16 MB (i.e.
   0xffxxxxxx -> 0x00xxxxxx). For this, an additional pointer table is
   needed. I/O ranges are marked non-cachable.

   For the Medusa it is better to map the I/O region transparently
   (i.e. 0xffxxxxxx -> 0xffxxxxxx), because some I/O registers are
   accessible only in the high area. The test whether it is a Medusa
   is done by writing to the byte at phys. 0x0. This should result
   in a bus error on all other machines.

   ...should, but doesn't. The Afterburner040 for the Falcon has the
   same behaviour (0x0..0x7 are no ROM shadow). So we have to do
   another test to distinguish Medusa and AB040. This is a
   read attempt for 0x00ff82fe phys. that should bus error on a Falcon
   (+AB040), but is in the range where the Medusa always asserts DTACK.
*/

	moveq	#0,%d3			/* base addr for others: 0x00000000 */
	movec	%d3,%vbr
	lea	%pc@(Ltest_berr),%a0
	movel	%a0,0x8
	movel	%sp,%a0
	moveb	0x0,%d1
	clrb	0x0
	nop
	moveb	%d1,0x0
	nop
	tstb	0x00ff82fe
	nop
	movel	#0xff000000,%d3		/* Medusa base addr: 0xff000000 */
Ltest_berr:
	movel	%a0,%sp
	lea     %pc@(SYMBOL_NAME(is_medusa)),%a0
	movel	%d3,%a0@

	/* Let the root table point to the new pointer table */
	lea	%a4@(PTR_TABLE_SIZE<<2),%a4
	movel	%a4,%a0
	addl	#_PAGE_TABLE,%a0
	movel	%a0,%a5@(0x7f<<2)       /* 0xFE000000 - 0xFFFFFFFF */

	/* clear lower half of the pointer table (0xfexxxxxx) */
	movel	%a4,%a0
	movel	#(PTR_TABLE_SIZE/2)-1,%d2
1:	clrl	%a0@+
	dbra	%d2,1b

	is_040_or_060(Lspata68040)

/* Mapping of the last 16M of virtual address space to the first 16M
   for efficient addressing of hardware registers */
	movel	#PAGE_TABLE_SIZE*PAGESIZE,%d1
	movel	#(PTR_TABLE_SIZE/2)-1,%d2
	movel	%d3,%d0
	addl	#_PAGE_PRESENT,%d0
1:	movel	%d0,%a0@+
	addl	%d1,%d0
	dbra	%d2,1b
	moveq	#_PAGE_NOCACHE030,%d0	/* make non-cachable */
	addl	%d0,%a4@(0x7f<<2)	/* 0xFFFC0000-0xFFFFFFFF (I/O space) */
/* GK: 0xFFF00000-0xFFF3FFFF (IDE-bus) has to be non-cachable too */
	addl	%d0,%a4@(0x7c<<2)

	jra	Lmapphys

Lspata68040:
	/* allocate 4 page tables */
	movel	%a6,%a3
	addw	#4*PAGESIZE,%a6

	/* Initialize the upper half of the pointer table (a0 is still valid) */
	movel	%a3,%a1
	addql	#_PAGE_TABLE,%a1
	movel	#PAGE_TABLE_SIZE<<2,%d2
	moveq	#TABLENR_16MB-1,%d1
1:	movel	%a1,%a0@+
	addl	%d2,%a1
	dbra 	%d1,1b

	/* Initialize the page tables as noncacheable/serialized! */
	movel	%a3,%a0
	movel	%d3,%a1
	addw	#_PAGE_GLOBAL040+_PAGE_NOCACHE_S+_PAGE_PRESENT,%a1
	movel	#PAGESIZE,%d2
	movew	#(PAGE_TABLE_SIZE*TABLENR_16MB)-1,%d1
1:	movel	%a1,%a0@+
	addl	%d2,%a1
	dbra	%d1,1b

	/*
	 * Finally, since we just allocated 4 page tables, make sure that
	 * the virtual mapping of the 4 page tables indicates
	 * noncachable or write-through.
	 */
	moveq	#3,%d0
1:	movel	%a2@,%d1	/* a2 already points to root table offset */
	andw	#_CACHEMASK040,%d1
	orw	%d6,%d1
	movel	%d1,%a2@+
	dbra	%d0,1b

Lnotatari:
#endif

/*
 * Setup a transparent mapping of the physical memory we are executing in.
 *
 * Only do this if the physical memory is not in the first 16M Meg, or not on
 * an Amiga since the first 16M is already identity mapped on the Amiga.
 */
Lmapphys:
	putc('J')

#ifdef CONFIG_AMIGA
	is_not_amiga(Lmapphysnotamiga)

/*
 * The virtual address of the start of the kernel is 0x1000. We transparently
 * translate the memory where we running in and can enable then the MMU. Hence
 * we have now two locations of the kernel in memory and can jump to the final
 * place. Except if the physical location is in the first 16MB, translation
 * will overlap later virtual location, but as we already mapped the first
 * 16MB to 0x80000000, we can jump there after translation and MMU is enabled
 * and then we can switch off translation and go to the final place.
 * When MMU is enabled, stack pointer and Lcustom will become again valid and
 * points to the unused first page.
 */

/*
 * Setup Supervisor Root Pointer register to point to page directory,
 * setup translation register contents and enable translation.
 */
	putc('K')

	movew	#PAGESIZE,%sp

	/* fixup the Amiga custom register location before printing */
	lea	%pc@(Lcustom),%a0
	movel	#0x80000000,%a0@

	is_040_or_060(Lamimmu68040)

	lea	2f:w,%a0
	movel	%d5,%d0
	andl	#0xff000000,%d0
	jne	1f
	lea	%pc@(2f+0x80000000),%a0
1:	orw	#TTR_ENABLE+TTR_CI+TTR_RWM+TTR_FCB2+TTR_FCM1+TTR_FCM0,%d0
	lea	%pc@(Lmmu),%a3
	movel	%d0,%a3@
	.long	0xf0130800	/* pmove %a3@,%tt0 */
	/* no limit, 4byte descriptors */
	movel	#0x80000002,%a3@
	movel	%a5,%a3@(4)
	.long	0xf0134800	/* pmove %a3@,%srp */
	.long	0xf0134c00	/* pmove %a3@,%crp */
	.long	0xf0002400	/* pflusha */
	/*
	 * enable,super root enable,4096 byte pages,7 bit root index,
	 * 7 bit pointer index, 6 bit page table index.
	 */
	movel	#0x82c07760,%a3@
	.long	0xf0134000	/* pmove %a3@,%tc (enable the MMU) */
	jmp	%a0@
2:	clrl	%a3@
	.long	0xf0130800	/* pmove %a3@,%tt0 */
	jmp	LdoneMMUenable:w

Lamimmu68040:

	lea	2f:w,%a0
	movel	%d5,%d0
	andl	#0xff000000,%d0
	jne	1f
	lea	%pc@(2f+0x80000000),%a0
1:	orw	#TTR_ENABLE+TTR_KERNELMODE+_PAGE_NOCACHE_S,%d0
	.long	0x4e7b0004	/* movec %d0,%itt0 */
	.long	0x4e7bd806	/* movec %a5,%urp */
	.long	0x4e7bd807	/* movec %a5,%srp */
	.word	0xf518		/* pflusha */
	movel	#TC_ENABLE+TC_PAGE4K,%d0
	/*
	 * this value is also ok for the 68060, we don`t use the cache
	 * mode/protection defaults
	 */
	.long	0x4e7b0003	/* movec %d0,%tc (enable the MMU) */
	jmp	%a0@
2:	moveq	#0,%d0
	.long	0x4e7b0004	/* movec %d0,%itt0 */
	jmp	LdoneMMUenable:w

Lmapphysnotamiga:
#endif

#ifdef CONFIG_ATARI
	is_not_atari(Lmapphysnotatari)

/*
 * If the kernel physical address is different from its virtual address, we
 * will temporarily set up an identity mapping of the 16MB chunk with
 * transparent translation where the kernel is executing.
 */
	putc('L')

	/* fixup the  Atari iobase register location before printing */
	lea	%pc@(Liobase),%a0
	movel	#0xff000000,%a0@

	is_040_or_060(Latarimmu68040)

	lea	%pc@(Lmmu),%a3
	movel	%d5,%d0
	jne	1f
	lea	LdoneMMUenable:w,%a0
	jra	3f
1:	lea	4f:w,%a0
	andl	#0xff000000,%d0 /* logical address base */
	jeq	2f
	orw	#TTR_ENABLE+TTR_CI+TTR_RWM+TTR_FCB2+TTR_FCM1+TTR_FCM0,%d0
	movel	%d0,%a3@
	.long	0xf0130800	/* pmove %a3@,%tt0 */
	jra	3f
	/* tt0 doesn't work if physical and virtual address of kernel is in
	 * the same 16M area (Falcon with Magnum/FX, kernel in alternate ram)
	 * Transparent translation through kernel pointer table
	 * Requires that this code until after MMU enabling lies in
	 * the 256K page around %d5
	 */
2:	movel	%a4@,%d1
	andw	#0xfff0,%d1
	movel	%d1,%a1
	movel	%d5,%d1
	moveq	#PTR_INDEX_SHIFT,%d0
	lsrl	%d0,%d1
	lea	%a1@(%d1:l:4),%a1
	movel	%d5,%d1
	addql	#_PAGE_PRESENT,%d1
	movel	%a1@,%d2
	movel	%d1,%a1@
	lea	5f:w,%a0
	/* no limit, 4byte descriptors */
3:	movel	#0x80000002,%a3@
	movel	%a5,%a3@(4)
	.long	0xf0134800	/* pmove %a3@,%srp */
	.long	0xf0134c00	/* pmove %a3@,%crp */
	.long	0xf0002400	/* pflusha */
	/*
	 * enable,super root enable,4096 byte pages,7 bit root index,
	 * 7 bit pointer index, 6 bit page table index.
	 */
	movel	#0x82c07760,%a3@
	.long	0xf0134000	/* pmove %a3@,%tc (enable the MMU) */
	jmp	%a0@
4:	clrl	%a3@
	.long	0xf0130800	/* pmove %a3@,%tt0 */
	jra	LdoneMMUenable
5:	movel	%d2,%a1@
	jra	LdoneMMUenable

Latarimmu68040:
	movel	%d5,%d0
	jne	1f
	lea	LdoneMMUenable:w,%a0
	jra	2f
1:	lea	3f:w,%a0
	andl	#0xff000000,%d0 /* logical address base */
	orw	#TTR_ENABLE+TTR_KERNELMODE+_PAGE_NOCACHE_S,%d0
	.long	0x4e7b0004	/* movec %d0,%itt0 */
2:	.word	0xf518		/* pflusha */
	.long	0x4e7bd807	/* movec %a5,%srp */
	.long	0x4e7bd806	/* movec %a5,%urp */
	movel	#TC_ENABLE+TC_PAGE4K,%d0
	/*
	 * this value is also ok for the 68060, we don`t use the cache
	 * mode/protection defaults
	 */
	.long	0x4e7b0003	/* movec %d0,%tc (enable the MMU) */
	jmp	%a0@
3:	moveq	#0,%d0
	.long	0x4e7b0004	/* movec %d0,%itt0 */
	tstl	%a1
	jra	LdoneMMUenable

Lmapphysnotatari:
#endif

LdoneMMUenable:

/*
 * Fixup the addresses for the kernel pointer table and availmem.
 * Convert them from physical addresses to virtual addresses.
 */

	putc('M')

	/*
	 * d5 contains physaddr of kernel start
	 */
	subl	%d5,SYMBOL_NAME(kpt)

	/*
	 * do the same conversion on the first available memory
	 * address (in a6).
	 */
	subl	%d5,%a6
	movel	%a6,SYMBOL_NAME(availmem) /* first available memory address */

	putc('N')

#if 0
	putr()
	lea	SYMBOL_NAME(kernel_pmd_table),%a0
	moveq	#63,%d0
1:	moveq	#7,%d1
	putn(%a0)
	putc(':')
	putc(' ')
2:	putn(%a0@+)
	dbra	%d1,2b
	putr()
	dbra	%d0,1b
	putr()
	movel	SYMBOL_NAME(kpt),%a0
	moveq	#639,%d0
1:	moveq	#7,%d1
	putn(%a0)
	putc(':')
	putc(' ')
2:	putn(%a0@+)
	dbra	%d1,2b
	putr()
	dbra	%d0,1b
#endif
/*
 * Enable caches
 */
	is_040_or_060(Lcache680460)

	movel	#CC3_ENABLE_DB+CC3_CLR_D+CC3_ENABLE_D+CC3_ENABLE_IB+CC3_CLR_I+CC3_ENABLE_I,%d0
	movec	%d0,%cacr
	jra	1f

Lcache680460:
	.word	0xf4f8		/* cpusha %bc */

	is_060(Lcache68060)

	movel	#CC6_ENABLE_D+CC6_ENABLE_I,%d0
	/* MMU stuff works in copyback mode now, so enable the cache */
	movec	%d0,%cacr
	jra	1f

Lcache68060:
	movel	#CC6_ENABLE_D+CC6_ENABLE_I+CC6_ENABLE_SB+CC6_PUSH_DPI+CC6_ENABLE_B+CC6_CLRA_B,%d0
	/* MMU stuff works in copyback mode now, so enable the cache */
	movec	%d0,%cacr
	/* enable superscalar dispatch in PCR */
	moveq	#1,%d0
	.long	0x4e7b0808	/* movec d0,pcr */
1:

/*
 * Setup initial stack pointer
 */
	lea	SYMBOL_NAME(init_user_stack)+PAGESIZE,%sp

/* jump to the kernel start */
	putr()

	jbsr	SYMBOL_NAME(start_kernel)

/*
 * switch off mmu and exit
 */

#ifdef HACKER_KERNEL
ENTRY(kernel_exit)
	lea	2f:w,%a0
	movel	%pc@(Lkernel_start),%a0
	lea	%a0@(2f:w),%a1
	movel	%a1,%d0
	andl	#0xff000000,%d0
	jne	1f
	jmp	%a0@(1f+0x80000000)
1:	orw	#TTR_ENABLE+TTR_KERNELMODE+_PAGE_NOCACHE_S,%d0
	.long	0x4e7b0004	/* movec %d0,%itt0 */
	jmp	%a1@
2:	moveq	#0,%d0
	.long	0x4e7b0003	/* movec %d0,%tc (disable the MMU) */
	.word	0xf518		/* pflusha */
	.long	0x4e7b0004	/* movec %d0,%itt0 */
	movec	%d0,%cacr
	.word	0xf4f8		/* cpusha %bc */

	lea	%pc@(SYMBOL_NAME(boot_info)),%a0
	jmp	%a0@(BI_amiga_exit_func:w)@(0:w)
#endif

/*
 * Serial port output support.
 */
LSERPER      = 0xdff032
LSERDAT      = 0xdff030
LSERDATR     = 0xdff018
LNTSC_PERIOD = 371
LPAL_PERIOD  = 368
LNTSC_ECLOCK = 7159090
LSERIAL_CNTRL = 0xbfd000
LSERIAL_DTR   = 7

/*
 * Debug output support
 * Atarians have a choice between the parallel port, the serial port
 * from the MFP or a serial port of the SCC
 */

#ifdef CONFIG_ATARI
/* #define USE_PRINTER */
/* #define USE_SCC */
#define USE_MFP

#ifdef USE_PRINTER

LPSG_SELECT	= 0xff8800
LPSG_READ	= 0xff8800
LPSG_WRITE	= 0xff8802
LPSG_IO_A	= 14
LPSG_IO_B	= 15
LPSG_CONTROL	= 7
LSTMFP_GPIP	= 0xfffa01
LSTMFP_DDR	= 0xfffa05
LSTMFP_IERB	= 0xfffa09

#elif defined(USE_SCC)
 
LSCC_CTRL_B	= 0xff8c85
LSCC_DATA_B	= 0xff8c87

/* Initialisation table for SCC */
scc_initable:
	.byte	9,12		/* Reset */
	.byte	4,0x44		/* x16, 1 stopbit, no parity */
	.byte	3,0xc0		/* receiver: 8 bpc */
	.byte	5,0xe2		/* transmitter: 8 bpc, assert dtr/rts */
	.byte	9,0		/* no interrupts */
	.byte	10,0		/* NRZ */
	.byte	11,0x50		/* use baud rate generator */
	.byte	12,24,13,0	/* 9600 baud */
	.byte	14,2,14,3	/* use master clock for BRG, enable */
	.byte	3,0xc1		/* enable receiver */
	.byte	5,0xea		/* enable transmitter */
	.byte	-1
	.even

#elif defined(USE_MFP)

LMFP_UCR     = 0xfffa29
LMFP_TDCDR   = 0xfffa1d
LMFP_TDDR    = 0xfffa25
LMFP_TSR     = 0xfffa2d
LMFP_UDR     = 0xfffa2f

#endif
#endif

/*
 * Initialize serial port hardware for 9600/8/1
 * a0 thrashed
 * Atari d0 trashed (a1 in case of SCC)
 */
	.even
Lserial_init:
#ifdef CONFIG_AMIGA
	cmpil	#MACH_AMIGA,%d4
	jne	1f
	lea	%pc@(SYMBOL_NAME(boot_info)),%a0
	bclr	#LSERIAL_DTR,LSERIAL_CNTRL
	movew	#LNTSC_PERIOD,LSERPER
	cmpl	#LNTSC_ECLOCK,%a0@(BI_amiga_eclock)
	jeq	9f
	movew	#LPAL_PERIOD,LSERPER
	jra	9f
1:
#endif
#ifdef CONFIG_ATARI
	cmpil   #MACH_ATARI,%d4
	jne	4f
#ifdef USE_PRINTER
	bclr	#0,LSTMFP_IERB
	bclr	#0,LSTMFP_DDR
	moveb	#LPSG_CONTROL,LPSG_SELECT
	moveb	#0xff,LPSG_WRITE
	moveb	#LPSG_IO_B,LPSG_SELECT
	clrb	LPSG_WRITE
	moveb	#LPSG_IO_A,LPSG_SELECT
	moveb	LPSG_READ,%d0
	bset	#5,%d0
	moveb	%d0,LPSG_WRITE
#elif defined(USE_SCC)
	lea	LSCC_CTRL_B,%a0
	lea	%pc@(scc_initable:w),%a1
2:	moveb	%a1@+,%d0
	jmi	3f
	moveb	%d0,%a0@
	moveb	%a1@+,%a0@
	jra	2b
3:	clrb	%a0@
#elif defined(USE_MFP)
	bclr	#1,LMFP_TSR
	moveb   #0x88,LMFP_UCR
	andb	#0x70,LMFP_TDCDR
	moveb   #2,LMFP_TDDR
	orb	#1,LMFP_TDCDR
	bset	#1,LMFP_TSR
#endif
4:
#endif
9:
	rts

/*
 * Output character in d7 on serial port.
 * d7 thrashed.
 */
Lserial_putc:
	moveml	%a0/%a1,%sp@-
#ifdef CONFIG_AMIGA
	cmpil	#MACH_AMIGA,%d4
	jne	2f
	andw	#0x00ff,%d7
	oriw	#0x0100,%d7
	movel	%pc@(Lcustom),%a1
	movew	%d7,%a1@(LSERDAT)
1:	movew	%a1@(LSERDATR),%d7
	andw	#0x2000,%d7
	jeq	1b
	jra	9f
2:
#endif
#ifdef CONFIG_ATARI
	cmpil   #MACH_ATARI,%d4
	jne	4f
	movel	%pc@(Liobase),%a1
#ifdef USE_PRINTER
3:	btst	#0,%a1@(LSTMFP_GPIP)
	jne	3b
	moveb	#LPSG_IO_B,%a1@(LPSG_SELECT)
	moveb	%d7,%a1@(LPSG_WRITE)
	moveb	#LPSG_IO_A,%a1@(LPSG_SELECT)
	moveb	%a1@(LPSG_READ),%d7
	bclr	#5,%d7
	moveb	%d7,%a1@(LPSG_WRITE)
	nop
	nop
	bset	#5,%d7
	moveb	%d7,%a1@(LPSG_WRITE)
#elif defined(USE_SCC)
3:	btst	#2,%a1@(LSCC_CTRL_B)
	jeq	3b
	moveb	%d7,%a1@(LSCC_DATA_B)
#elif defined(USE_MFP)
3:	btst	#7,%a1@(LMFP_TSR)
	jeq	3b
	moveb	%d7,%a1@(LMFP_UDR)
#endif
4:
#endif
9:
	moveml	%sp@+,%a0/%a1
	rts

/*
 * Output string pointed to by a0 to serial port.
 * a0 trashed.
 */
Lserial_puts:
	movel	%d7,%sp@-
1:	moveb	%a0@+,%d7
	jeq	2f
	jbsr	Lserial_putc
	jra	1b
2:	movel	%sp@+,%d7
	rts

/*
 * Output number in d7 in hex notation on serial port.
 * d0-d2 trashed.
 * d7 trashed.
 */

Lserial_putnum:
	moveml	%d0-%d2/%d7,%sp@-
	movel	%d7,%d1
	moveq	#4,%d0
	moveq	#7,%d2
L1:	roll	%d0,%d1
	moveb	%d1,%d7
	andb	#0x0f,%d7
	cmpb	#0x0a,%d7
	jcc	1f
	addb	#'0',%d7
	jra	2f
1:	addb	#'A'-10,%d7
2:	jbsr	Lserial_putc
	dbra	%d2,L1
	moveq	#32,%d7
	jbsr	Lserial_putc
	moveml	%sp@+,%d0-%d2/%d7
	rts

Lshowtest:
	moveml	%a0/%d7,%sp@-
	putc('A')
	putc('=')
	putn(%a1)

	ptestr	#5,%a1@,#7,%a0

	putc('D')
	putc('A')
	putc('=')
	putn(%a0)

	putc('D')
	putc('=')
	putn(%a0@)

	putc('S')
	putc('=')
	lea	%pc@(Lmmu),%a0
	pmove	%psr,%a0@
	clrl	%d7
	movew	%a0@,%d7
	jbsr	Lserial_putnum

	putr()
	moveml	%sp@+,%a0/%d7
	rts

	.data
	.even
#ifdef HACKER_KERNEL
Lkernel_start:
	.long 0
#endif
Lcustom:
Liobase:
	.long 0
Lmmu:	.quad 0
SYMBOL_NAME_LABEL(kpt)
	.long 0
SYMBOL_NAME_LABEL(availmem)
	.long 0
SYMBOL_NAME_LABEL(is_medusa)
	.long 0
SYMBOL_NAME_LABEL(m68k_pgtable_cachemode)
	.long 0
