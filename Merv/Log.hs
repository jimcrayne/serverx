{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DoAndIfThenElse #-}
module Merv.Log where
    
import Prelude hiding (log,catch)
import System.IO
import System.Directory
import System.FilePath

import Text.Printf
import Data.String
import System.IO.Unsafe (unsafePerformIO)
import Control.Concurrent.STM.TBMQueue
import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad.Loops
import Control.Exception

import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as L
import System.Environment (getProgName)
import Data.Monoid

import Data.Typeable
import Data.Dynamic
import Data.Word 
import Control.Concurrent.Async
import Control.Monad
import Control.Monad.Fix
import qualified Data.Map as M
import Data.ByteString.Search (replace)
import Data.List

globalLogQ :: TBMQueue (ThreadId,B.ByteString)
globalLogQ = unsafePerformIO (newTBMQueueIO 400)
{-# NOINLINE globalLogQ #-}

globalLogReplaceMap :: TVar (M.Map (ThreadId,B.ByteString) B.ByteString)
globalLogReplaceMap = unsafePerformIO (newTVarIO M.empty)
{-# NOINLINE globalLogReplaceMap #-}

globalShutdownLogging :: TMVar ()
globalShutdownLogging = unsafePerformIO newEmptyTMVarIO
{-# NOINLINE globalShutdownLogging #-}

equate :: B.ByteString -> B.ByteString -> IO Bool
equate key@(B.uncons -> Just (k,ey)) val = do
    tid <- myThreadId
    let disallowed = ["$t","%t","%s", "%d"] 
    if k `elem` "%$" then 
        if key `notElem` disallowed then do
            atomically $ modifyTVar globalLogReplaceMap (M.insert (tid,key) val)
            return True
        else do
            log' $ "ERROR (Logging):" 
                <> B.pack (show tid) 
                <> " Cannot change magic substitution keys: '" <> B.pack (show disallowed) 
            return False
    else do
        log' $ "ERROR (Logging):" 
            <> B.pack (show tid) 
            <> " Failed to equate '" <> key <> "' and '" <> val <> "'. Must prefix '$' or '%'."
        return False

equate "" val  = do
        tid <- myThreadId
        log' $ "ERROR (Logging):" 
            <> B.pack (show tid) 
            <> " Cannot equate '" <> val <> "' to empty string."
        return False

log' s = do
    tid <- myThreadId
    atomically $ writeTBMQueue globalLogQ (tid,s)

startLoggingQueue file logq shutdownTMVar = async . fix $ \loop -> (
        whileM_ (atomically . fmap not . isClosedTBMQueue $ logq) $ do
            done <- atomically $ tryReadTMVar shutdownTMVar
            case done of 
                Just _ -> atomically $ closeTBMQueue logq
                Nothing -> do
                    whileM_ (atomically $ isEmptyTBMQueue logq) (threadDelay 2000)
                    whileM_ (atomically . fmap not $ isEmptyTBMQueue logq) $ do
                        x <- atomically $ readTBMQueue logq
                        case x of
                            Just (th,s) -> do
                                equates <- atomically $ readTVar globalLogReplaceMap
                                tid <- myThreadId
                                
                                let kvs :: [(B.ByteString, B.ByteString)]
                                    kvs = fmap (\((_,k),v) -> (k,v)) (filter ((==tid) . fst . fst) (M.toList equates))
                                    kvs' = fmap (\(x,y) -> (L.fromChunks [x], L.fromChunks [y])) kvs
                                    s' :: L.ByteString 
                                    s' = foldl'
                                            (\s (k,v) -> replace k v (B.concat $ L.toChunks s))
                                            (L.fromChunks [s])
                                            kvs
                                B.appendFile file (B.concat $ L.toChunks s')
                            _ -> return ()
    ) `catches` [ Handler (\(e:: IOException) -> appendFile file ("ERROR (Logging): " ++ show e ++ "\n"))
                , Handler (\(FormatError st s:: FormatError) -> do 
                                case st of
                                    _ -> appendFile file ("ERROR (Logging): " ++ s ++ "\n") 
                                loop
                          )]

data FormatError = FormatError (Maybe FormatState) String deriving (Show,Typeable)
instance Exception FormatError
    
startLogging logfile = startLoggingQueue logfile globalLogQ globalShutdownLogging

log :: B.ByteString -> IO ()
log s = do
    tid <- myThreadId
    let t = B.pack $ show tid
    atomically $ modifyTVar globalLogReplaceMap (M.insert (tid,"%t") t)
    atomically $ modifyTVar globalLogReplaceMap (M.insert (tid,"$t") t)
    atomically $ writeTBMQueue globalLogQ (tid,s <> "\n")

-- logf s = atomically . writeTBMQueue globalLogQ . B.pack . printf (s <> "\n")

data FormatTag = forall a . FmtString a Dynamic | forall a. FmtInteger a String

--class LogfArg a where
--    mkFormatTag :: a -> FormatTag

mkFormatTag :: (Typeable a,Show a) => a -> FormatTag
mkFormatTag x = 
    case typeOf x of
        r | r == typeOf (1::Integer) -> FmtInteger x (show x)
        r | r == typeOf (1::Int)  -> FmtInteger x (show x)
        r | r == typeOf (1::Word) -> FmtInteger x (show x)
        r | r == typeOf (""::String) -> FmtString x (toDyn x)
        r | r == typeOf (""::B.ByteString) -> FmtString x (toDyn x)
        _   -> FmtString x (toDyn $ show x)


--instance LogfArg B.ByteString where
--    mkFormatTag = FmtByteString

--instance LogfArg Int where
--    mkFormatTag = FmtInteger . fromIntegral

--instance LogfArg Integer where
--    mkFormatTag = FmtInteger

class LogFType t where
    logfTags ::  Maybe FormatState -> String -> [FormatTag] -> t

instance LogFType String where
    logfTags st formatstr args = uprintf st formatstr (reverse args)

data FormatState = FState { threadId :: ThreadId } deriving (Show,Typeable)

uprintf :: Maybe FormatState -> String -> [FormatTag] -> String
uprintf fs ""         []     = ""
uprintf fs ""         _      = fmterror fs
--uprintf fs ('%':'t':c:cs) us = fmt fs c (error "Report Bug in Log.hs!") ++ uprintf fs cs us
uprintf fs ('%':_:_ ) []     = argerror fs
uprintf fs ('%':c:cs) (u:us) = fmt fs c u ++ uprintf fs cs us
uprintf fs ( c :cs   ) us    = c : uprintf fs cs us

fmt :: Maybe FormatState ->  Char -> FormatTag -> String
fmt fs 'd' u = asint fs u
fmt fs 's' u = asstr fs u
--fmt fs 't' _ = case fs of
--                    (Just (FState tid)) -> show tid
--                    _ -> "%t-id"

asint _ (FmtInteger i x) = x
asint fs (FmtString  _ _) = typeerror fs "Integral" "String"

asstr :: Maybe FormatState -> FormatTag -> String
asstr _ (FmtString  s x) = fromDyn x ""
asstr _ (FmtInteger _ x) = x -- typeerror "String" "Integral"

typeerror fs t1 t2 = errorFmt fs $ "Type error: expected " ++ t1 ++ ", got " ++ t2 ++ "."

fmterror fs = errorFmt fs "Reached end of format string with args remaining."
argerror fs = errorFmt fs "Insufficient args for format string"

errorFmt fs s= throw (FormatError fs s)

instance LogFType (IO a) where
    logfTags state formatstr args = case state of
        Nothing -> do
            log (B.pack $ uprintf Nothing formatstr (reverse args)) 
            return undefined
        ms -> do
            log (B.pack $ uprintf ms formatstr (reverse args)) 
            return undefined

instance (Typeable a, Show a, LogFType t) => LogFType (a -> t) where
    logfTags state fmt args a = logfTags state fmt (mkFormatTag a : args)

logf :: LogFType r => String -> r
logf fmtstr = logfTags Nothing fmtstr []


withLog :: String -> IO () -> IO ()
withLog name action = do
    appName <- getProgName
    appDir <- getAppUserDataDirectory appName
    createDirectoryIfMissing True appDir
    let logFile = case name of
                    "" -> appDir </> appName ++ ".log"
                    _ ->  appDir </> appName ++ "." ++ name ++ ".log"
    bracket 
            (startLogging logFile) 
            (\aid -> do
                threadDelay 10000 -- time to print any exceptions
                atomically $ closeTBMQueue globalLogQ
                threadDelay 1000 -- give it a chance to shutdown itself
                cancel aid       -- kill the thread
            )
            (\aid -> 
                catch action logException
            )
                
        
    where
        waitForLog x = do
            whileM (fmap not . atomically $ isEmptyTBMQueue globalLogQ) (threadDelay 5000)
            atomically $ closeTBMQueue globalLogQ
            return x
        logException e = do
            log (B.pack $ "ERROR: " ++ show (e::SomeException) ++ "\n")
            throw e

