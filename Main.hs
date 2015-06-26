{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

import Prelude hiding (log)
import qualified Data.ByteString.Char8.Log as Log
import Control.Concurrent.STM.TBMQueue.Multiplex

import System.Environment
import Control.Exception --(throw,ArithException (..))
import qualified Data.ByteString.Char8 as B

import qualified Network.IRC as IRC
import qualified Data.Map as M

import Control.Concurrent.STM.TBMQueue
import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad
import Control.Monad.Loops

import Network.Server.Listen.TCP
import Control.Concurrent.Async
import Data.Monoid
import System.IO.Temp

main = Log.withLog "" $ \lh -> do
    let log = Log.log lh . B.pack
    Log.enableEcho lh
    newchans <- atomically $ newTBMQueue 20 :: IO (TBMQueue (ThreadId, TBMQueue IRC.Message))
    outq <- atomically $ newTBMQueue 20 :: IO (TBMQueue IRC.Message)
    connections <- atomically $ newTVar M.empty :: IO (TVar (M.Map ThreadId (TBMQueue IRC.Message)))
    broadcaster <- async $ consumeQueueMicroseconds outq 5000 (broadcast connections)
    listenAsync <- async $ createIRCPortListener 4444 "<SERVER-NAME>" 5000 20 20 newchans outq 
    log "Listening on port 4444..."
    newchanAsync <- async $ consumeQueueMicroseconds newchans 5000 (runNewClientConnection outq connections)
    
    void $ waitAny [listenAsync,newchanAsync,broadcaster]
    
    
runNewClientConnection :: TBMQueue IRC.Message
                       -> TVar (M.Map ThreadId (TBMQueue IRC.Message)) 
                       -> (ThreadId,TBMQueue IRC.Message) -> IO ()

runNewClientConnection outq connmap (tid,chan) = Log.withLog "" $ \lh -> do
    print (tid,"hello"::String)
    (mp,closed) <- atomically $ do
        mp'unfiltered <- readTVar connmap
        closedKVals <- filterM (isClosedTBMQueue . snd) (M.toList mp'unfiltered)
        modifyTVar connmap (M.filterWithKey (\k v -> not (k `elem` map fst closedKVals)))
        mp <- readTVar connmap
        return (mp,map fst closedKVals)
    let name = B.pack (show tid)
        welcomeMessage = ("Welcome!! New Connection: You are " <> name)
    Log.log lh ("-> (" <> B.pack (show tid) <> ") " <> welcomeMessage)
    atomically $ writeTBMQueue chan (IRC.privmsg "" welcomeMessage)
    let l = M.toList mp
    forM_ l $ \(i,c) -> do
        atomically $ writeTBMQueue outq (IRC.privmsg "" ("* " <> name <> " enters."))
        forM_ closed $ \closedTid ->  
            atomically $ writeTBMQueue outq (IRC.privmsg "" ("* " <>B.pack (show closedTid) <> " exits."))
         
    atomically $ modifyTVar connmap (M.insert tid chan)

broadcast connections msg =  Log.withLog "" $ \lh -> do
    mp <- atomically $ readTVar connections
    forM_ (M.elems mp) $ \q -> do
        Log.log lh (" > (All conns) " <> IRC.encode msg)
        atomically $ writeTBMQueue q msg
