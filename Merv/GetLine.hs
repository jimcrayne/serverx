module Merv.GetLine where

import Control.Monad
import Data.Serialize
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as L
import Data.Monoid
import Data.Binary.Builder

getLine :: Get BS.ByteString
getLine = getWords empty
 where
    getWords b = do
        w <- getWord8
        let x = singleton w
        if (w == 10 || w == 0)
            then return $ BS.concat . L.toChunks . toLazyByteString $ b <> x
            else getWords (b <> x)

{-
instance Serialize IRC.Message where
    put = putByteString . IRC.encode
    get = do
        x <- MG.getLine
        case IRC.decode x of
            Just x -> return x
            Nothing -> fail ("IRC PARSE ERROR:'" <> B.unpack x <> "'")
-}
