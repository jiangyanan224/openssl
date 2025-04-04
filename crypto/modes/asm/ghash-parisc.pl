#! /usr/bin/env perl
# Copyright 2010-2020 The OpenSSL Project Authors. All Rights Reserved.
#
# Licensed under the Apache License 2.0 (the "License").  You may not use
# this file except in compliance with the License.  You can obtain a copy
# in the file LICENSE in the source distribution or at
# https://www.openssl.org/source/license.html

#
# ====================================================================
# Written by Andy Polyakov, @dot-asm, initially for use in the OpenSSL
# project. The module is, however, dual licensed under OpenSSL and
# CRYPTOGAMS licenses depending on where you obtain it. For further
# details see https://github.com/dot-asm/cryptogams/.
# ====================================================================
#
# April 2010
#
# The module implements "4-bit" GCM GHASH function and underlying
# single multiplication operation in GF(2^128). "4-bit" means that it
# uses 256 bytes per-key table [+128 bytes shared table]. On PA-7100LC
# it processes one byte in 19.6 cycles, which is more than twice as
# fast as code generated by gcc 3.2. PA-RISC 2.0 loop is scheduled for
# 8 cycles, but measured performance on PA-8600 system is ~9 cycles per
# processed byte. This is ~2.2x faster than 64-bit code generated by
# vendor compiler (which used to be very hard to beat:-).
#
# Special thanks to polarhome.com for providing HP-UX account.

# $output is the last argument if it looks like a file (it has an extension)
# $flavour is the first argument if it doesn't look like a file
$output = $#ARGV >= 0 && $ARGV[$#ARGV] =~ m|\.\w+$| ? pop : undef;
$flavour = $#ARGV >= 0 && $ARGV[0] !~ m|\.| ? shift : undef;

$output and open STDOUT,">$output";

if ($flavour =~ /64/) {
	$LEVEL		="2.0W";
	$SIZE_T		=8;
	$FRAME_MARKER	=80;
	$SAVED_RP	=16;
	$PUSH		="std";
	$PUSHMA		="std,ma";
	$POP		="ldd";
	$POPMB		="ldd,mb";
	$NREGS		=6;
} else {
	$LEVEL		="1.0";	#"\n\t.ALLOW\t2.0";
	$SIZE_T		=4;
	$FRAME_MARKER	=48;
	$SAVED_RP	=20;
	$PUSH		="stw";
	$PUSHMA		="stwm";
	$POP		="ldw";
	$POPMB		="ldwm";
	$NREGS		=11;
}

$FRAME=10*$SIZE_T+$FRAME_MARKER;# NREGS saved regs + frame marker
				#                 [+ argument transfer]

################# volatile registers
$Xi="%r26";	# argument block
$Htbl="%r25";
$inp="%r24";
$len="%r23";
$Hhh=$Htbl;	# variables
$Hll="%r22";
$Zhh="%r21";
$Zll="%r20";
$cnt="%r19";
$rem_4bit="%r28";
$rem="%r29";
$mask0xf0="%r31";

################# preserved registers
$Thh="%r1";
$Tll="%r2";
$nlo="%r3";
$nhi="%r4";
$byte="%r5";
if ($SIZE_T==4) {
	$Zhl="%r6";
	$Zlh="%r7";
	$Hhl="%r8";
	$Hlh="%r9";
	$Thl="%r10";
	$Tlh="%r11";
}
$rem2="%r6";	# used in PA-RISC 2.0 code

$code.=<<___;
	.LEVEL	$LEVEL
	.SPACE	\$TEXT\$
	.SUBSPA	\$CODE\$,QUAD=0,ALIGN=8,ACCESS=0x2C,CODE_ONLY

	.EXPORT	gcm_gmult_4bit,ENTRY,ARGW0=GR,ARGW1=GR
	.ALIGN	64
gcm_gmult_4bit
	.PROC
	.CALLINFO	FRAME=`$FRAME-10*$SIZE_T`,NO_CALLS,SAVE_RP,ENTRY_GR=$NREGS
	.ENTRY
	$PUSH	%r2,-$SAVED_RP(%sp)	; standard prologue
	$PUSHMA	%r3,$FRAME(%sp)
	$PUSH	%r4,`-$FRAME+1*$SIZE_T`(%sp)
	$PUSH	%r5,`-$FRAME+2*$SIZE_T`(%sp)
	$PUSH	%r6,`-$FRAME+3*$SIZE_T`(%sp)
