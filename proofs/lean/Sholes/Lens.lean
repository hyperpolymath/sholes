-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

import Sholes.Core

namespace Sholes

def Environment := Bool
def Posix : Environment := false
def Windows : Environment := true

def toWindowsText : Stream → Stream
  | [] => []
  | b :: bs => if b = lf then cr :: lf :: toWindowsText bs else b :: toWindowsText bs

def toWindows (s : Stream) : Stream :=
  if containsNul s = true then s else toWindowsText s

def get : Environment → Stream → Stream
  | false, s => canon s
  | true, s => toWindows (canon s)

def put (_ : Environment) (s _ : Stream) : Stream := canon s

theorem put_get (e : Environment) (s : Stream) : put e s (get e s) = canon s := rfl

theorem get_put (e : Environment) (s : Stream) :
    get e (put e s (get e s)) = get e s := by
  cases e
  · exact idempotence s
  · exact congrArg toWindows (idempotence s)

end Sholes
