{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
module Codec.LineReady.Binary {-# WARNING "Generic LineReady instance for Binary! .. using UndecidableInstances." #-} where

import Data.ByteString.Lazy.Char8 as L
import Data.ByteString.Char8 as B
import Data.Binary
import Codec.LineReady
import Data.Either
import Data.Int (Int64)

instance Binary t => LineReady t where
  type SerialError = (L.ByteString,Int64,String)
  toLineReady m = toLineReady (B.concat . L.toChunks $ encode m)
  fromLineReady s = fromLineReady s >>= decodeOrFail -- Either monad
