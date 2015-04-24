{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TemplateHaskell, BangPatterns, GeneralizedNewtypeDeriving, NamedFieldPuns, PatternGuards #-}

module Distribution.Server.Features.AdminLog where

import Distribution.Package
import Distribution.Server.Users.Types (UserId)
import Distribution.Server.Users.Group
import Distribution.Server.Framework
import Distribution.Server.Framework.BackupRestore

import Distribution.Server.Features.Core
import Distribution.Server.Features.Users

import Data.SafeCopy (base, deriveSafeCopy)
import Data.Typeable
import Data.Maybe(catMaybes)
import Control.Monad.Reader
import qualified Control.Monad.State as State
import Data.Time (UTCTime)
import Data.Time.Clock (getCurrentTime)
import qualified Data.ByteString.Lazy.Char8 as BS
import Text.Read (readMaybe)
import Distribution.Server.Util.Parse

data GroupDesc = MaintainerGroup PackageName | AdminGroup | TrusteeGroup | OtherGroup String deriving (Eq, Ord, Read, Show)

deriveSafeCopy 0 'base ''GroupDesc

instance MemSize GroupDesc where
    memSize (MaintainerGroup x) = memSize x
    memSize _ = 0

data AdminAction = Admin_GroupAddUser UserId GroupDesc | Admin_GroupDelUser UserId GroupDesc deriving (Eq, Ord, Read, Show)

instance MemSize AdminAction where
    memSize (Admin_GroupAddUser x y) = memSize2 x y
    memSize (Admin_GroupDelUser x y) = memSize2 x y

deriveSafeCopy 0 'base ''AdminAction

mkAdminAction :: GroupDescription -> Bool -> UserId -> AdminAction
mkAdminAction gd isAdd uid = (if isAdd then Admin_GroupAddUser else Admin_GroupDelUser) uid groupdesc
    where groupdesc | groupTitle gd == "Hackage admins" = AdminGroup
                    | groupTitle gd == "Package trustees" = TrusteeGroup
                    | Just (pn,_) <- groupEntity gd, groupTitle gd == "Maintainers" = MaintainerGroup (PackageName pn)
                    | otherwise = OtherGroup (groupTitle gd ++ maybe "" ((' ':) . fst) (groupEntity gd))

newtype AdminLog = AdminLog {
      adminLog :: [(UTCTime,UserId,AdminAction)]
} deriving (Typeable, Show, MemSize)

deriveSafeCopy 0 'base ''AdminLog

initialAdminLog :: AdminLog
initialAdminLog = AdminLog []

getAdminLog :: Query AdminLog AdminLog
getAdminLog = ask

addAdminLog :: (UTCTime, UserId, AdminAction) -> Update AdminLog ()
addAdminLog x = State.modify (\(AdminLog xs) -> AdminLog (x : xs))

instance Eq AdminLog where
    (AdminLog (x:_)) == (AdminLog (y:_)) = x == y
    (AdminLog []) == (AdminLog []) = True
    _ == _ = False

replaceAdminLog :: AdminLog -> Update AdminLog ()
replaceAdminLog = State.put

makeAcidic ''AdminLog ['getAdminLog
                      ,'replaceAdminLog
                      ,'addAdminLog]

data AdminLogFeature = AdminLogFeature {
      adminLogFeatureInterface :: HackageFeature
}

instance IsHackageFeature AdminLogFeature where
    getFeatureInterface = adminLogFeatureInterface

initAdminLogFeature :: ServerEnv -> IO (UserFeature -> CoreFeature -> IO AdminLogFeature)
initAdminLogFeature ServerEnv{serverStateDir} = do
  adminLogState <- adminLogStateComponent serverStateDir
  return $ \UserFeature{groupChangedHook} CoreFeature{coreResource} -> do
    registerHook groupChangedHook $ \(gd,addOrDel,actorUid,targetUid) -> do
        now <- getCurrentTime
        updateState adminLogState $ AddAdminLog
            (now, actorUid, mkAdminAction gd addOrDel targetUid)

    return $ AdminLogFeature {
       adminLogFeatureInterface =
           (emptyHackageFeature "Admin Actions Log") {
               featureDesc = "Log of additions and removals of users from groups.",
               featureResources = [adminLogResource coreResource adminLogState],
               featureState = [abstractAcidStateComponent adminLogState]
       }
    }

adminLogResource :: CoreResource -> StateComponent AcidState AdminLog -> Resource
adminLogResource coreResource logState = (extendResourcePath "/admin-log.:format" (corePackagesPage coreResource)) {
               resourceGet = [
                  ("html", \ _ -> do
                     adminLog <- queryState logState GetAdminLog
                     return . toResponse $ show adminLog)
                , ("rss", \ _ -> do
                     adminLog <- queryState logState GetAdminLog
                     return . toResponse $ show adminLog)
               ]
             }

adminLogStateComponent :: FilePath -> IO (StateComponent AcidState AdminLog)
adminLogStateComponent stateDir = do
  st <- openLocalStateFrom (stateDir </> "db" </> "AdminLog") initialAdminLog
  return StateComponent {
      stateDesc    = "AdminLog"
    , stateHandle  = st
    , getState     = query st GetAdminLog
    , putState     = update st . ReplaceAdminLog
    , backupState  = \_ (AdminLog xs) -> [BackupByteString ["adminLog.txt"] . backupLogEntries $ xs]
    , restoreState = restoreAdminLogBackup
    , resetState   = adminLogStateComponent
    }

restoreAdminLogBackup :: RestoreBackup AdminLog
restoreAdminLogBackup = go (AdminLog [])
    where go logs =
              RestoreBackup {
                   restoreEntry = \entry ->
                                  case entry of
                                    BackupByteString ["adminLog.txt"] bs ->
                                        return . go $ importLogs logs bs
                                    _ -> return (go logs)
                 , restoreFinalize = return logs
                 }

importLogs :: AdminLog -> BS.ByteString -> AdminLog
importLogs (AdminLog ls) = AdminLog . (++ls) . catMaybes . map fromRecord . lines . unpackUTF8
    where
      fromRecord :: String -> Maybe (UTCTime,UserId,AdminAction)
      fromRecord = readMaybe

backupLogEntries :: [(UTCTime,UserId,AdminAction)] -> BS.ByteString
backupLogEntries = packUTF8 . unlines . map show