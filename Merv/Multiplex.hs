{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BangPatterns #-}
module Merv.Multiplex where

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
pipeTransHookMicroseconds :: TBMQueue a -> TBMQueue b -> Int ->  (a -> Maybe b) -> (a -> IO ()) -> IO ()
pipeTransHookMicroseconds fromChan toChan micros translate triggerAction = 
    whileM_ (fmap not (atomically $ isClosedTBMQueue fromChan)) $ do
        whileM_ (fmap not (atomically $ isEmptyTBMQueue fromChan)) $ do
            msg <- atomically $ readTBMQueue fromChan
            case msg of
                Just m' -> do
                    triggerAction m'
                    case translate m' of
                        Just m -> atomically $ writeTBMQueue toChan m
                        _ -> return ()
                _ -> return ()
        threadDelay micros -- 5000 -- yield two 100ths of a second, for other threads

pipeTransHook fromChan toChan translate triggerAction =
    pipeTransHookMicroseconds fromChan toChan 5000 translate triggerAction 

pipeTrans fromChan toChan translate = 
    pipeTransHook fromChan toChan translate (void . return)

pipeHook fromChan toChan triggerAction = 
    pipeTransHook fromChan toChan id triggerAction

pipeQueue fromChan toChan =
    pipeTransHookMicroseconds fromChan toChan 5000 id (void . return) 

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
