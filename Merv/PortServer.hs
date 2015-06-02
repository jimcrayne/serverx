{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BangPatterns #-}
module Merv.PortServer (createTCPPortListener) where

import qualified Data.ByteString.Char8 as B
import Network.Socket hiding (send)
import Network.Socket.ByteString
import Data.Monoid ((<>))
import Network.IRC
import Network.HTTP.Base (catchIO,catchIO_)
import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad
import Control.Monad.Fix
import System.IO
import System.Directory (getAppUserDataDirectory)
import Text.Printf (printf)
import System.FilePath ((</>))
import Control.Concurrent.STM.TBMQueue
import Control.Monad.Loops
import Merv.Types (multiplexChildPost)
import Control.Exception
import Control.Concurrent.Async

createTCPPortListener :: PortNumber -> B.ByteString -> Int -> Int -> Int
                   -> TBMQueue (ThreadId,TBMQueue Message) -> TBMQueue Message -> IO ()
createTCPPortListener port name delay qsize maxconns postNewTChans outq = 
    bracket
        -- aquire resources
        (socket AF_INET Stream 0)

        -- release resources
        sClose 

        -- operate on resources
        (\sock -> do
        -- make socket immediately reusable - eases debugging.
        setSocketOption sock ReuseAddr 1
        -- listen on TCP port 4242
        bindSocket sock (SockAddrInet port iNADDR_ANY)
        -- allow a maximum of 15 outstanding connections
        listen sock maxconns
        sockAcceptLoop sock name delay qsize postNewTChans outq
        )
 
sockAcceptLoop :: Socket -> B.ByteString -> Int -> Int -> TBMQueue (ThreadId,TBMQueue Message) -> TBMQueue Message -> IO ()
sockAcceptLoop listenSock name delay qsize postNewTChans outq = 
    whileM_ (atomically $ fmap not (isClosedTBMQueue postNewTChans)) $ do
        -- accept one connection and handle it
        conn@(sock,_) <- accept listenSock
        async $ bracket (do
            -- acquire resources 
                hdl <- socketToHandle sock ReadWriteMode
                q <- atomically $ newTBMQueue qsize 
                thisChildOut <- atomically $ newTBMQueue qsize 
                async1 <- async (runConn hdl name q thisChildOut delay) 
                async2 <- async (multiplexChildPost outq thisChildOut 
                                        Just  -- no translation on outgoing
                                        (\m -> return ()))
                return (hdl,q,thisChildOut,(async1,async2))
            )
            -- release resources
            (\(hdl,q,thisChildOut,(async1,async2)) -> do
                cancel async1
                cancel async2
                atomically $ closeTBMQueue q
                atomically $ closeTBMQueue thisChildOut
                hClose hdl
            )
            -- run opration on async
            (\(_,q,_,(async1,async2)) -> do
                let tid = asyncThreadId async1
                atomically $ writeTBMQueue postNewTChans (tid,q)
                --link2 async1 async2  -- Do I need this?
                waitBoth async1 async2
            )
 
runConn :: Handle -> B.ByteString -> TBMQueue Message -> TBMQueue Message -> Int -> IO ()
runConn hdl name q outq delay = do
    --send sock (encode (Message Nothing "NOTICE" ["*", ("Hi " <> name <> "!\n")]))
    B.hPutStrLn hdl (encode (Message Nothing "NOTICE" ["*", ("Hi " <> name <> "!\n")]))

    race_ 
        -- continuously read q and output to handle (socket)
        -- to terminate thread, close q
        (do
        let pending = fmap not (atomically $ isEmptyTBMQueue q)
            closed = atomically . isClosedTBMQueue $ q
        whileM_ (fmap not closed) $ do
            whileM_ pending  $ do
                m <- atomically (readTBMQueue q)
                case m of
                    Just m -> B.hPutStrLn hdl (encode m) 
                    -- Nothing means the Queue is closed and empty, so dont loop
                    Nothing -> return () 
            threadDelay delay
        B.hPutStrLn hdl (encode (quit (Just "Bye!")) )
        )

        -- continuously input from handle and
        -- send to provided outq
        ( forever $ do
        line <- B.hGetLine hdl
        -- debugging
        dir <- getAppUserDataDirectory "merv"
        tid <- myThreadId
        let bQuit = (B.isPrefixOf "/quit") line
        appendFile (dir </> "xdebug") 
                   (printf "%s:%s\n(bQuit=%s) %s\n" (show tid) (show line) (show bQuit) (show $ parseMessage line))
        -- end debugging
        case parseMessage line of
            Just (msg_command -> "QUIT") -> atomically $ closeTBMQueue q
            Just m -> atomically $ writeTBMQueue outq m
            Nothing | "/q" `B.isPrefixOf` line -> atomically $ closeTBMQueue q
            _ -> return undefined
        ) 