___
$code.=<<___ if ($SIZE_T==4);
	$PUSH	%r7,`-$FRAME+4*$SIZE_T`(%sp)
	$PUSH	%r8,`-$FRAME+5*$SIZE_T`(%sp)
	$PUSH	%r9,`-$FRAME+6*$SIZE_T`(%sp)
	$PUSH	%r10,`-$FRAME+7*$SIZE_T`(%sp)
	$PUSH	%r11,`-$FRAME+8*$SIZE_T`(%sp)
___
$code.=<<___;
	blr	%r0,$rem_4bit
	ldi	3,$rem
L\$pic_gmult
	andcm	$rem_4bit,$rem,$rem_4bit
	addl	$inp,$len,$len
	ldo	L\$rem_4bit-L\$pic_gmult($rem_4bit),$rem_4bit
	ldi	0xf0,$mask0xf0
___
$code.=<<___ if ($SIZE_T==4);
	ldi	31,$rem
	mtctl	$rem,%cr11
	extrd,u,*= $rem,%sar,1,$rem	; executes on PA-RISC 1.0
	b	L\$parisc1_gmult
	nop
___

$code.=<<___;
	ldb	15($Xi),$nlo
	ldo	8($Htbl),$Hll

	and	$mask0xf0,$nlo,$nhi
	depd,z	$nlo,59,4,$nlo

	ldd	$nlo($Hll),$Zll
	ldd	$nlo($Hhh),$Zhh

	depd,z	$Zll,60,4,$rem
	shrpd	$Zhh,$Zll,4,$Zll
	extrd,u	$Zhh,59,60,$Zhh
	ldb	14($Xi),$nlo

	ldd	$nhi($Hll),$Tll
	ldd	$nhi($Hhh),$Thh
	and	$mask0xf0,$nlo,$nhi
	depd,z	$nlo,59,4,$nlo

	xor	$Tll,$Zll,$Zll
	xor	$Thh,$Zhh,$Zhh
	ldd	$rem($rem_4bit),$rem
	b	L\$oop_gmult_pa2
	ldi	13,$cnt

	.ALIGN	8
L\$oop_gmult_pa2
	xor	$rem,$Zhh,$Zhh		; moved here to work around gas bug
	depd,z	$Zll,60,4,$rem

	shrpd	$Zhh,$Zll,4,$Zll
	extrd,u	$Zhh,59,60,$Zhh
	ldd	$nlo($Hll),$Tll
	ldd	$nlo($Hhh),$Thh

	xor	$Tll,$Zll,$Zll
	xor	$Thh,$Zhh,$Zhh
	ldd	$rem($rem_4bit),$rem

	xor	$rem,$Zhh,$Zhh
	depd,z	$Zll,60,4,$rem
	ldbx	$cnt($Xi),$nlo

	shrpd	$Zhh,$Zll,4,$Zll
	extrd,u	$Zhh,59,60,$Zhh
	ldd	$nhi($Hll),$Tll
	ldd	$nhi($Hhh),$Thh

	and	$mask0xf0,$nlo,$nhi
	depd,z	$nlo,59,4,$nlo
	ldd	$rem($rem_4bit),$rem

	xor	$Tll,$Zll,$Zll
	addib,uv -1,$cnt,L\$oop_gmult_pa2
	xor	$Thh,$Zhh,$Zhh

	xor	$rem,$Zhh,$Zhh
	depd,z	$Zll,60,4,$rem

	shrpd	$Zhh,$Zll,4,$Zll
	extrd,u	$Zhh,59,60,$Zhh
	ldd	$nlo($Hll),$Tll
	ldd	$nlo($Hhh),$Thh

	xor	$Tll,$Zll,$Zll
	xor	$Thh,$Zhh,$Zhh
	ldd	$rem($rem_4bit),$rem

	xor	$rem,$Zhh,$Zhh
	depd,z	$Zll,60,4,$rem

	shrpd	$Zhh,$Zll,4,$Zll
	extrd,u	$Zhh,59,60,$Zhh
	ldd	$nhi($Hll),$Tll
	ldd	$nhi($Hhh),$Thh

	xor	$Tll,$Zll,$Zll
	xor	$Thh,$Zhh,$Zhh
	ldd	$rem($rem_4bit),$rem

	xor	$rem,$Zhh,$Zhh
	std	$Zll,8($Xi)
	std	$Zhh,0($Xi)
