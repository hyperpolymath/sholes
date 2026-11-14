-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| ABI Type Definitions
|||
||| This module defines the Application Binary Interface (ABI) for
||| libsholes. It is the Idris2 side of the seam whose Zig side is
||| src/interface/ffi/src/main.zig; tests/aspect_tests.sh (Aspect 3) checks
||| that the two name the same symbols, and `Result` below carries the same
||| integer codes as the Zig `Result` enum, in the same order.
|||
||| Typechecked under Idris2 0.7.0 (`idris2 --typecheck src/interface/abi.ipkg`)
||| and gated through verification/proofs/idris2/MANIFEST.

module Abi.Types

import Data.Bits
import Data.So
import Data.Vect
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- Platform Model
--------------------------------------------------------------------------------

||| Target platforms for the FFI bridge
public export
data Platform = Linux | MacOS | Windows | WASM | RISCV

||| Pointer size in bits per platform
public export
ptrSize : Platform -> Nat
ptrSize Linux = 64
ptrSize MacOS = 64
ptrSize Windows = 64
ptrSize WASM = 32
ptrSize RISCV = 64

||| Current target platform (detected at compile-time)
public export
thisPlatform : Platform
thisPlatform = Linux -- Simplified for template

--------------------------------------------------------------------------------
-- Core Types
--------------------------------------------------------------------------------

||| Return codes for FFI calls. One constructor per case of the Zig
||| `Result = enum(c_int)` in src/interface/ffi/src/main.zig, in its order:
||| ok = 0, error = 1, invalid_param = 2, out_of_memory = 3, null_pointer = 4.
public export
data Result = Ok | Error | InvalidParam | OutOfMemory | NullPointer

||| The C integer each constructor crosses the seam as. The Zig enum is
||| `enum(c_int)`, a 32-bit C `int`, so the code is 32 bits wide, not Idris's
||| 64-bit `Int`. It is `Bits32` rather than `Int32` because Idris2 0.7.0's
||| RefC backend rejects an `Int32` foreign return ('Unknonw FFI type in C
||| backend: Int_32'); `Bits32` builds and runs on Chez and RefC alike
||| (checked 2026-11-09). Every code here is non-negative, so the bit
||| pattern is the same; a negative C code reads as a large `Bits32` and
||| decodes to `Nothing`.
public export
resultCode : Result -> Bits32
resultCode Ok = 0
resultCode Error = 1
resultCode InvalidParam = 2
resultCode OutOfMemory = 3
resultCode NullPointer = 4

||| Decode a C integer from the seam. Anything outside the table is Nothing:
||| the caller decides what an unknown code means, never this module.
public export
fromCode : Bits32 -> Maybe Result
fromCode 0 = Just Ok
fromCode 1 = Just Error
fromCode 2 = Just InvalidParam
fromCode 3 = Just OutOfMemory
fromCode 4 = Just NullPointer
fromCode _ = Nothing

||| The code table round-trips: decoding what we encode gives back the
||| constructor. This is the Idris2 half of the seam's code table; the Zig
||| half is the enum literal, checked by name in tests/aspect_tests.sh.
export
fromCodeResultCode : (r : Result) -> fromCode (resultCode r) = Just r
fromCodeResultCode Ok = Refl
fromCodeResultCode Error = Refl
fromCodeResultCode InvalidParam = Refl
fromCodeResultCode OutOfMemory = Refl
fromCodeResultCode NullPointer = Refl

||| `Just` is injective (local, so the proof below needs no extra import).
justInjective : {0 x, y : a} -> Just x = Just y -> x = y
justInjective Refl = Refl

||| No two constructors share a code: the table is injective. Derived from the
||| round trip alone, so it needs no reasoning about primitive integers.
export
resultCodeInjective : (a, b : Result) -> resultCode a = resultCode b -> a = b
resultCodeInjective a b prf =
  justInjective (trans (sym (fromCodeResultCode a))
                       (trans (cong fromCode prf) (fromCodeResultCode b)))

||| Results are decidably equal (table generated, one clause per pair)
public export
implementation DecEq Result where
  decEq Ok Ok = Yes Refl
  decEq Ok Error = No (\case Refl impossible)
  decEq Ok InvalidParam = No (\case Refl impossible)
  decEq Ok OutOfMemory = No (\case Refl impossible)
  decEq Ok NullPointer = No (\case Refl impossible)
  decEq Error Ok = No (\case Refl impossible)
  decEq Error Error = Yes Refl
  decEq Error InvalidParam = No (\case Refl impossible)
  decEq Error OutOfMemory = No (\case Refl impossible)
  decEq Error NullPointer = No (\case Refl impossible)
  decEq InvalidParam Ok = No (\case Refl impossible)
  decEq InvalidParam Error = No (\case Refl impossible)
  decEq InvalidParam InvalidParam = Yes Refl
  decEq InvalidParam OutOfMemory = No (\case Refl impossible)
  decEq InvalidParam NullPointer = No (\case Refl impossible)
  decEq OutOfMemory Ok = No (\case Refl impossible)
  decEq OutOfMemory Error = No (\case Refl impossible)
  decEq OutOfMemory InvalidParam = No (\case Refl impossible)
  decEq OutOfMemory OutOfMemory = Yes Refl
  decEq OutOfMemory NullPointer = No (\case Refl impossible)
  decEq NullPointer Ok = No (\case Refl impossible)
  decEq NullPointer Error = No (\case Refl impossible)
  decEq NullPointer InvalidParam = No (\case Refl impossible)
  decEq NullPointer OutOfMemory = No (\case Refl impossible)
  decEq NullPointer NullPointer = Yes Refl

||| Opaque handle for library resources
||| Invariant: Handle pointer must be non-null
public export
record Handle where
  constructor MkHandle
  ptr : Bits64
  0 prf : So (ptr /= 0)

||| Returns Nothing if pointer is null
public export
createHandle : Bits64 -> Maybe Handle
createHandle 0 = Nothing
createHandle ptr = case decSo (ptr /= 0) of
  Yes p => Just (MkHandle ptr p)
  No _ => Nothing

--------------------------------------------------------------------------------
-- C-Types Mapping
--------------------------------------------------------------------------------

||| Tagged types for C-FFI boundary
public export
data CType = CInt | CUInt | CLong | CULong | CPtrType

||| Pointer type for platform
public export
CPtr : Platform -> CType -> Type
CPtr p _ = Bits64 -- Simplified for 64-bit template
