{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
module Codec.LineReady.Serialize 
    {-# WARNING "Generic LineReady instance for Serialize! ... using UndecidableInstances." #-} where

import Data.Serialize
import Codec.LineReady
import Data.Either

instance Serialize t => LineReady t where
  type SerialError = String
  toLineReady m = toLineReady (encode m)
  fromLineReady s = fromLineReady s >>= decode -- Either monad