___

$code.=<<___ if ($SIZE_T==4);
	b	L\$done_gmult
	nop

L\$parisc1_gmult
	ldb	15($Xi),$nlo
	ldo	12($Htbl),$Hll
	ldo	8($Htbl),$Hlh
	ldo	4($Htbl),$Hhl

	and	$mask0xf0,$nlo,$nhi
	zdep	$nlo,27,4,$nlo

	ldwx	$nlo($Hll),$Zll
	ldwx	$nlo($Hlh),$Zlh
	ldwx	$nlo($Hhl),$Zhl
	ldwx	$nlo($Hhh),$Zhh
	zdep	$Zll,28,4,$rem
	ldb	14($Xi),$nlo
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zlh,$Zll,4,$Zll
	ldwx	$nhi($Hll),$Tll
	shrpw	$Zhl,$Zlh,4,$Zlh
	ldwx	$nhi($Hlh),$Tlh
	shrpw	$Zhh,$Zhl,4,$Zhl
	ldwx	$nhi($Hhl),$Thl
	extru	$Zhh,27,28,$Zhh
	ldwx	$nhi($Hhh),$Thh
	xor	$rem,$Zhh,$Zhh
	and	$mask0xf0,$nlo,$nhi
	zdep	$nlo,27,4,$nlo

	xor	$Tll,$Zll,$Zll
	ldwx	$nlo($Hll),$Tll
	xor	$Tlh,$Zlh,$Zlh
	ldwx	$nlo($Hlh),$Tlh
	xor	$Thl,$Zhl,$Zhl
	b	L\$oop_gmult_pa1
	ldi	13,$cnt

	.ALIGN	8
L\$oop_gmult_pa1
	zdep	$Zll,28,4,$rem
	ldwx	$nlo($Hhl),$Thl
	xor	$Thh,$Zhh,$Zhh
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zlh,$Zll,4,$Zll
	ldwx	$nlo($Hhh),$Thh
	shrpw	$Zhl,$Zlh,4,$Zlh
	ldbx	$cnt($Xi),$nlo
	xor	$Tll,$Zll,$Zll
	ldwx	$nhi($Hll),$Tll
	shrpw	$Zhh,$Zhl,4,$Zhl
	xor	$Tlh,$Zlh,$Zlh
	ldwx	$nhi($Hlh),$Tlh
	extru	$Zhh,27,28,$Zhh
	xor	$Thl,$Zhl,$Zhl
	ldwx	$nhi($Hhl),$Thl
	xor	$rem,$Zhh,$Zhh
	zdep	$Zll,28,4,$rem
	xor	$Thh,$Zhh,$Zhh
	ldwx	$nhi($Hhh),$Thh
	shrpw	$Zlh,$Zll,4,$Zll
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zhl,$Zlh,4,$Zlh
	shrpw	$Zhh,$Zhl,4,$Zhl
	and	$mask0xf0,$nlo,$nhi
	extru	$Zhh,27,28,$Zhh
	zdep	$nlo,27,4,$nlo
	xor	$Tll,$Zll,$Zll
	ldwx	$nlo($Hll),$Tll
	xor	$Tlh,$Zlh,$Zlh
	ldwx	$nlo($Hlh),$Tlh
	xor	$rem,$Zhh,$Zhh
	addib,uv -1,$cnt,L\$oop_gmult_pa1
	xor	$Thl,$Zhl,$Zhl

	zdep	$Zll,28,4,$rem
	ldwx	$nlo($Hhl),$Thl
	xor	$Thh,$Zhh,$Zhh
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zlh,$Zll,4,$Zll
	ldwx	$nlo($Hhh),$Thh
	shrpw	$Zhl,$Zlh,4,$Zlh
	xor	$Tll,$Zll,$Zll
	ldwx	$nhi($Hll),$Tll
	shrpw	$Zhh,$Zhl,4,$Zhl
	xor	$Tlh,$Zlh,$Zlh
	ldwx	$nhi($Hlh),$Tlh
	extru	$Zhh,27,28,$Zhh
	xor	$rem,$Zhh,$Zhh
	xor	$Thl,$Zhl,$Zhl
	ldwx	$nhi($Hhl),$Thl
	xor	$Thh,$Zhh,$Zhh
	ldwx	$nhi($Hhh),$Thh
	zdep	$Zll,28,4,$rem
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zlh,$Zll,4,$Zll
	shrpw	$Zhl,$Zlh,4,$Zlh
	shrpw	$Zhh,$Zhl,4,$Zhl
	extru	$Zhh,27,28,$Zhh
	xor	$Tll,$Zll,$Zll
	xor	$Tlh,$Zlh,$Zlh
	xor	$rem,$Zhh,$Zhh
	stw	$Zll,12($Xi)
	xor	$Thl,$Zhl,$Zhl
	stw	$Zlh,8($Xi)
	xor	$Thh,$Zhh,$Zhh
	stw	$Zhl,4($Xi)
	stw	$Zhh,0($Xi)
