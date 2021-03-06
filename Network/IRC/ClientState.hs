{-# LANGUAGE OverloadedStrings #-}
module Network.IRC.ClientState where

import Data.Time.Clock
import qualified Data.ByteString.Char8 as B

data AwaitCommand = USER
                  | CAP_END
                  | NICK
                  | PONG deriving (Show,Eq)
                  -- NumericCmd Int

data RegisterState = UnRegistered { awaitingForRegistration :: [Expecting] 
                                  , ipOrDomainName :: B.ByteString 
                                  }
                   | UseredButWaiting { awaitingForRegistration :: [Expecting]
                                      , username :: B.ByteString
                                      , prefix :: B.ByteString
                                      , realname :: B.ByteString
                                      , ipOrDomainName :: B.ByteString 
                                      } 
                   | Registered { username :: B.ByteString 
                                , prefix :: B.ByteString
                                , realname :: B.ByteString 
                                , ipOrDomainName :: B.ByteString} deriving Show

data Nick = NoneOrDefaultNick B.ByteString
          | Nick B.ByteString deriving (Show,Eq)

data Expecting = Expect { expectedSince :: DiffTime
                        , timeout :: DiffTime
                        , expectedCommand :: AwaitCommand
                        } deriving (Show,Eq)

data ClientState a = ClientState { registerState :: RegisterState
                                 , nick :: Nick
                                 , expecting  :: [Expecting]
                                 , connectionInfo :: Maybe a
                                 } deriving Show

initialState time timeout = ClientState { registerState = UnRegistered [Expect time timeout USER] ""
                                , nick = NoneOrDefaultNick ""
                                , expecting = [] 
                                , connectionInfo = Nothing
                                }

clientState0 = initialState (-1) (-1)

