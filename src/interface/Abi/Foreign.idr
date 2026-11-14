-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| Foreign Function Interface Bridge
|||
||| Raw FFI calls into lib{{project}} (src/interface/ffi/src/main.zig) and their
||| safe wrappers. Every `%foreign "C:<symbol>,lib{{project}}"` below names a
||| symbol that main.zig `export fn`s; tests/aspect_tests.sh (Aspect 3) fails
||| if one does not. The symbols and the Result codes follow main.zig; the
||| template once bound rsr_* in librsr, which nothing exported.

module Abi.Foreign

import Abi.Types
import Abi.Layout

%default total

--------------------------------------------------------------------------------
-- Library Lifecycle
--------------------------------------------------------------------------------

||| Raw FFI call to initialize the library (Zig: returns ?*Handle, null on failure)
%foreign "C:{{project}}_init,lib{{project}}"
prim__init : PrimIO Bits64

||| Raw FFI call to free library resources (Zig: accepts null)
%foreign "C:{{project}}_free,lib{{project}}"
prim__free : Bits64 -> PrimIO ()

||| Raw FFI call: 1 if the handle is initialised, else 0
%foreign "C:{{project}}_is_initialized,lib{{project}}"
prim__isInitialized : Bits64 -> PrimIO Bits32

||| Safe wrapper for initialization
export
init : IO (Maybe Handle)
init = do
  ptr <- primIO prim__init
  pure (createHandle ptr)

||| Safe wrapper for cleanup
export
free : Handle -> IO ()
free h = primIO (prim__free h.ptr)

||| Safe wrapper for the initialised check
export
isInitialized : Handle -> IO Bool
isInitialized h = do
  flag <- primIO (prim__isInitialized h.ptr)
  pure (flag /= 0)

--------------------------------------------------------------------------------
-- Core Operations
--------------------------------------------------------------------------------

||| Raw FFI call for main processing. The Zig side returns `Result` as a
||| c_int code (0 = ok), not a value: see Abi.Types.resultCode. The return
||| is 32 bits to match C `int` (Idris's `Int` is 64-bit, and the upper half
||| of the return register is unspecified for an `int` return). It is
||| `Bits32`, not `Int32`, because RefC in Idris2 0.7.0 cannot generate code
||| for an `Int32` foreign return; see Abi.Types.resultCode.
%foreign "C:{{project}}_process,lib{{project}}"
prim__process : Bits64 -> Bits32 -> PrimIO Bits32

||| Safe wrapper. Right () on code 0; Left on any other known code; an
||| unknown code is reported as Error rather than guessed at.
export
process : Handle -> Bits32 -> IO (Either Result ())
process h input = do
  code <- primIO (prim__process h.ptr input)
  pure $ case fromCode code of
    Just Ok => Right ()
    Just r  => Left r
    Nothing => Left Error

--------------------------------------------------------------------------------
-- Status and Metrics
--------------------------------------------------------------------------------

||| Get the last error message, if any (Zig: thread-local, no handle argument)
%foreign "C:{{project}}_last_error,lib{{project}}"
prim__lastError : PrimIO (Ptr String)

||| Library version string (static storage on the Zig side)
%foreign "C:{{project}}_version,lib{{project}}"
prim__version : PrimIO (Ptr String)

||| Detailed error string helper, one line per Result constructor
export
errorDescription : Result -> String
errorDescription Ok = "Success"
errorDescription Error = "Generic error"
errorDescription InvalidParam = "Invalid parameter"
errorDescription OutOfMemory = "Out of memory"
errorDescription NullPointer = "Null pointer"

--------------------------------------------------------------------------------
-- Documentation
--------------------------------------------------------------------------------

||| Summary of ABI safety properties:
||| 1. All functions are total (total keyword enforced).
||| 2. Pointers are verified non-null before being wrapped in Handle.
||| 3. Abi.Layout proves C-ABI alignment for its example struct only. No
|||    struct crosses this seam by value: Handle is an opaque pointer.
||| 4. FFI boundary uses explicitly tagged types from Abi.Types, and the
|||    Result code table round-trips (Abi.Types.fromCodeResultCode)
|||    and is injective (Abi.Types.resultCodeInjective).
public export
abiSafetyGuarantees : String
abiSafetyGuarantees = "{{project}} ABI: 4 stated safety properties for FFI integration"
