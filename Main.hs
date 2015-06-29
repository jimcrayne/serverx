{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}

-- Imports from elsewhere
import Prelude hiding (log)
import System.Environment
import Control.Exception --(throw,ArithException (..))
import qualified Data.ByteString.Char8 as B
import qualified Network.IRC as IRC
import qualified Data.Map as M
import Control.Concurrent.STM.TBMQueue
import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad
import Control.Monad.Loops
import Control.Concurrent.Async
import Data.Monoid
import System.IO.Temp
import Network.BSD
import Data.List
import Data.DateTime

-- Imports from this library/package...
import qualified System.IO.Log as Log
import Control.Concurrent.STM.TBMQueue.Multiplex
import Network.Server.Listen.TCP
import Network.IRC.ClientState
import Codec.LineReady
import IRCError
import IRCReply
import Data.Version
import Paths_serverx (version)

instance LineReady IRC.Message where
    type SerialError IRC.Message = String
    toLineReady = IRC.encode
    fromLineReady s = case IRC.decode s of
        Just x -> Right x
        Nothing -> Left ("IRC PARSE ERROR:'" <>  B.unpack s <> "'")

-- Type to use as the parameter to ClientState
-- it is stored in the connectionInfo field
type ConnectionInfo = (ThreadId, TBMQueue IRC.Message)
instance Show (TBMQueue IRC.Message) where
    show x = "<TBMQueue>"

