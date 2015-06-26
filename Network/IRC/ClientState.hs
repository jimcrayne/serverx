{-# LANGUAGE OverloadedStrings #-}
module Network.IRC.ClientState where

import Data.Time.Clock
import qualified Data.ByteString.Char8 as B

data AwaitCommand = USER
                  | CAP_END
                  | NICK
                  | PONG
                  -- NumericCmd Int

data RegisterState = UnRegistered { awaitingForRegistration :: [Expecting] , ipOrDomainName :: B.ByteString }
                   | Registered { username :: B.ByteString , prefix :: B.ByteString }

data Nick = NoneOrDefaultNick B.ByteString
          | Nick B.ByteString

data Expecting = Expect { expectedSince :: DiffTime
                        , timeout :: DiffTime
                        , expectedCommand :: AwaitCommand
                        }

data ClientState a = ClientState { registerState :: RegisterState
                                 , nick :: Nick
                                 , expecting  :: [Expecting]
                                 , connectionInfo :: Maybe a
                                 }

initialState time timeout = ClientState { registerState = UnRegistered [Expect time timeout USER] ""
                                , nick = NoneOrDefaultNick ""
                                , expecting = [] 
                                , connectionInfo = Nothing
                                }

clientState0 = initialState (-1) (-1)

