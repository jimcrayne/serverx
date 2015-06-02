module InterruptableDelay where

import Control.Concurrent
import Control.Monad
import Control.Exception ({-evaluate,-}handle,ErrorCall(..))

type Microseconds = Int

data InterruptableDelay = InterruptableDelay 
        { delayThread :: MVar ThreadId
        }

interruptableDelay :: IO InterruptableDelay
interruptableDelay = do
    fmap InterruptableDelay newEmptyMVar

startDelay :: InterruptableDelay -> Microseconds -> IO Bool
startDelay d interval = do
    thread <- myThreadId
    handle (\(ErrorCall _)-> do
                debugNoise $ "delay interrupted"
                return False) $ do 
        putMVar (delayThread d) thread
        threadDelay interval
        void $ takeMVar (delayThread d)
        return True

  where debugNoise str = return ()


interruptDelay :: InterruptableDelay -> IO ()
interruptDelay d = do
    mthread <- do
        tryTakeMVar (delayThread d)
    flip (maybe $ return ()) mthread $ \thread -> do
    throwTo thread (ErrorCall "Interrupted delay")