___
$code.=<<___;
L\$done_gmult
	$POP	`-$FRAME-$SAVED_RP`(%sp),%r2		; standard epilogue
	$POP	`-$FRAME+1*$SIZE_T`(%sp),%r4
	$POP	`-$FRAME+2*$SIZE_T`(%sp),%r5
	$POP	`-$FRAME+3*$SIZE_T`(%sp),%r6
___
$code.=<<___ if ($SIZE_T==4);
	$POP	`-$FRAME+4*$SIZE_T`(%sp),%r7
	$POP	`-$FRAME+5*$SIZE_T`(%sp),%r8
	$POP	`-$FRAME+6*$SIZE_T`(%sp),%r9
	$POP	`-$FRAME+7*$SIZE_T`(%sp),%r10
	$POP	`-$FRAME+8*$SIZE_T`(%sp),%r11
___
$code.=<<___;
	bv	(%r2)
	.EXIT
	$POPMB	-$FRAME(%sp),%r3
	.PROCEND

	.EXPORT	gcm_ghash_4bit,ENTRY,ARGW0=GR,ARGW1=GR,ARGW2=GR,ARGW3=GR
	.ALIGN	64
gcm_ghash_4bit
	.PROC
	.CALLINFO	FRAME=`$FRAME-10*$SIZE_T`,NO_CALLS,SAVE_RP,ENTRY_GR=11
	.ENTRY
	$PUSH	%r2,-$SAVED_RP(%sp)	; standard prologue
	$PUSHMA	%r3,$FRAME(%sp)
	$PUSH	%r4,`-$FRAME+1*$SIZE_T`(%sp)
	$PUSH	%r5,`-$FRAME+2*$SIZE_T`(%sp)
	$PUSH	%r6,`-$FRAME+3*$SIZE_T`(%sp)
___
$code.=<<___ if ($SIZE_T==4);
	$PUSH	%r7,`-$FRAME+4*$SIZE_T`(%sp)
	$PUSH	%r8,`-$FRAME+5*$SIZE_T`(%sp)
	$PUSH	%r9,`-$FRAME+6*$SIZE_T`(%sp)
	$PUSH	%r10,`-$FRAME+7*$SIZE_T`(%sp)
	$PUSH	%r11,`-$FRAME+8*$SIZE_T`(%sp)
___
$code.=<<___;
	blr	%r0,$rem_4bit
	ldi	3,$rem
L\$pic_ghash
	andcm	$rem_4bit,$rem,$rem_4bit
	addl	$inp,$len,$len
	ldo	L\$rem_4bit-L\$pic_ghash($rem_4bit),$rem_4bit
	ldi	0xf0,$mask0xf0
___
$code.=<<___ if ($SIZE_T==4);
	ldi	31,$rem
	mtctl	$rem,%cr11
	extrd,u,*= $rem,%sar,1,$rem	; executes on PA-RISC 1.0
	b	L\$parisc1_ghash
	nop
___

$code.=<<___;
	ldb	15($Xi),$nlo
	ldo	8($Htbl),$Hll

