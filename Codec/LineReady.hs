{-# LANGUAGE TypeFamilies #-}
module Codec.LineReady where

import qualified Data.ByteString.Char8 as B
import Data.Monoid
import Data.List (foldl')
import Data.Maybe

class LineReady t where
    type SerialError t
    toLineReady :: t -> B.ByteString
    fromLineReady :: B.ByteString -> Either (SerialError t) t

replaceCharStrIndex :: Char -> B.ByteString -> Int -> B.ByteString
replaceCharStrIndex c str i = a <> B.singleton c <> B.drop 1 b 
        where (a,b) = B.splitAt i str

-- You can use this ByteString instance of LineReady
-- to make an instance for any binary serializable
-- data.
--  CEREAL:
--  type SerialError = String
--  toLineReady m = toLineReady (encode m)
--  fromLineREady s = fromLineReady s >>= decode -- Either monad
--  BINARY:
--  type SerialError = (L.ByteString,Int64,String)
--  toLineReady m = toLineReady (B.concat . L.toChunks $ encode m)
--  fromLineREady s = fromLineReady s >>= decodeOrFail -- Either monad

instance LineReady B.ByteString where
    type SerialError B.ByteString = ()

    toLineReady blob = 
        let as = zip [0..] (B.unpack blob) 
            bs = filter ((=='\n') . snd) as
            is = map fst bs 
            in B.pack (show is) <> foldl' (replaceCharStrIndex '#') blob is 

    fromLineReady str = Right $ foldl' (replaceCharStrIndex '\n') (B.drop 1 str') is
            where is = map fst . mapMaybe B.readInt $ 
                            B.groupBy (\c d -> (c/=',')&&(d/=',')) ls
                  (ls,str') = B.break (==']') (B.drop 1 str)
