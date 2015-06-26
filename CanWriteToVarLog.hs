{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
module CanWriteToVarLog where
import System.IO.Temp
import System.IO
import Control.Exception
import System.IO.Error
import System.Directory
import System.Info (os)
import System.FilePath

canWriteToVarLog :: IO Bool
canWriteToVarLog = if not (isValid "/var/log") then return False else
#ifdef mingw32_HOST_OS
    return False
#else
    catch 
       (bracket (openTempFile "/var/log" "tmpXXX.txt")
                (\(f,h) -> hClose h >> removeFile f)
                (\(f,h) -> hPutStrLn h "Test" >> return True))
       (\(e::IOException) -> if isPermissionError e then return False else throw e)
#endif

