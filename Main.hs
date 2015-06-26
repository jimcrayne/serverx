{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Imports from elsewhere
import Prelude hiding (log)
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
import Control.Concurrent.Async
import Data.Monoid
import System.IO.Temp

-- Imports from this library/package...
import qualified Data.ByteString.Char8.Log as Log
import Control.Concurrent.STM.TBMQueue.Multiplex
import Network.Server.Listen.TCP
import Network.IRC.ClientState


-- Type to use as the parameter to ClientState
-- it is stored in the connectionInfo field
type ConnectionInfo = (ThreadId, TBMQueue IRC.Message)

-- | clientIsAccepting
--
--      @st     client state (it's message queue is tucked in to the connectionInfo field)
--
-- Is the client Accepting messages? 
-- We check it's message queue is open
clientIsAccepting :: ClientState ConnectionInfo -> STM Bool
clientIsAccepting (connectionInfo -> Just (_,x)) =  fmap not $ isClosedTBMQueue x
clientIsAccepting _ = return False

clientIsAcceptingIO :: ClientState ConnectionInfo -> IO Bool
clientIsAcceptingIO = atomically . clientIsAccepting

clientQ :: ClientState ConnectionInfo -> TBMQueue IRC.Message
clientQ (connectionInfo -> Just (_,x)) =  x 
clientQ _ = error "NO CLIENT QUEUE!"

type ClientId = ThreadId

-- | main
--
-- Program entry.
main = Log.withLog "" $ \lh -> do
    let log = Log.log lh . B.pack
    Log.enableEcho lh
    Log.setPrefix lh (B.pack "LOG:")

    -- Initialize Thread-Save Data
    newchans <- atomically $ newTBMQueue 20 :: IO (TBMQueue (ThreadId, TBMQueue IRC.Message))
    coutq <- atomically $ newTBMQueue 20 :: IO (TBMQueue IRC.Message)
    outq <- atomically $ newTBMQueue 20 :: IO (TBMQueue IRC.Message)
    connections <- atomically $ newTVar M.empty :: IO (TVar (M.Map ClientId (ClientState ConnectionInfo)))

    -- Start worker threads
    -- Send outq messages out to child connections
    --broadcaster <- async $ consumeQueueMicroseconds outq 5000 (broadcast connections)

    -- recieve messages from children in coutq and then log them before sending them back out
    listenAsync <- async $ do 
        log "Listening on port 4444..."
        createIRCPortListener 4444 "<SERVER-NAME>" 5000 20 20 newchans coutq 
    handleIncoming <- async . pipeHook coutq outq $ \msg -> do
        Log.log lh . B.pack . show $ msg
        Log.log lh . B.append "< " . IRC.encode $ msg

    putStrLn "DEBUG : kick off consumeQueueMicroseconds async!"
    newchanAsync <- async $ consumeQueueMicroseconds newchans 5000 (runNewClientConnection outq connections)

    
    -- Wait till done
    void $ waitAny [listenAsync,newchanAsync{-,broadcaster-}]
    
    
runNewClientConnection :: TBMQueue IRC.Message
                       -> TVar (M.Map ThreadId (ClientState ConnectionInfo)) 
                       -> (ThreadId,TBMQueue IRC.Message) -> IO ()

runNewClientConnection outq connmap (tid,chan) = Log.withLog "" $ \lh -> do
    let log s = Log.log lh s
    mtid <- myThreadId
    putStrLn (show mtid <> " " <> show (tid,"hello"::String))

    -- check for dead clients, this could be moved to 
    -- another thread really...
    (mp,closed) <- atomically $ do
        mp'unfiltered <- readTVar connmap
        closedKVals <- filterM (fmap not . clientIsAccepting . snd) (M.toList mp'unfiltered)
        let closedIds = map fst closedKVals
        modifyTVar connmap (M.filterWithKey (\k v -> not (k `elem` closedIds)))
        mp'filtered <- readTVar connmap
        return (mp'filtered,closedIds)

    let name = B.pack (filter (/=' ') $ show tid)
        welcomeMessage = ("Welcome!! New Connection: You are " <> name)
    log ("-> (" <> name <> ") " <> welcomeMessage)
    atomically $ writeTBMQueue chan (IRC.privmsg "" welcomeMessage)
    let l = M.toList mp
    forM_ l $ \(i,clientQ -> c) -> do
        let entrance = IRC.privmsg "" ("* " <> name <> " enters.")
        log (B.append "@" $ IRC.encode entrance)
        atomically $ writeTBMQueue c entrance
        forM_ closed $ \closedTid -> do
            let exit = (IRC.privmsg "" ("* " <>B.pack (show closedTid) <> " exits."))
            log (B.append "@" $ IRC.encode exit)
            atomically $ writeTBMQueue c exit
         
    atomically $ modifyTVar connmap (M.insert tid $ clientState0 { connectionInfo = Just (tid,chan)
                                                                 , nick=NoneOrDefaultNick name })

broadcast connections msg =  Log.withLog "" $ \lh -> do
    mp <- atomically $ readTVar connections
    Log.enableEcho lh
    forM_ (M.elems mp) $ \q -> do
        Log.log lh (" > (All conns) " <> IRC.encode msg)
        atomically $ writeTBMQueue q msg
    
