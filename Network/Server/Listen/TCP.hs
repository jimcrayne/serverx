{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeFamilies #-}
module Network.Server.Listen.TCP (createTCPPortListener) where

import qualified Data.ByteString.Char8 as B
import Network.Socket hiding (send)
import Network.Socket.ByteString
import Data.Monoid ((<>))
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
import Control.Exception
import Control.Concurrent.Async
import Control.Arrow (second)

import Control.Concurrent.STM.TBMQueue.Multiplex (pipeTransHookMicroseconds)
import Codec.LineReady
import qualified System.IO.Log as Log

createTCPPortListener :: LineReady a => PortNumber -> B.ByteString -> Int -> Int -> Int
                    -> (ThreadId -> IO clientId)
                    -> TBMQueue (clientId,TBMQueue a) -> TBMQueue a 
                    -> (Handle -> IO B.ByteString) 
                    -> (B.ByteString -> a) 
                    -> (clientId -> a -> IO ()) 
                    -> IO ()
createTCPPortListener port name delay qsize maxconns newClientId postNewTChans outq getLine parse react = 
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
        sockAcceptLoop sock name delay qsize newClientId postNewTChans outq getLine parse react
        )
 
sockAcceptLoop :: LineReady a => Socket -> B.ByteString -> Int -> Int 
                        -> (ThreadId -> IO clientId)
                        -> TBMQueue (clientId,TBMQueue a) -> TBMQueue a 
                        -> (Handle -> IO B.ByteString) 
                        -> (B.ByteString -> a) 
                        -> (clientId -> a -> IO ()) 
                        -> IO ()
sockAcceptLoop listenSock name delay qsize newClientId postNewTChans outq getLine parse react = 
    whileM_ (atomically $ fmap not (isClosedTBMQueue postNewTChans)) $ do
        -- accept one connection and handle it
        conn@(sock,_) <- accept listenSock
        async $ bracket (do
            -- acquire resources 
                hdl <- socketToHandle sock ReadWriteMode
                q <- atomically $ newTBMQueue qsize 
                thisChildOut <- atomically $ newTBMQueue qsize  :: IO (TBMQueue B.ByteString)
                async1 <- async (runConn hdl name q thisChildOut delay getLine react) 
                let tid = asyncThreadId async1
                cid <- newClientId tid
                async2 <- async (pipeTransHookMicroseconds thisChildOut outq 5000
                                        (\m s -> m)  -- translate bytestring to message type on outgoing
                                        (\(s::B.ByteString) -> do
                                                let m = parse s
                                                react cid m
                                                return . Just . parse $ s
                                        )
                                )
                return (hdl,q,thisChildOut,(async1,async2),cid)
            )
            -- release resources
            (\(hdl,q,thisChildOut,(async1,async2),cid) -> do
                cancel async1
                cancel async2
                atomically $ closeTBMQueue q
                atomically $ closeTBMQueue thisChildOut
                hClose hdl
            )
            -- run opration on async
            (\(_,q,_,(async1,async2),cid) -> do
                let tid = asyncThreadId async1
                putStrLn ("DEBUG listenSock! Connection: " <> show tid)
                atomically $ writeTBMQueue postNewTChans (cid,q)
                --link2 async1 async2  -- Do I need this?
                waitBoth async1 async2
            )
 
runConn :: LineReady a => Handle -> B.ByteString -> TBMQueue a -> TBMQueue B.ByteString -> Int 
                       -> (Handle -> IO B.ByteString) -> (clientId -> a -> IO ()) -> IO ()
runConn hdl name q outq delay getLine react = do
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
        (whileM_ (atomically . fmap not $ isClosedTBMQueue outq) $ do
                 bBadSocket <- hIsClosed hdl
                 if bBadSocket then 
                    atomically $ closeTBMQueue outq
                  else
                    getLine hdl >>= atomically . writeTBMQueue outq
        )