-- | clientIsAccepting
--
--      @st     client state (it's message queue is tucked in to the connectionInfo field)
--
-- Is the client Accepting messages? 
-- We check it's message queue is open
clientIsAccepting :: ClientState ConnectionInfo -> STM Bool
clientIsAccepting (connectionInfo -> Just (_,x)) =  fmap not $ isClosedTBMQueue x
clientIsAccepting _ = return False

clientIsAcceptingIO :: ClientState ConnectionInfo -> IO Bool
clientIsAcceptingIO = atomically . clientIsAccepting

clientQ :: ClientState ConnectionInfo -> TBMQueue IRC.Message
clientQ (connectionInfo -> Just (_,x)) =  x 
clientQ _ = error "NO CLIENT QUEUE!"

type ClientId = ThreadId

data ServerState = ServerState { hostname :: B.ByteString
                               , serverStartDate :: DateTime
                               , motd :: [B.ByteString]}
-- | main
--
-- Program entry.
main = Log.withLog "" $ \lh -> do
    Log.enableEcho lh
    Log.setPrefix lh (B.pack "[%tid]:")
    let log = Log.log lh . B.pack
    starttime <- getCurrentTime
    hostname <- fmap B.pack getHostName
    -- TODO: load motd from config file.
    let motd = []
    let serverstate= ServerState hostname starttime motd
    -- Initialize Thread-Save Data
    newchans <- atomically $ newTBMQueue 20 :: IO (TBMQueue (ThreadId, TBMQueue IRC.Message))
    coutq <- atomically $ newTBMQueue 20 :: IO (TBMQueue IRC.Message)
    outq <- atomically $ newTBMQueue 20 :: IO (TBMQueue IRC.Message)
    connections <- atomically $ newTVar M.empty :: IO (TVar (M.Map ClientId (ClientState ConnectionInfo)))

    -- Start worker threads
    -- Send outq messages out to child connections
    --broadcaster <- async $ consumeQueueMicroseconds outq 5000 (broadcast connections)

    -- recieve messages from children in coutq and then log them before sending them back out
    listenAsync <- async $ do 
        log "Listening on port 4444..."
        createTCPPortListener 4444 "<SERVER-NAME>" 5000 20 20 
                              return newchans coutq B.hGetLine lineToIRC (ircReact serverstate connections)

    {- handleIncoming <- async . pipeHook coutq outq $ \msg -> do
        Log.log lh . B.pack . show $ msg
        Log.log lh . B.append "< " . IRC.encode $ msg -}

    newchanAsync <- async $ consumeQueueMicroseconds newchans 5000 (runNewClientConnection outq connections)

    
    -- Wait till done
    void $ waitAny [listenAsync,newchanAsync{-,broadcaster-}]
    
    
runNewClientConnection :: TBMQueue IRC.Message
                       -> TVar (M.Map ThreadId (ClientState ConnectionInfo)) 
                       -> (ThreadId,TBMQueue IRC.Message) -> IO ()

runNewClientConnection outq connmap (tid,chan) = Log.withLog "" $ \lh -> do
    let log s = Log.log lh s
    mtid <- myThreadId
    putStrLn (show mtid <> " " <> show (tid,"hello"::String))

    -- check for dead clients, this could be moved to 
    -- another thread really...
    (mp,closed) <- atomically $ do
        mp'unfiltered <- readTVar connmap
        closedKVals <- filterM (fmap not . clientIsAccepting . snd) (M.toList mp'unfiltered)
        let closedIds = map fst closedKVals
        modifyTVar connmap (M.filterWithKey (\k v -> not (k `elem` closedIds)))
        mp'filtered <- readTVar connmap
        return (mp'filtered,closedIds)

    let name = B.pack (filter (/=' ') $ show tid)
        welcomeMessage = ("Welcome!! New Connection: You are " <> name)
    log ("-> (" <> name <> ") " <> welcomeMessage)
    -- atomically $ writeTBMQueue chan (IRC.notify name welcomeMessage)
    let l = M.toList mp
    forM_ l $ \(i,clientQ -> c) -> do
        let entrance = IRC.privmsg "" ("* " <> name <> " enters.")
        log (B.append "@" $ IRC.encode entrance)
        atomically $ writeTBMQueue c entrance
        forM_ closed $ \closedTid -> do
            let exit = (IRC.privmsg "" ("* " <>B.pack (show closedTid) <> " exits."))
            log (B.append "@" $ IRC.encode exit)
            atomically $ writeTBMQueue c exit
         
    atomically $ modifyTVar connmap (M.insert tid $ clientState0 { connectionInfo = Just (tid,chan)
                                                                 , nick=NoneOrDefaultNick name })

broadcast connections msg =  Log.withLog "" $ \lh -> do
    mp <- atomically $ readTVar connections
    Log.enableEcho lh
    forM_ (M.elems mp) $ \q -> do
        Log.log lh (" > (All conns) " <> IRC.encode msg)
        atomically $ writeTBMQueue q msg
    
lineToIRC line = 
        case IRC.decode line of
            Just m -> m
            Nothing | "/q" `B.isPrefixOf` line -> IRC.quit (Just line)
            Nothing -> IRC.Message Nothing "PARSE_ERROR" [line]

msg_command = IRC.msg_command
msg_params = IRC.msg_params
msg_prefix = IRC.msg_prefix

ircReact serv@(ServerState hostname datetime motd0) cons clientId msg = Log.withQuickLogEquate "" $ \(lh,log,equate) -> do
  client <- fmap lookupState . atomically $ readTVar cons
  let Just (_,replyq) = connectionInfo client
  let reply cmd params = atomically $ writeTBMQueue replyq (IRC.Message { IRC.msg_prefix=Just (IRC.Server hostname)
                                                                    , IRC.msg_command=cmd
                                                                    , IRC.msg_params=params
                                                                    })
  equate "%cli" (B.pack $ show clientId)
  equate "%msg" (B.pack $ show msg)
  equate "%nick" (getnick client)
  case registerState client of
    UnRegistered awaiting ip -> do
        log "%nick UNREGISTERED> %msg"
        case (msg_command msg,msg_params msg) of
            ("QUIT", msg ) -> do
                log "%nick: %msg"
                atomically $ closeTBMQueue replyq
            ("NICK", [newnick]) -> setState client {nick = Nick newnick}

            ("USER", [user,modereq,servunused,realname]) | not (null awaiting) -> do
                let prefix = getnick client <> "!" <> user <> "@" <> hostname
                    awaiting0 = filter ((/=USER).expectedCommand) awaiting
                if null awaiting0 then do
                    setState client {registerState = Registered user prefix realname ip}
                    sendWelcome reply serv user prefix realname ip hostname
                else
                    setState client {registerState = UseredButWaiting awaiting0 user prefix realname ip}

            ("USER", [user,modereq,servunused,realname]) | null awaiting -> do
                let prefix = getnick client <> "!" <> user <> "@" <> hostname
                setState client {registerState = Registered user prefix realname ip}
                sendWelcome reply serv user prefix realname ip hostname


            ("CAP",["LS"]) -> do
                let r0 = registerState client
                    a1 = union [Expect (-1) (-1) CAP_END] awaiting
                    r1 = r0 { awaitingForRegistration = a1}
                setState client {registerState = r1 }
                reply "CAP" ["*","LS",""]

            ("CAP",["END"]) | CAP_END `elem` map expectedCommand awaiting 
                                        -> let r0 = registerState client
                                               a1 = filter ((/=CAP_END) . expectedCommand) awaiting
                                               r1 = r0 { awaitingForRegistration = a1}
                                               in setState client {registerState = r1 }
            ("CAP",_ ) -> log "Unimplemented command: %msg"

            _ | not (null $ awaitingForRegistration (registerState client)) -> 
                reply err_NOTREGISTERED ["You have not registered"]

    UseredButWaiting awaiting user prefix realname ip -> do
        log "%nick USERedButWaiting> %msg"
        case (msg_command msg,msg_params msg) of
            ("QUIT", msg ) -> do
                log "%nick: %msg"
                atomically $ closeTBMQueue replyq
            ("NICK", [newnick]) -> do
                let r=registerState client
                setState client {nick = Nick newnick, registerState = r {prefix=updateprefix newnick prefix} }

            ("USER", [user,modereq,servunused,realname]) | not (null awaiting) -> do
                let prefix = getnick client <> "!" <> user <> "@" <> hostname
                    awaiting0 = filter ((/=USER).expectedCommand) awaiting
                if null awaiting0 then do
                    setState client {registerState = Registered user prefix realname ip}
                    sendWelcome reply serv user prefix realname ip hostname
                else
                    setState client {registerState = UseredButWaiting awaiting0 user prefix realname ip}

            ("USER", [user,modereq,servunused,realname]) | null awaiting -> do
                let prefix = getnick client <> "!" <> user <> "@" <> hostname
                setState client {registerState = Registered user prefix realname ip}
                sendWelcome reply serv user prefix realname ip hostname

            ("CAP",["LS"]) -> do
                let r0 = registerState client
                    a1 = union [Expect (-1) (-1) CAP_END] awaiting
                    r1 = r0 { awaitingForRegistration = a1}
                setState client {registerState = r1 }
                reply "CAP" ["*","LS",""]

            ("CAP",["END"]) | CAP_END `elem` map expectedCommand awaiting -> do
                let r0 = registerState client
                    a1 = filter ((/=CAP_END) . expectedCommand) awaiting
                    r1 = r0 { awaitingForRegistration = a1}
                if (null a1) then do
                     setState client {registerState = Registered user prefix realname ip}
                     sendWelcome reply serv user prefix realname ip hostname
                else setState client {registerState = r1 }
            ("CAP",_ ) -> log "Unimplemented command: %msg"

            _ | not (null $ awaitingForRegistration (registerState client)) -> 
                reply err_NOTREGISTERED ["You have not registered"]

    Registered user prefix realname ip -> do
        equate "%user" user
        equate "%prefix" prefix
        let nick = B.takeWhile (/='!') prefix
        let feedback cmd params = atomically $ writeTBMQueue replyq (IRC.Message 
                        { IRC.msg_prefix=Just (IRC.NickName nick 
                                                            (Just user) 
                                                            (Just (B.drop 1 . B.dropWhile (/='@') $ prefix)))
                        , IRC.msg_command=cmd
                        , IRC.msg_params=params
                        })
        case (msg_command msg, msg_params msg) of
            ("QUIT", msg ) -> do
                log "%nick: %msg"
                atomically $ closeTBMQueue replyq
            ("NICK", [newnick]) -> do
                let r=registerState client
                setState client {nick = Nick newnick, registerState = r {prefix=updateprefix newnick prefix} }
                feedback "NICK" [newnick]
            ("CAP",["LS"]) -> do
                reply "CAP" [nick,"LS",""]
            ("MOTD",[]) -> do
                postMotd reply nick serv hostname
            ("MOTD",[s]) | s == hostname -> do -- TODO: RFC says Support Wildcards...
                postMotd reply nick serv hostname
            ("MOTD",_) -> do -- TODO: RFC says Support Wildcards...
                    reply err_UNKNOWNCOMMAND [nick, "MOTD parameters not fully supported. No Wildcards. No remote servers."]
            ("PARSE_ERROR",xs) -> do 
                    -- TODO: perhaps we should just upcase the command before parsing..
                    reply err_UNKNOWNCOMMAND [nick, 
                            "PARSE ERROR: " <> (B.pack . show $ xs) <> " (Did you use capital letters?)"]
            ("PING", [s]) -> do
                feedback "PONG" [s]
            (cmd,_) -> do
                    log "%nick> %msg"
                    reply err_UNKNOWNCOMMAND [nick, cmd <> " command is not implemented."]
  clients <- atomically $ readTVar cons
  log (B.pack $ show (lookupState clients))
  Log.clearEquates lh 
    where 
        lookupState clients =
            case M.lookup clientId clients of
                Just cs -> cs
                _ -> clientState0 -- ignored, but this will type check

        updateState f = atomically $ modifyTVar cons (M.update f clientId) 
        setState :: ClientState ConnectionInfo -> IO ()
        setState cs = updateState (const (Just cs))
        getnick cs = case nick cs of
            NoneOrDefaultNick s -> s
            Nick s -> s

        updateprefix nick prefix = nick <> B.dropWhile (/='!') prefix
        sendWelcome reply0 serv user prefix realname ip hostname = do
           let reply cmd params= reply0 cmd (nick:params)
               nick = B.takeWhile (/='!') prefix
               vstr = B.pack (showVersion version)
               datestr = B.pack $ 
                            formatDateTime "This server was created %a %Y-%m-%d at %H:%M:%S %Z" (serverStartDate serv)
           progname <- fmap B.pack getProgName
           let progverstr = progname <> "-" <> vstr
           reply "001" {- RPL_WELCOME -}
                 [("Welcome to the Internet Relay Network " <> prefix)]
           reply "002" {- RPL_YOURHOST -}
                 [("Your host is " <> hostname <> ", running version " <> progverstr)]
           reply "003" {- RPL_CREATED -}
                 [datestr] 
           reply "004" {- RPL_MYINFO -}
                 [progname <> " " <> vstr <> " " <> {-available user modes>-} " "  {- available channel modes -} ]
           postMotd reply0 nick serv hostname

        postMotd reply0 nick serv hostname = do
            let reply cmd params = reply0 cmd (nick:params)
            reply rpl_MOTDSTART [hostname <> " Message of the Day -"]
            forM_ (motd serv) $ \line -> reply rpl_MOTD [line]
            reply rpl_ENDOFMOTD ["End of /MOTD command."]
           
