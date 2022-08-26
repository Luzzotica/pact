-- |
-- Module      :  Pact.Native.Trans.Log
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Operators and math built-ins.
--

module Pact.Native.Trans.Log
    ( trans_log
    , trans_log2
    , trans_log10
    , trans_logBase
    ) where

import Pact.Native.Trans.Types
  ( c'MPFR_RNDN
  , c'mpfr_init
  , c'mpfr_set_str
  , c'mpfr_div
  , c'mpfr_log
  , c'mpfr_log2
  , c'mpfr_log10
  , c'mpfr_sprintf
  , TransResult
  , readResultNumber
  , trans_arity1
  , withFormattedNumber
  )
import Data.Decimal (Decimal, normalizeDecimal)
import Foreign.C.String (withCString, peekCString)
import Foreign.Marshal.Alloc (alloca)
import System.IO.Unsafe (unsafePerformIO)

trans_log :: Decimal -> TransResult Decimal
trans_log = trans_arity1 c'mpfr_log

trans_log2 :: Decimal -> TransResult Decimal
trans_log2 = trans_arity1 c'mpfr_log2

trans_log10 :: Decimal -> TransResult Decimal
trans_log10 = trans_arity1 c'mpfr_log10

trans_logBase :: Decimal -> Decimal -> TransResult Decimal
trans_logBase x y = readResultNumber $ unsafePerformIO $
  withCString (show (normalizeDecimal x)) $ \xstr ->
  withCString (show (normalizeDecimal y)) $ \ystr ->
  alloca $ \x' ->
  alloca $ \x'' ->
  alloca $ \y' ->
  alloca $ \y'' ->
  alloca $ \z' ->
  withFormattedNumber $ \out fmt -> do
    c'mpfr_init x'
    c'mpfr_set_str x' xstr 10 c'MPFR_RNDN
    c'mpfr_init y'
    c'mpfr_set_str y' ystr 10 c'MPFR_RNDN
    c'mpfr_init x''
    c'mpfr_init y''
    c'mpfr_log x'' x' c'MPFR_RNDN
    c'mpfr_log y'' y' c'MPFR_RNDN
    c'mpfr_init z'
    c'mpfr_div z' y'' x'' c'MPFR_RNDN
    c'mpfr_sprintf out fmt c'MPFR_RNDN z'
    peekCString out
