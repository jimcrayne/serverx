{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeFamilies #-}
module Merv.PortServer (createTCPPortListener,createIRCPortListener) where

import qualified Data.ByteString.Char8 as B
import Network.Socket hiding (send)
import Network.Socket.ByteString
import Data.Monoid ((<>))
import qualified Network.IRC as IRC
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
import Merv.Multiplex (pipeTransHookMicroseconds)
import Control.Exception
import Control.Concurrent.Async

import Control.Arrow (second)
import Codec.LineReady

instance LineReady IRC.Message where
    type SerialError IRC.Message = String
    toLineReady = IRC.encode
    fromLineReady s = case IRC.decode s of
        Just x -> Right x
        Nothing -> Left ("IRC PARSE ERROR:'" <>  B.unpack s <> "'")

createIRCPortListener :: PortNumber -> B.ByteString -> Int -> Int -> Int
                   -> TBMQueue (ThreadId,TBMQueue IRC.Message) -> TBMQueue IRC.Message -> IO ()
createIRCPortListener port name delay qsize maxconns postNewTChans outq = 
  createTCPPortListener port name delay qsize maxconns postNewTChans outq ircReact


createTCPPortListener :: LineReady a => PortNumber -> B.ByteString -> Int -> Int -> Int
                   -> TBMQueue (ThreadId,TBMQueue a) -> TBMQueue a 
                   -> (Handle -> TBMQueue a -> IO ()) -> IO ()
createTCPPortListener port name delay qsize maxconns postNewTChans outq react = 
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
        sockAcceptLoop sock name delay qsize postNewTChans outq react
        )
 
sockAcceptLoop :: LineReady a => Socket -> B.ByteString -> Int -> Int -> TBMQueue (ThreadId,TBMQueue a) -> TBMQueue a 
                       -> (Handle -> TBMQueue a -> IO ()) -> IO ()
sockAcceptLoop listenSock name delay qsize postNewTChans outq react = 
    whileM_ (atomically $ fmap not (isClosedTBMQueue postNewTChans)) $ do
        -- accept one connection and handle it
        conn@(sock,_) <- accept listenSock
        async $ bracket (do
            -- acquire resources 
                hdl <- socketToHandle sock ReadWriteMode
                q <- atomically $ newTBMQueue qsize 
                thisChildOut <- atomically $ newTBMQueue qsize 
                async1 <- async (runConn hdl name q thisChildOut delay react) 
                async2 <- async (pipeTransHookMicroseconds thisChildOut outq 5000
                                        (\() -> Just)  -- no translation on outgoing
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
 
runConn :: LineReady a => Handle -> B.ByteString -> TBMQueue a -> TBMQueue a -> Int 
                       -> (Handle -> TBMQueue a -> IO ()) -> IO ()
runConn hdl name q outq delay react = do
    --send sock (encode (Message Nothing "NOTICE" ["*", ("Hi " <> name <> "!\n")]))
    -- B.hPutStrLn hdl (encode (Message Nothing "NOTICE" ["*", ("Hi " <> name <> "!\n")]))
    -- OnConnect Message...

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
                    Just m -> B.hPutStrLn hdl (toLineReady m) 
                    -- Nothing means the Queue is closed and empty, so dont loop
                    Nothing -> return () 
            threadDelay delay
        --B.hPutStrLn hdl (encode (quit (Just "Bye!")) )
        )

        -- continuously input from handle and
        -- send to provided outq
        (whileM_ (atomically . fmap not $ isClosedTBMQueue outq) $ react hdl outq )


ircReact hdl outq = do
        line <- B.hGetLine hdl
        {- debugging
        dir <- getAppUserDataDirectory "merv"
        tid <- myThreadId
        let bQuit = (B.isPrefixOf "/quit") line
        appendFile (dir </> "xdebug") 
                   (printf "%s:%s\n(bQuit=%s) %s\n" (show tid) (show line) (show bQuit) (show $ IRC.parseMessage line))
        -- end debugging -}
        case IRC.decode line of
            Just (IRC.msg_command -> "QUIT") -> atomically $ closeTBMQueue outq
            Just m -> atomically $ writeTBMQueue outq m
            Nothing | "/q" `B.isPrefixOf` line -> atomically $ closeTBMQueue outq
            _ -> return undefined
