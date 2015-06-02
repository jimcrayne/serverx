{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ExistentialQuantification #-}
module Merv.Log where
    
import Prelude hiding (log)
import System.IO
import System.Directory
import System.FilePath

import Text.Printf
import Data.String
import Data.String.ToString
import System.IO.Unsafe (unsafePerformIO)
import Control.Concurrent.STM.TBMQueue
import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad.Loops
import Control.Exception

import qualified Data.ByteString.Char8 as B
import System.Environment (getProgName)
import Data.Monoid

import Data.Typeable
import Data.Dynamic
import Data.Word 
import System.Environment (getArgs)
import Control.Concurrent
import Control.Concurrent.Async
import Control.Monad

globalLogQ :: TBMQueue B.ByteString
globalLogQ = unsafePerformIO (newTBMQueueIO 400)
{-# NOINLINE globalLogQ #-}

startLoggingQueue file logq shutdownTMVar = async $ catch (do
        whileM_ (atomically . fmap not . isClosedTBMQueue $ logq) $ do
            done <- atomically $ tryReadTMVar shutdownTMVar
            case done of 
                Just () -> atomically $ closeTBMQueue logq
                Nothing -> do
                    whileM_ (atomically $ isEmptyTBMQueue logq) (threadDelay 2000)
                    whileM_ (atomically . fmap not $ isEmptyTBMQueue logq) $ do
                        x <- atomically $ readTBMQueue logq
                        case x of
                            Just s -> B.appendFile file s
                            _ -> return ()
    ) (\e -> appendFile file ("ERROR: " ++ show (e::SomeException) ++ "\n"))
    
startLogging logfile = startLoggingQueue logfile globalLogQ globalShutdownLogging

log :: B.ByteString -> IO ()
log s = atomically $ writeTBMQueue globalLogQ (s <> "\n")

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
    logfTags ::  String -> [FormatTag] -> t

instance LogFType String where
    logfTags formatstr args = uprintf formatstr (reverse args)

uprintf :: String -> [FormatTag] -> String
uprintf ""         []     = ""
uprintf ""         _      = fmterror
uprintf ('%':_:_ ) []     = argerror
uprintf ('%':c:cs) (u:us) = fmt c u ++ uprintf cs us
uprintf ( c :cs   ) us    = c : uprintf cs us

fmt :: Char -> FormatTag -> String
fmt 'd' u = asint u
fmt 's' u = asstr u

asint (FmtInteger i x) = x
asint (FmtString  _ _) = typeerror "Integral" "String"

asstr :: FormatTag -> String
asstr (FmtString  s x) = fromDyn x ""
asstr (FmtInteger _ x) = x -- typeerror "String" "Integral"

typeerror t1 t2 = error $ "Type error: expected " ++ t1 ++ ", got " ++ t2 ++ "."

fmterror = error "Reached end of format string with args remaining."
argerror = error "Insufficient args for format string"

instance LogFType (IO a) where
    logfTags formatstr args = catch (log (B.pack $ uprintf formatstr (reverse args)) >> return undefined)
                                    (\e -> log (B.pack (show (e::SomeException))) >> return undefined)

instance (Typeable a, Show a, LogFType t) => LogFType (a -> t) where
    logfTags fmt args a = logfTags fmt (mkFormatTag a : args)

logf :: LogFType r => String -> r
logf fmtstr = logfTags fmtstr []

globalShutdownLogging :: TMVar ()
globalShutdownLogging = unsafePerformIO $ newEmptyTMVarIO
{-# NOINLINE globalShutdownLogging #-}

withLog :: String -> (IO ()) -> IO ()
withLog name action = do
    appName <- getProgName
    appDir <- getAppUserDataDirectory appName
    createDirectoryIfMissing True appDir
    let logFile = case name of
                    "" -> (appDir </> appName ++ ".log")
                    _ -> (appDir </> appName ++ "." ++ name ++ ".log")
    bracket 
            (startLogging logFile) 
            (\aid -> do
                threadDelay 10000 -- time to print any exceptions
                atomically $ closeTBMQueue globalLogQ
                threadDelay 1000 -- give it a chance to shutdown itself
                cancel aid       -- kill the thread
            )
            (\aid -> (do
                --link aid
                catch action logException
                wait aid
            ))
                
        
    where
        waitForLog x = do
            whileM (fmap not . atomically $ isEmptyTBMQueue globalLogQ) (threadDelay 5000)
            atomically $ closeTBMQueue globalLogQ
            return x
        logException e = do
            log (B.pack $ "ERROR: " ++ show (e::SomeException) ++ "\n")
            throw e

-- | runPersonality 
-- Entrypoint
-- takes the place of Main
-- argument is getArgs
--
runPersonality :: [String] -> IO ()
runPersonality args = withLog "person" $ do
    print args
    let x = 2::Int
    logf " OK %s?" ("test"::String) 
    logf "X=%s Y=%d" x (4::Integer)
    logf "J=%s N=%s" (Just (4::Integer)) (" "::String) :: IO ()
    logf "PERMITED? %s===2" x
    logf "TESTING (--x = %s--) LOG ABILITY, args= %s" x args
    args' <- getArgs
    logf "getARgs -> %d" args'
    printf "getARgs %d " (show args')