L\$outer_ghash_pa2
	ldb	15($inp),$nhi
	xor	$nhi,$nlo,$nlo
	and	$mask0xf0,$nlo,$nhi
	depd,z	$nlo,59,4,$nlo

	ldd	$nlo($Hll),$Zll
	ldd	$nlo($Hhh),$Zhh

	depd,z	$Zll,60,4,$rem
	shrpd	$Zhh,$Zll,4,$Zll
	extrd,u	$Zhh,59,60,$Zhh
	ldb	14($Xi),$nlo
	ldb	14($inp),$byte

	ldd	$nhi($Hll),$Tll
	ldd	$nhi($Hhh),$Thh
	xor	$byte,$nlo,$nlo
	and	$mask0xf0,$nlo,$nhi
	depd,z	$nlo,59,4,$nlo

	xor	$Tll,$Zll,$Zll
	xor	$Thh,$Zhh,$Zhh
	ldd	$rem($rem_4bit),$rem
	b	L\$oop_ghash_pa2
	ldi	13,$cnt

	.ALIGN	8
L\$oop_ghash_pa2
	xor	$rem,$Zhh,$Zhh		; moved here to work around gas bug
	depd,z	$Zll,60,4,$rem2

	shrpd	$Zhh,$Zll,4,$Zll
	extrd,u	$Zhh,59,60,$Zhh
	ldd	$nlo($Hll),$Tll
	ldd	$nlo($Hhh),$Thh

	xor	$Tll,$Zll,$Zll
	xor	$Thh,$Zhh,$Zhh
	ldbx	$cnt($Xi),$nlo
	ldbx	$cnt($inp),$byte

	depd,z	$Zll,60,4,$rem
	shrpd	$Zhh,$Zll,4,$Zll
	ldd	$rem2($rem_4bit),$rem2

	xor	$rem2,$Zhh,$Zhh
	xor	$byte,$nlo,$nlo
	ldd	$nhi($Hll),$Tll
	ldd	$nhi($Hhh),$Thh

	and	$mask0xf0,$nlo,$nhi
	depd,z	$nlo,59,4,$nlo

	extrd,u	$Zhh,59,60,$Zhh
	xor	$Tll,$Zll,$Zll

	ldd	$rem($rem_4bit),$rem
	addib,uv -1,$cnt,L\$oop_ghash_pa2
	xor	$Thh,$Zhh,$Zhh

	xor	$rem,$Zhh,$Zhh
	depd,z	$Zll,60,4,$rem2

	shrpd	$Zhh,$Zll,4,$Zll
	extrd,u	$Zhh,59,60,$Zhh
	ldd	$nlo($Hll),$Tll
	ldd	$nlo($Hhh),$Thh

	xor	$Tll,$Zll,$Zll
	xor	$Thh,$Zhh,$Zhh

	depd,z	$Zll,60,4,$rem
	shrpd	$Zhh,$Zll,4,$Zll
	ldd	$rem2($rem_4bit),$rem2

	xor	$rem2,$Zhh,$Zhh
	ldd	$nhi($Hll),$Tll
	ldd	$nhi($Hhh),$Thh

	extrd,u	$Zhh,59,60,$Zhh
	xor	$Tll,$Zll,$Zll
	xor	$Thh,$Zhh,$Zhh
	ldd	$rem($rem_4bit),$rem

	xor	$rem,$Zhh,$Zhh
	std	$Zll,8($Xi)
	ldo	16($inp),$inp
	std	$Zhh,0($Xi)
	cmpb,*<> $inp,$len,L\$outer_ghash_pa2
	copy	$Zll,$nlo
___

$code.=<<___ if ($SIZE_T==4);
	b	L\$done_ghash
	nop

L\$parisc1_ghash
	ldb	15($Xi),$nlo
	ldo	12($Htbl),$Hll
	ldo	8($Htbl),$Hlh
	ldo	4($Htbl),$Hhl

