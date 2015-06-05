module GetLine where

import Control.Monad
import Data.Serialize
import qualified Data.ByteString as BS

getLine :: Get BS.ByteString
getLine = getWords BS.empty
 where
    getWords b = do
        w <- getWord8
        if w == 10
            then return $ BS.snoc b w
            else getWords (BS.snoc b w)
