{-# LANGUAGE DeriveDataTypeable, DeriveGeneric, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings, TemplateHaskell, TypeFamilies #-}
module Distribution.Server.Users.Types (
    module Distribution.Server.Users.Types,
    module Distribution.Server.Users.AuthToken,
    module Distribution.Server.Framework.AuthTypes
  ) where

import Distribution.Server.Framework.AuthTypes
import Distribution.Server.Framework.MemSize
import Distribution.Server.Users.AuthToken

import Distribution.Text
         ( Text(..) )
import qualified Distribution.Server.Util.Parse as Parse
import qualified Distribution.Compat.ReadP as Parse
import qualified Text.PrettyPrint          as Disp
import qualified Data.Char as Char
import qualified Data.Text as T
import qualified Data.Map as M

import Control.Applicative ((<$>))
import Control.Monad (mzero)
import Data.Aeson ((.:), (.=), ToJSON(..), FromJSON(..), Value(..), object)
import Data.SafeCopy (base, extension, deriveSafeCopy, Migrate(..))
import Data.Typeable (Typeable)
import Data.Hashable
import GHC.Generics


newtype UserId = UserId Int
  deriving (Eq, Ord, Read, Show, Typeable, MemSize, ToJSON, FromJSON)

newtype UserName  = UserName String
  deriving (Eq, Ord, Read, Show, Typeable, MemSize, ToJSON, FromJSON, Hashable)

data UserInfo = UserInfo {
                  userName   :: !UserName,
                  userStatus :: !UserStatus,
                  userTokens :: !(M.Map AuthToken T.Text) -- tokens and descriptions
                } deriving (Eq, Show, Typeable, Generic)

data UserStatus = AccountEnabled  UserAuth
                | AccountDisabled (Maybe UserAuth)
                | AccountDeleted
    deriving (Eq, Show, Typeable, Generic)

-- This ToJSON instance ignores the UserAuth component
-- so that password hashes are harder to leak
instance ToJSON UserStatus where
  toJSON (AccountEnabled _)  = String "AccountEnabled"
  toJSON (AccountDisabled _) = String "AccountDisabled"
  toJSON AccountDeleted      = String "AccountDeleted"

emptyAuth :: UserAuth
emptyAuth = UserAuth (PasswdHash "")

instance FromJSON UserInfo where
  parseJSON (Object o) =
    UserInfo <$> o .: "name" <*> o .: "status" <*> pure mempty
  parseJSON _ = mzero

instance ToJSON UserInfo where
  toJSON (UserInfo nm st _) = object ["name" .= nm, "status" .= st]

instance FromJSON UserStatus where
  parseJSON (String "AccountEnabled")  =
    return $ AccountEnabled emptyAuth
  parseJSON (String "AccountDisabled") =
    return $ AccountDisabled $ Just emptyAuth
  parseJSON (String "AccountDeleted")  =
    return $ AccountDeleted
  parseJSON _ = mzero


newtype UserAuth = UserAuth PasswdHash
    deriving (Show, Eq, Typeable)

isActiveAccount :: UserStatus -> Bool
isActiveAccount (AccountEnabled  _) = True
isActiveAccount (AccountDisabled _) = True
isActiveAccount  AccountDeleted     = False

instance MemSize UserInfo where
    memSize (UserInfo a b c) = memSize3 a b c

instance MemSize UserStatus where
    memSize (AccountEnabled  a) = memSize1 a
    memSize (AccountDisabled a) = memSize1 a
    memSize (AccountDeleted)    = memSize0

instance MemSize UserAuth where
    memSize (UserAuth a) = memSize1 a

instance Text UserId where
    disp (UserId uid) = Disp.int uid
    parse = UserId <$> Parse.int

instance Text UserName where
    disp (UserName name) = Disp.text name
    parse = UserName <$> Parse.munch1 isValidUserNameChar

isValidUserNameChar :: Char -> Bool
isValidUserNameChar c = (c < '\127' && Char.isAlphaNum c) || (c == '_')

data UserInfo_v0 = UserInfo_v0 {
                  userName_v0   :: !UserName,
                  userStatus_v0 :: !UserStatus
                } deriving (Eq, Show, Typeable)

instance Migrate UserInfo where
    type MigrateFrom UserInfo = UserInfo_v0
    migrate v0 =
        UserInfo
        { userName = userName_v0 v0
        , userStatus = userStatus_v0 v0
        , userTokens = M.empty
        }

$(deriveSafeCopy 0 'base ''UserId)
$(deriveSafeCopy 0 'base ''UserName)
$(deriveSafeCopy 1 'base ''UserAuth)
$(deriveSafeCopy 0 'base ''UserStatus)
$(deriveSafeCopy 0 'base ''UserInfo_v0)
$(deriveSafeCopy 1 'extension ''UserInfo)