L\$outer_ghash_pa1
	ldb	15($inp),$byte
	xor	$byte,$nlo,$nlo
	and	$mask0xf0,$nlo,$nhi
	zdep	$nlo,27,4,$nlo

	ldwx	$nlo($Hll),$Zll
	ldwx	$nlo($Hlh),$Zlh
	ldwx	$nlo($Hhl),$Zhl
	ldwx	$nlo($Hhh),$Zhh
	zdep	$Zll,28,4,$rem
	ldb	14($Xi),$nlo
	ldb	14($inp),$byte
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zlh,$Zll,4,$Zll
	ldwx	$nhi($Hll),$Tll
	shrpw	$Zhl,$Zlh,4,$Zlh
	ldwx	$nhi($Hlh),$Tlh
	shrpw	$Zhh,$Zhl,4,$Zhl
	ldwx	$nhi($Hhl),$Thl
	extru	$Zhh,27,28,$Zhh
	ldwx	$nhi($Hhh),$Thh
	xor	$byte,$nlo,$nlo
	xor	$rem,$Zhh,$Zhh
	and	$mask0xf0,$nlo,$nhi
	zdep	$nlo,27,4,$nlo

	xor	$Tll,$Zll,$Zll
	ldwx	$nlo($Hll),$Tll
	xor	$Tlh,$Zlh,$Zlh
	ldwx	$nlo($Hlh),$Tlh
	xor	$Thl,$Zhl,$Zhl
	b	L\$oop_ghash_pa1
	ldi	13,$cnt

	.ALIGN	8
L\$oop_ghash_pa1
	zdep	$Zll,28,4,$rem
	ldwx	$nlo($Hhl),$Thl
	xor	$Thh,$Zhh,$Zhh
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zlh,$Zll,4,$Zll
	ldwx	$nlo($Hhh),$Thh
	shrpw	$Zhl,$Zlh,4,$Zlh
	ldbx	$cnt($Xi),$nlo
	xor	$Tll,$Zll,$Zll
	ldwx	$nhi($Hll),$Tll
	shrpw	$Zhh,$Zhl,4,$Zhl
	ldbx	$cnt($inp),$byte
	xor	$Tlh,$Zlh,$Zlh
	ldwx	$nhi($Hlh),$Tlh
	extru	$Zhh,27,28,$Zhh
	xor	$Thl,$Zhl,$Zhl
	ldwx	$nhi($Hhl),$Thl
	xor	$rem,$Zhh,$Zhh
	zdep	$Zll,28,4,$rem
	xor	$Thh,$Zhh,$Zhh
	ldwx	$nhi($Hhh),$Thh
	shrpw	$Zlh,$Zll,4,$Zll
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zhl,$Zlh,4,$Zlh
	xor	$byte,$nlo,$nlo
	shrpw	$Zhh,$Zhl,4,$Zhl
	and	$mask0xf0,$nlo,$nhi
	extru	$Zhh,27,28,$Zhh
	zdep	$nlo,27,4,$nlo
	xor	$Tll,$Zll,$Zll
	ldwx	$nlo($Hll),$Tll
	xor	$Tlh,$Zlh,$Zlh
	ldwx	$nlo($Hlh),$Tlh
	xor	$rem,$Zhh,$Zhh
	addib,uv -1,$cnt,L\$oop_ghash_pa1
	xor	$Thl,$Zhl,$Zhl

	zdep	$Zll,28,4,$rem
	ldwx	$nlo($Hhl),$Thl
	xor	$Thh,$Zhh,$Zhh
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zlh,$Zll,4,$Zll
	ldwx	$nlo($Hhh),$Thh
	shrpw	$Zhl,$Zlh,4,$Zlh
	xor	$Tll,$Zll,$Zll
	ldwx	$nhi($Hll),$Tll
	shrpw	$Zhh,$Zhl,4,$Zhl
	xor	$Tlh,$Zlh,$Zlh
	ldwx	$nhi($Hlh),$Tlh
	extru	$Zhh,27,28,$Zhh
	xor	$rem,$Zhh,$Zhh
	xor	$Thl,$Zhl,$Zhl
	ldwx	$nhi($Hhl),$Thl
	xor	$Thh,$Zhh,$Zhh
	ldwx	$nhi($Hhh),$Thh
	zdep	$Zll,28,4,$rem
	ldwx	$rem($rem_4bit),$rem
	shrpw	$Zlh,$Zll,4,$Zll
	shrpw	$Zhl,$Zlh,4,$Zlh
	shrpw	$Zhh,$Zhl,4,$Zhl
	extru	$Zhh,27,28,$Zhh
	xor	$Tll,$Zll,$Zll
	xor	$Tlh,$Zlh,$Zlh
	xor	$rem,$Zhh,$Zhh
	stw	$Zll,12($Xi)
	xor	$Thl,$Zhl,$Zhl
	stw	$Zlh,8($Xi)
	xor	$Thh,$Zhh,$Zhh
	stw	$Zhl,4($Xi)
	ldo	16($inp),$inp
	stw	$Zhh,0($Xi)
	comb,<>	$inp,$len,L\$outer_ghash_pa1
	copy	$Zll,$nlo
