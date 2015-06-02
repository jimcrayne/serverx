{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BangPatterns #-}
module Merv.Types where

import Network
import System.IO
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (ByteString (..) )
import Network.IRC
import Network.IRC.Base
import System.Exit
import System.Directory
import System.FilePath
import Data.Monoid
import Control.Concurrent.STM
import Data.Map.Strict as M
import Control.Monad
import Control.Concurrent
import qualified Data.Set as S
import Control.Arrow (second,first)
import System.Environment hiding (getExecutablePath)
import System.Environment.Executable (getExecutablePath)
import System.Process
import Numeric (readDec)
import Network.Socket.Internal (PortNumber (..))
import qualified Data.Binary as Bin
import Data.Binary.Get.Internal as X
import Data.Binary.Put as Y
import GHC.Generics (Generic)
import Control.Concurrent.STM.TBMQueue
import Control.Monad.Loops
import Data.List
import Data.Maybe

-- | multiplexChildPost
--
--  This function indefinitely reads the @childout@ queue and applies 
--  the function @translate@ to the contents before passing it on to the
--  @out@ queue. The @triggerAction@ is performed on the message prior
--  to translation.
--
--  To terminate the thread, close @childout@ queue.
--
multiplexChildPost :: TBMQueue Message -> TBMQueue Message -> (Message -> Maybe Message) -> (Message -> IO ())-> IO ()
multiplexChildPost out childout translate triggerAction = whileM_ (fmap not (atomically $ isClosedTBMQueue childout)) $ do
    whileM_ (fmap not (atomically $ isEmptyTBMQueue childout)) $ do
        msg <- atomically $ readTBMQueue childout
        case msg of
            Just m' -> do
                triggerAction m'
                case translate m' of
                    Just m -> atomically $ writeTBMQueue out m
                    _ -> return ()
            _ -> return ()
    threadDelay 5000 -- yield two 100ths of a second, for other threads
