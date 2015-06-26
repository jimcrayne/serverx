{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DoAndIfThenElse #-}
module Data.ByteString.Char8.Log where
    
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
import CanWriteToVarLog
import System.FilePath

type LogQueue = TBMQueue (ThreadId, B.ByteString)

data LogHandle = LogH { logQ :: LogQueue
                      , logFileName :: FilePath
                      , logPrefix :: TVar B.ByteString
                      , logReplaceMap :: TVar (M.Map (ThreadId,B.ByteString) B.ByteString)
                      , logEchoFlag :: TVar Bool
                      , logFileMutex :: TMVar () -- Not strictly necessary anymore, now that I have
                                                 -- an active logManagers list... But I'll leave it
                                                 -- just in case someone wants to write to the file
                                                 -- from some non logManager thread.
                      , logManagers :: TVar Int
                      }

globalLogHandleRegistry :: TVar (M.Map B.ByteString LogHandle)
globalLogHandleRegistry = unsafePerformIO $ newTVarIO M.empty
{-# NOINLINE globalLogHandleRegistry #-}

getDefaultLogFileName :: String -> IO String
getDefaultLogFileName name = do
    appName <- getProgName
    bVarLog <- canWriteToVarLog
    logDir <- 
        if bVarLog then
            return "/var/log"
        else
            getAppUserDataDirectory appName
    return $ case name of
                    "" -> logDir </> appName ++ extSeparator:"log"
                    _ ->  logDir </> appName ++ "." ++ name ++ extSeparator:"log"

newLog :: String -> IO LogHandle
newLog name = getDefaultLogFileName name >>= newLogWithFile

newLogWithFile logFile = do
    handlesMap <- atomically $ readTVar globalLogHandleRegistry
    case M.lookup (B.pack logFile) handlesMap of
        Just h -> return h

        Nothing -> do
            q <- newTBMQueueIO 200 :: IO LogQueue
            replaceMap <- newTVarIO M.empty
            prefix <- newTVarIO (B.pack "")
            echoFlag <- newTVarIO False
            mutex <- newTMVarIO ()
            managers <- newTVarIO 0 :: IO (TVar Int)
            let dir = takeDirectory logFile
            createDirectoryIfMissing True dir
            fileExists <- doesFileExist logFile
            unless fileExists (openFile logFile WriteMode >>= hClose)
                              
            let h =LogH { logQ = q
                        , logFileName = logFile
                        , logPrefix = prefix
                        , logReplaceMap = replaceMap
                        , logEchoFlag = echoFlag
                        , logFileMutex = mutex
                        , logManagers = managers
                        }
            atomically $ modifyTVar globalLogHandleRegistry (M.insert (B.pack logFile) h)
            return h

enableEcho lh = atomically $ writeTVar (logEchoFlag lh) True
disableEcho lh = atomically $ writeTVar (logEchoFlag lh) False
setPrefix lh s = atomically $ writeTVar (logPrefix lh) s

equate :: LogHandle -> B.ByteString -> B.ByteString -> IO Bool
equate lh key@(B.uncons -> Just (k,ey)) val = do
    tid <- myThreadId
    let disallowed = ["$t","%t","%s", "%d"] 
    if k `elem` "%$" then 
        if key `notElem` disallowed then do
            atomically $ modifyTVar (logReplaceMap lh) (M.insert (tid,key) val)
            return True
        else do
            logRaw lh $ "ERROR (Logging):" 
                <> B.pack (show tid) 
                <> " Cannot change magic substitution keys: '" <> B.pack (show disallowed) 
            return False
    else do
        logRaw lh $ "ERROR (Logging):" 
            <> B.pack (show tid) 
            <> " Failed to equate '" <> key <> "' and '" <> val <> "'. Must prefix '$' or '%'."
        return False

equate lh "" val  = do
        tid <- myThreadId
        logRaw lh $ "ERROR (Logging):" 
            <> B.pack (show tid) 
            <> " Cannot equate '" <> val <> "' to empty string."
        return False

logRaw lh s = do
    tid <- myThreadId
    atomically $ writeTBMQueue (logQ lh) (tid,s)

clearEquates lh = do
    tid <- myThreadId
    atomically $ modifyTVar (logReplaceMap lh) (M.filterWithKey (\(id,_) _ -> id/=tid))
        
appendFileWithMutex x f s = do
    --putStrLn "DEBUG $ AWAIT mutex"
    torch <- atomically $ takeTMVar x
    B.appendFile f s
    --putStrLn "DEBUG $ Pass mutex"
    atomically $ putTMVar x torch

stopLogging lh = do
    mgrs <- atomically $ do
        modifyTVar (logManagers lh) (subtract 1) 
        readTVar (logManagers lh)
    when (mgrs == 0) $ do
        threadDelay 10000 -- time to print any exceptions
        atomically $ closeTBMQueue (logQ lh)
        threadDelay 1000 -- give it a chance to shutdown itself

startLogging lh = async $ do 
    let file = logFileName lh
        logq = logQ lh
    mgrs <- atomically $ do
        modifyTVar (logManagers lh) (+1)
        readTVar (logManagers lh)
    when (mgrs == 1) . fix $ \loop -> (do
        whileM_ (atomically . fmap not . isClosedTBMQueue $ logq) $ do
                    whileM_ (atomically $ isEmptyTBMQueue logq) (threadDelay 2000)
                    whileM_ (atomically . fmap not $ isEmptyTBMQueue logq) $ do
                        x <- atomically $ readTBMQueue logq
                        prefix <- atomically $ readTVar (logPrefix lh)
                        case x of
                            Just (th,B.append prefix -> s) -> do
                                equates <- atomically $ readTVar (logReplaceMap lh)
                                
                                let kvs :: [(B.ByteString, B.ByteString)]
                                    kvs = fmap (\((_,k),v) -> (k,v)) (filter ((==th) . fst . fst) (M.toList equates))
                                    kvs' = fmap (\(x,y) -> (L.fromChunks [x], L.fromChunks [y])) kvs
                                    s' :: L.ByteString 
                                    -- TODO: This is not a very efficient way to make replacements..
                                    s' = foldl'
                                            (\s (k,v) -> replace k v (B.concat $ L.toChunks s))
                                            (L.fromChunks [s])
                                            kvs
                                let outline = B.concat $ L.toChunks s'
                                appendFileWithMutex (logFileMutex lh) file outline
                                bEcho <- atomically $ readTVar (logEchoFlag lh)
                                if bEcho then B.putStrLn outline else return ()
                            _ -> return ()
        ) `catches` [ Handler (\(e:: IOException) -> do
                        bStdErr <- hIsOpen stderr 
                        when bStdErr $
                            hPutStr stderr ("ERROR (Logging): " ++ show e ++ "\n"))
                    , Handler (\(FormatError st s:: FormatError) -> do 
                        case st of
                            _ -> 
                                appendFileWithMutex (logFileMutex lh) 
                                                    file 
                                                    (B.pack $ "ERRORk(Logging): " ++ s ++ "\n") 
                        loop
                              )]

data FormatError = FormatError (Maybe FormatState) String deriving (Show,Typeable)
instance Exception FormatError
    

log :: LogHandle -> B.ByteString -> IO ()
log lh s = do
    tid <- myThreadId
    let t = B.pack $ show tid
    atomically $ modifyTVar (logReplaceMap lh) (M.insert (tid,"%t") t)
    atomically $ modifyTVar (logReplaceMap lh) (M.insert (tid,"$t") t)
    atomically $ writeTBMQueue (logQ lh) (tid,s <> "\n")

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
    logfTags ::  LogHandle -> Maybe FormatState -> String -> [FormatTag] -> t

instance LogFType String where
    logfTags lh st formatstr args = uprintf st formatstr (reverse args)

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
asstr _ (FmtString  s x) = fromDyn x "<ERROR:ByteString Bug TODO>"
asstr _ (FmtInteger _ x) = x -- typeerror "String" "Integral"

typeerror fs t1 t2 = errorFmt fs $ "Type error: expected " ++ t1 ++ ", got " ++ t2 ++ "."

fmterror fs = errorFmt fs "Reached end of format string with args remaining."
argerror fs = errorFmt fs "Insufficient args for format string"

errorFmt fs s= throw (FormatError fs s)

instance LogFType (IO a) where
    logfTags lh state formatstr args = case state of
        Nothing -> do
            log lh (B.pack $ uprintf Nothing formatstr (reverse args)) 
            return undefined
        ms -> do
            log lh (B.pack $ uprintf ms formatstr (reverse args)) 
            return undefined

instance (Typeable a, Show a, LogFType t) => LogFType (a -> t) where
    logfTags lh state fmt args a = logfTags lh state fmt (mkFormatTag a : args)

logf :: LogFType r => LogHandle -> String -> r
logf lh fmtstr = logfTags lh Nothing fmtstr []


withLogH :: LogHandle -> (IO a) -> IO a
withLogH lh action = do
    bracket
            (startLogging lh)
            (\aid -> do
                stopLogging lh
                cancel aid       -- kill the thread
            )
            (\aid -> catch action (logException lh)
            )

withLog :: String -> (LogHandle -> IO a) -> IO a
withLog name action = do
    lh <- newLog name
    withLogH lh (action lh)

withLogFile :: String -> (LogHandle -> IO a) -> IO a
withLogFile name action = do
    lh <- newLogWithFile name
    withLogH lh (action lh)

withQuickLog :: String -> ((LogHandle,B.ByteString -> IO ()) -> IO a) -> IO a
withQuickLog name action = do
    lh <- newLog name
    withLogH lh (action (lh,log lh))

withQuickLogEquate :: String 
                   -> ((LogHandle,B.ByteString -> IO (),B.ByteString -> B.ByteString -> IO Bool) -> IO a) 
                   -> IO a
withQuickLogEquate name action = do
    lh <- newLog name
    withLogH lh (action (lh,log lh,equate lh))

withQuickLogEquateLogF name action = do
    lh <- newLog name
    withLogH lh (action (lh,log lh,equate lh,logf lh))

logException :: LogHandle -> SomeException -> IO a
logException lh e = do
    hPutStrLn stderr ("ERROR LogException " ++ show e)
    log lh (B.pack $ "ERROR: " ++ show (e::SomeException) ++ "\n")
    throw e

logToFile filename str = withLogFile filename (\lh -> log lh str)