___
$code.=<<___;
L\$done_ghash
	$POP	`-$FRAME-$SAVED_RP`(%sp),%r2		; standard epilogue
	$POP	`-$FRAME+1*$SIZE_T`(%sp),%r4
	$POP	`-$FRAME+2*$SIZE_T`(%sp),%r5
	$POP	`-$FRAME+3*$SIZE_T`(%sp),%r6
___
$code.=<<___ if ($SIZE_T==4);
	$POP	`-$FRAME+4*$SIZE_T`(%sp),%r7
	$POP	`-$FRAME+5*$SIZE_T`(%sp),%r8
	$POP	`-$FRAME+6*$SIZE_T`(%sp),%r9
	$POP	`-$FRAME+7*$SIZE_T`(%sp),%r10
	$POP	`-$FRAME+8*$SIZE_T`(%sp),%r11
___
$code.=<<___;
	bv	(%r2)
	.EXIT
	$POPMB	-$FRAME(%sp),%r3
	.PROCEND

	.ALIGN	64
L\$rem_4bit
	.WORD	`0x0000<<16`,0,`0x1C20<<16`,0,`0x3840<<16`,0,`0x2460<<16`,0
	.WORD	`0x7080<<16`,0,`0x6CA0<<16`,0,`0x48C0<<16`,0,`0x54E0<<16`,0
	.WORD	`0xE100<<16`,0,`0xFD20<<16`,0,`0xD940<<16`,0,`0xC560<<16`,0
	.WORD	`0x9180<<16`,0,`0x8DA0<<16`,0,`0xA9C0<<16`,0,`0xB5E0<<16`,0
	.STRINGZ "GHASH for PA-RISC, GRYPTOGAMS by <https://github.com/dot-asm>"
	.ALIGN	64
___

# Explicitly encode PA-RISC 2.0 instructions used in this module, so
# that it can be compiled with .LEVEL 1.0. It should be noted that I
# wouldn't have to do this, if GNU assembler understood .ALLOW 2.0
# directive...

my $ldd = sub {
  my ($mod,$args) = @_;
  my $orig = "ldd$mod\t$args";

    if ($args =~ /%r([0-9]+)\(%r([0-9]+)\),%r([0-9]+)/)		# format 4
    {	my $opcode=(0x03<<26)|($2<<21)|($1<<16)|(3<<6)|$3;
	sprintf "\t.WORD\t0x%08x\t; %s",$opcode,$orig;
    }
    elsif ($args =~ /(\-?[0-9]+)\(%r([0-9]+)\),%r([0-9]+)/)	# format 5
    {	my $opcode=(0x03<<26)|($2<<21)|(1<<12)|(3<<6)|$3;
	$opcode|=(($1&0xF)<<17)|(($1&0x10)<<12);		# encode offset
	$opcode|=(1<<5)  if ($mod =~ /^,m/);
	$opcode|=(1<<13) if ($mod =~ /^,mb/);
	sprintf "\t.WORD\t0x%08x\t; %s",$opcode,$orig;
    }
    else { "\t".$orig; }
};

my $std = sub {
  my ($mod,$args) = @_;
  my $orig = "std$mod\t$args";

    if ($args =~ /%r([0-9]+),(\-?[0-9]+)\(%r([0-9]+)\)/) # format 3 suffices
    {	my $opcode=(0x1c<<26)|($3<<21)|($1<<16)|(($2&0x1FF8)<<1)|(($2>>13)&1);
	sprintf "\t.WORD\t0x%08x\t; %s",$opcode,$orig;
    }
    else { "\t".$orig; }
};

