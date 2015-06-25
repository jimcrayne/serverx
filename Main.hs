{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

import Prelude hiding (log)
import Merv.Log
import Merv.Multiplex

import System.Environment
import Control.Exception --(throw,ArithException (..))
import qualified Data.ByteString.Char8 as B

import qualified Network.IRC as IRC
import qualified Data.Map as M

import Control.Concurrent.STM.TBMQueue
import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad

import Merv.PortServer
import Control.Concurrent.Async
import Data.Monoid
import System.IO.Temp

main = withLog "" $ do
    newchans <- atomically $ newTBMQueue 20 :: IO (TBMQueue (ThreadId, TBMQueue IRC.Message))
    outq <- atomically $ newTBMQueue 20 :: IO (TBMQueue IRC.Message)
    connections <- atomically $ newTVar M.empty :: IO (TVar (M.Map ThreadId (TBMQueue IRC.Message)))
    listenAsync <- async $ createIRCPortListener 4444 "<SERVER-NAME>" 5000 20 20 newchans outq 
    newchanAsync <- async $ withQueue newchans (runNewClientConnection connections)
    
    void $ waitBoth listenAsync newchanAsync
    
    
runNewClientConnection :: TVar (M.Map ThreadId (TBMQueue IRC.Message)) -> (ThreadId,TBMQueue IRC.Message) -> IO ()
runNewClientConnection connmap (tid,chan) = do
    print (tid,"hello"::String)
    mp <- atomically $ do
        modifyTVar connmap (M.insert tid chan)
        readTVar connmap
    let l = M.toList mp
    mapM_ (\(i,c) -> atomically $ writeTBMQueue c (IRC.privmsg "" ("hello " <> B.pack (show i)))) l
    return ()
