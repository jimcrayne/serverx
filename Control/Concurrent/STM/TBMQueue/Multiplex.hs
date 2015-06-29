{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BangPatterns #-}
module Control.Concurrent.STM.TBMQueue.Multiplex where

import System.IO
import qualified Data.ByteString.Char8 as B
import Data.Monoid
import Control.Concurrent.STM
import Data.Map.Strict as M
import Control.Monad
import Control.Concurrent
import qualified Data.Binary as Bin
import Control.Concurrent.STM.TBMQueue
import Control.Monad.Loops
import Data.List
import Data.Maybe

-- | pipeTransHookMicroseconds
--
--  This function indefinitely reads the @fromChan@ queue and applies 
--  the function @translate@ to the contents before passing it on to the
--  @toChan@ queue. The @triggerAction@ is performed on the message prior
--  to the translation. The @fromChan@ queue is checked every @micros@ 
--  microseconds from the last emptying.
--
--  To terminate the thread, close @fromChan@ queue.
--
pipeTransHookMicroseconds :: TBMQueue a -> TBMQueue b -> Int ->  (x -> a -> Maybe b) -> (a -> IO x) -> IO ()
pipeTransHookMicroseconds fromChan toChan micros translate triggerAction = 
    whileM_ (fmap not (atomically $ isClosedTBMQueue fromChan)) $ do
        whileM_ (fmap not (atomically $ isEmptyTBMQueue fromChan)) $ do
            msg <- atomically $ readTBMQueue fromChan
            case msg of
                Just m' -> do
                    x <- triggerAction m'
                    case translate x m' of
                        Just m -> atomically $ writeTBMQueue toChan m
                        _ -> return ()
                _ -> return ()
        threadDelay micros -- 5000 -- yield two 100ths of a second, for other threads

pipeTransHook fromChan toChan translate triggerAction =
    pipeTransHookMicroseconds fromChan toChan 5000 translate triggerAction 

pipeTrans fromChan toChan translate = 
    pipeTransHook fromChan toChan translate (void . return)


pipeHook fromChan toChan triggerAction = 
    pipeTransHook fromChan toChan (\() -> Just) triggerAction

pipeQueue fromChan toChan =
    pipeTransHookMicroseconds fromChan toChan 5000 (\() -> Just) (void . return) 

teePipeQueueMicroseconds fromChan toChan1 toChan2 micros =
    whileM_ (fmap not (atomically $ isClosedTBMQueue fromChan)) $ do
        whileM_ (fmap not (atomically $ isEmptyTBMQueue fromChan)) $ do
            msg <- atomically $ readTBMQueue fromChan
            case msg of
                Just m -> do
                    atomically $ writeTBMQueue toChan1 m
                    atomically $ writeTBMQueue toChan2 m
                _ -> return ()
        threadDelay micros -- 5000 -- yield two 100ths of a second, for other threads

teePipeQueue fromChan toChan1 toChan2 =
    teePipeQueueMicroseconds fromChan toChan1 toChan2 5000 


-- Deprecated: Use consumeQueueMicroseconds
-- TODO: Remove this
withQueueMicroseconds fromChan action delay = whileM_ (atomically . fmap not $ isClosedTBMQueue fromChan) $ do
    whileM_ (atomically . fmap not $ isEmptyTBMQueue fromChan) $ do
        t <- atomically $ readTBMQueue fromChan
        case t of 
            Just x -> action x
            Nothing -> return ()
    threadDelay delay

{-# ANN withQueue ("HLint: Ignore Eta reduce"::String) #-}
withQueue fromchan action = consumeQueueMicroseconds fromchan 5000 action 
{-# DEPRECATED withQueueMicroseconds, withQueue "Use consumeQueueMicroseconds" #-}

-- | consumeQueueMicroseconds
-- (as of version 1.0.4)
--
-- Continously run the provided action on items
-- from the provided queue. Delay for provided
-- microseconds each time the queue is emptied.
consumeQueueMicroseconds q micros action = whileM_ (atomically . fmap not $ isClosedTBMQueue q) $ do
    whileM_ (atomically . fmap not $ isEmptyTBMQueue q) $ do
        x <- atomically $ readTBMQueue q
        case x of
            Just s -> action s
            Nothing -> return ()
    threadDelay micros