my $extrd = sub {
  my ($mod,$args) = @_;
  my $orig = "extrd$mod\t$args";

    # I only have ",u" completer, it's implicitly encoded...
    if ($args =~ /%r([0-9]+),([0-9]+),([0-9]+),%r([0-9]+)/)	# format 15
    {	my $opcode=(0x36<<26)|($1<<21)|($4<<16);
	my $len=32-$3;
	$opcode |= (($2&0x20)<<6)|(($2&0x1f)<<5);		# encode pos
	$opcode |= (($len&0x20)<<7)|($len&0x1f);		# encode len
	sprintf "\t.WORD\t0x%08x\t; %s",$opcode,$orig;
    }
    elsif ($args =~ /%r([0-9]+),%sar,([0-9]+),%r([0-9]+)/)	# format 12
    {	my $opcode=(0x34<<26)|($1<<21)|($3<<16)|(2<<11)|(1<<9);
	my $len=32-$2;
	$opcode |= (($len&0x20)<<3)|($len&0x1f);		# encode len
	$opcode |= (1<<13) if ($mod =~ /,\**=/);
	sprintf "\t.WORD\t0x%08x\t; %s",$opcode,$orig;
    }
    else { "\t".$orig; }
};

my $shrpd = sub {
  my ($mod,$args) = @_;
  my $orig = "shrpd$mod\t$args";

    if ($args =~ /%r([0-9]+),%r([0-9]+),([0-9]+),%r([0-9]+)/)	# format 14
    {	my $opcode=(0x34<<26)|($2<<21)|($1<<16)|(1<<10)|$4;
	my $cpos=63-$3;
	$opcode |= (($cpos&0x20)<<6)|(($cpos&0x1f)<<5);		# encode sa
	sprintf "\t.WORD\t0x%08x\t; %s",$opcode,$orig;
    }
    elsif ($args =~ /%r([0-9]+),%r([0-9]+),%sar,%r([0-9]+)/)	# format 11
    {	sprintf "\t.WORD\t0x%08x\t; %s",
		(0x34<<26)|($2<<21)|($1<<16)|(1<<9)|$3,$orig;
    }
    else { "\t".$orig; }
};

my $depd = sub {
  my ($mod,$args) = @_;
  my $orig = "depd$mod\t$args";

    # I only have ",z" completer, it's implicitly encoded...
    if ($args =~ /%r([0-9]+),([0-9]+),([0-9]+),%r([0-9]+)/)	# format 16
    {	my $opcode=(0x3c<<26)|($4<<21)|($1<<16);
    	my $cpos=63-$2;
	my $len=32-$3;
	$opcode |= (($cpos&0x20)<<6)|(($cpos&0x1f)<<5);		# encode pos
	$opcode |= (($len&0x20)<<7)|($len&0x1f);		# encode len
	sprintf "\t.WORD\t0x%08x\t; %s",$opcode,$orig;
    }
    else { "\t".$orig; }
};

sub assemble {
  my ($mnemonic,$mod,$args)=@_;
  my $opcode = eval("\$$mnemonic");

    ref($opcode) eq 'CODE' ? &$opcode($mod,$args) : "\t$mnemonic$mod\t$args";
}

if (`$ENV{CC} -Wa,-v -c -o /dev/null -x assembler /dev/null 2>&1`
	=~ /GNU assembler/) {
    $gnuas = 1;
}

foreach (split("\n",$code)) {
	s/\`([^\`]*)\`/eval $1/ge;
	if ($SIZE_T==4) {
		s/^\s+([a-z]+)([\S]*)\s+([\S]*)/&assemble($1,$2,$3)/e;
		s/cmpb,\*/comb,/;
		s/,\*/,/;
	}

	s/(\.LEVEL\s+2\.0)W/$1w/	if ($gnuas && $SIZE_T==8);
	s/\.SPACE\s+\$TEXT\$/.text/	if ($gnuas && $SIZE_T==8);
	s/\.SUBSPA.*//			if ($gnuas && $SIZE_T==8);
	s/\bbv\b/bve/			if ($SIZE_T==8);

	print $_,"\n";
}

close STDOUT or die "error closing STDOUT: $!";
