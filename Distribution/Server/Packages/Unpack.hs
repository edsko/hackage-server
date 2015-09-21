-- Unpack a tarball containing a Cabal package
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Distribution.Server.Packages.Unpack (
    CombinedTarErrs(..),
    checkEntries,
    checkUselessPermissions,
    unpackPackage,
    unpackPackageRaw,
  ) where

import qualified Codec.Archive.Tar       as Tar
import qualified Codec.Archive.Tar.Entry as Tar
import qualified Codec.Archive.Tar.Check as Tar

import Distribution.Version
         ( Version(..) )
import Distribution.Package
         ( PackageIdentifier, packageVersion, packageName, PackageName(..) )
import Distribution.PackageDescription
         ( GenericPackageDescription(..), PackageDescription(..)
         , exposedModules )
import Distribution.PackageDescription.Parse
         ( parsePackageDescription )
import Distribution.PackageDescription.Configuration
         ( flattenPackageDescription )
import Distribution.PackageDescription.Check
         ( PackageCheck(..), checkPackage )
import Distribution.ParseUtils
         ( ParseResult(..), locatedErrorMsg, showPWarning )
import Distribution.Text
         ( display, simpleParse )
import Distribution.ModuleName
         ( components )
import Distribution.Server.Util.Parse
         ( unpackUTF8 )
import Distribution.License
         ( License(..) )

import Control.Applicative
import Control.Monad
         ( unless, when )
import Control.Monad.Except
         ( ExceptT, runExceptT, MonadError, throwError )
import Control.Monad.Identity
         ( Identity(..) )
import Control.Monad.Writer
         ( WriterT(..), MonadWriter, tell )
import Data.Bits
         ( (.&.) )
import Data.ByteString.Lazy
         ( ByteString )
import qualified Data.ByteString.Lazy as LBS
import Data.List
         ( nub, (\\), partition, intercalate )
import Data.Maybe
         ( isJust )
import Data.Time
         ( UTCTime(..), fromGregorian, addUTCTime )
import Data.Time.Clock.POSIX
         ( posixSecondsToUTCTime )
import qualified Distribution.Server.Util.GZip as GZip
import System.FilePath
         ( (</>), (<.>), splitDirectories, splitExtension, normalise )
import qualified System.FilePath.Windows
         ( takeFileName )
import Text.Printf
         ( printf )

-- Whether to allow upload of "all rights reserved" packages
allowAllRightsReserved :: Bool
allowAllRightsReserved = True

-- | Upload or check a tarball containing a Cabal package.
-- Returns either an fatal error or a package description and a list
-- of warnings.
unpackPackage :: UTCTime -> FilePath -> ByteString
              -> Either String
                        ((GenericPackageDescription, ByteString), [String])
unpackPackage now tarGzFile contents =
  runUploadMonad $ do
    (pkgDesc, warnings, cabalEntry) <- basicChecks False now tarGzFile contents
    mapM_ throwError warnings
    extraChecks pkgDesc
    return (pkgDesc, cabalEntry)

unpackPackageRaw :: FilePath -> ByteString
                 -> Either String
                           ((GenericPackageDescription, ByteString), [String])
unpackPackageRaw tarGzFile contents =
  runUploadMonad $ do
    (pkgDesc, _warnings, cabalEntry) <- basicChecks True noTime tarGzFile contents
    return (pkgDesc, cabalEntry)
  where
    noTime = UTCTime (fromGregorian 1970 1 1) 0

basicChecks :: Bool -> UTCTime -> FilePath -> ByteString
            -> UploadMonad (GenericPackageDescription, [String], ByteString)
basicChecks lax now tarGzFile contents = do
  let (pkgidStr, ext) = (base, tar ++ gz)
        where (tarFile, gz) = splitExtension (portableTakeFileName tarGzFile)
              (base,   tar) = splitExtension tarFile
  unless (ext == ".tar.gz") $
    throwError $ tarGzFile ++ " is not a gzipped tar file, it must have the .tar.gz extension"

  pkgid <- case simpleParse pkgidStr of
    Just pkgid
      | null . versionBranch . packageVersion $ pkgid
      -> throwError $ "Invalid package id " ++ quote pkgidStr
                   ++ ". It must include the package version number, and not just "
                   ++ "the package name, e.g. 'foo-1.0'."

      | display pkgid == pkgidStr -> return (pkgid :: PackageIdentifier)

      | not . null . versionTags . packageVersion $ pkgid
      -> throwError $ "Hackage no longer accepts packages with version tags: "
                   ++ intercalate ", " (versionTags (packageVersion pkgid))
    _ -> throwError $ "Invalid package id " ++ quote pkgidStr
                   ++ ". The tarball must use the name of the package."

  -- Extract entries and check the tar format / portability
  let entries = tarballChecks lax now expectedDir
              $ Tar.read (GZip.decompressNamed tarGzFile contents)
      expectedDir = display pkgid

  -- Extract the .cabal file from the tarball
  let selectEntry entry = case Tar.entryContent entry of
        Tar.NormalFile bs _ | cabalFileName == normalise (Tar.entryPath entry)
                           -> Just bs
        _                  -> Nothing
      PackageName name  = packageName pkgid
      cabalFileName     = display pkgid </> name <.> "cabal"
  cabalEntries <- selectEntries explainTarError selectEntry entries
  cabalEntry   <- case cabalEntries of
    -- NB: tar files *can* contain more than one entry for the same filename.
    -- (This was observed in practice with the package CoreErlang-0.0.1).
    -- In this case, after extracting the tar the *last* file in the archive
    -- wins. Since selectEntries returns results in reverse order we use the head:
    cabalEntry:_ -> -- We tend to keep hold of the .cabal file, but
                    -- cabalEntry itself is part of a much larger
                    -- ByteString (the whole tar file), so we make a
                    -- copy of it
                    return $ LBS.copy cabalEntry
    [] -> throwError $ "The " ++ quote cabalFileName
                    ++ " file is missing from the package tarball."

  when (startsWithBOM cabalEntry) $
    throwError $ "The cabal file starts with a Unicode byte order mark (BOM), "
              ++ "which causes problems for older versions of cabal. Please "
              ++ "save the package's cabal file as UTF8 without the BOM."

  -- Parse the Cabal file
  let cabalFileContent = unpackUTF8 cabalEntry
  (pkgDesc, warnings) <- case parsePackageDescription cabalFileContent of
    ParseFailed err -> throwError $ showError (locatedErrorMsg err)
    ParseOk warnings pkgDesc ->
      return (pkgDesc, map (showPWarning cabalFileName) warnings)

  -- Check that the name and version in Cabal file match
  when (packageName pkgDesc /= packageName pkgid) $
    throwError "Package name in the cabal file does not match the file name."
  when (packageVersion pkgDesc /= packageVersion pkgid) $
    throwError "Package version in the cabal file does not match the file name."

  return (pkgDesc, warnings, cabalEntry)

  where
    showError (Nothing, msg) = msg
    showError (Just n, msg) = "line " ++ show n ++ ": " ++ msg

-- | The issue is that browsers can upload the file name using either unix
-- or windows convention, so we need to take the basename using either
-- convention. Since windows allows the unix '/' as a separator then we can
-- use the Windows.takeFileName as a portable solution.
--
portableTakeFileName :: FilePath -> String
portableTakeFileName = System.FilePath.Windows.takeFileName

-- Miscellaneous checks on package description
extraChecks :: GenericPackageDescription -> UploadMonad ()
extraChecks genPkgDesc = do
  let pkgDesc = flattenPackageDescription genPkgDesc
  -- various checks

  --FIXME: do the content checks. The dev version of Cabal generalises
  -- checkPackageContent to work in any monad, we just need to provide
  -- a record of ops that will do checks inside the tarball. We should
  -- gather a map of files and dirs and have these just to map lookups:
  --
  -- > checkTarballContents = CheckPackageContentOps {
  -- >   doesFileExist      = Set.member fileMap,
  -- >   doesDirectoryExist = Set.member dirsMap
  -- > }
  -- > fileChecks <- checkPackageContent checkTarballContents pkgDesc

  let pureChecks = checkPackage genPkgDesc (Just pkgDesc)
      checks = pureChecks -- ++ fileChecks
      isDistError (PackageDistSuspicious {}) = False -- warn without refusing
      isDistError _                          = True
      (errors, warnings) = partition isDistError checks
  mapM_ (throwError . explanation) errors
  mapM_ (warn . explanation) warnings

  -- Proprietary License check (only active in central-server branch)
  when (not allowAllRightsReserved && license pkgDesc == AllRightsReserved) $
    throwError $ "This server does not accept packages with 'license' "
              ++ "field set to AllRightsReserved."

  -- Check for an existing x-revision
  when (isJust (lookup "x-revision" (customFieldsPD pkgDesc))) $
    throwError $ "Newly uploaded packages must not specify the 'x-revision' "
              ++ "field in their .cabal file. This is only used for "
              ++ "post-release revisions."

  -- Check reasonableness of names of exposed modules
  let topLevel = case library pkgDesc of
                 Nothing -> []
                 Just l ->
                     nub $ map head $ filter (not . null) $ map components $ exposedModules l
      badTopLevel = topLevel \\ allocatedTopLevelNodes

  unless (null badTopLevel) $
          warn $ "Exposed modules use unallocated top-level names: " ++
                          unwords badTopLevel

-- Monad for uploading packages:
--      WriterT for warning messages
--      Either for fatal errors
newtype UploadMonad a = UploadMonad (WriterT [String] (ExceptT String Identity) a)
  deriving (Functor, Applicative, Monad, MonadWriter [String], MonadError String)

warn :: String -> UploadMonad ()
warn msg = tell [msg]

runUploadMonad :: UploadMonad a -> Either String (a, [String])
runUploadMonad (UploadMonad m) = runIdentity . runExceptT . runWriterT $ m

-- | Registered top-level nodes in the class hierarchy.
allocatedTopLevelNodes :: [String]
allocatedTopLevelNodes = [
        "Algebra", "Codec", "Control", "Data", "Database", "Debug",
        "Distribution", "DotNet", "Foreign", "Graphics", "Language",
        "Network", "Numeric", "Prelude", "Sound", "System", "Test", "Text"]

selectEntries :: forall err a.
                 (err -> String)
              -> (Tar.Entry -> Maybe a)
              -> Tar.Entries err
              -> UploadMonad [a]
selectEntries formatErr select = extract []
  where
    extract :: [a] -> Tar.Entries err -> UploadMonad [a]
    extract _        (Tar.Fail err)           = throwError (formatErr err)
    extract selected  Tar.Done                = return selected
    extract selected (Tar.Next entry entries) =
      case select entry of
        Nothing    -> extract          selected  entries
        Just saved -> extract (saved : selected) entries

data CombinedTarErrs =
     FormatError      Tar.FormatError
   | PortabilityError Tar.PortabilityError
   | TarBombError     FilePath FilePath
   | FutureTimeError  FilePath UTCTime
   | PermissionsError FilePath Tar.Permissions

tarballChecks :: Bool -> UTCTime -> FilePath
              -> Tar.Entries Tar.FormatError
              -> Tar.Entries CombinedTarErrs
tarballChecks lax now expectedDir =
    (if not lax then checkFutureTimes now else id)
  . checkTarbomb expectedDir
  . checkUselessPermissions
  . (if lax then ignoreShortTrailer
            else fmapTarError (either id PortabilityError)
               . Tar.checkPortability)
  . fmapTarError FormatError
  where
    ignoreShortTrailer =
      Tar.foldEntries Tar.Next Tar.Done
                      (\e -> case e of
                               FormatError Tar.ShortTrailer -> Tar.Done
                               _                            -> Tar.Fail e)
    fmapTarError f = Tar.foldEntries Tar.Next Tar.Done (Tar.Fail . f)

checkFutureTimes :: UTCTime
                 -> Tar.Entries CombinedTarErrs
                 -> Tar.Entries CombinedTarErrs
checkFutureTimes now =
    checkEntries checkEntry
  where
    -- Allow 30s for client clock skew
    now' = addUTCTime 30 now
    checkEntry entry
      | entryUTCTime > now'
      = Just (FutureTimeError posixPath entryUTCTime)
      where
        entryUTCTime = posixSecondsToUTCTime (realToFrac (Tar.entryTime entry))
        posixPath    = Tar.fromTarPathToPosixPath (Tar.entryTarPath entry)

    checkEntry _ = Nothing

checkTarbomb :: FilePath -> Tar.Entries CombinedTarErrs -> Tar.Entries CombinedTarErrs
checkTarbomb expectedTopDir =
    checkEntries checkEntry
  where
    checkEntry entry =
      case splitDirectories (Tar.entryPath entry) of
        (topDir:_) | topDir == expectedTopDir -> Nothing
        _ -> Just $ TarBombError (Tar.entryPath entry) expectedTopDir

checkUselessPermissions :: Tar.Entries CombinedTarErrs -> Tar.Entries CombinedTarErrs
checkUselessPermissions =
    checkEntries checkEntry
  where
    checkEntry entry =
      case Tar.entryContent entry of
        (Tar.NormalFile _ _) -> checkPermissions 0o644 (Tar.entryPermissions entry)
        (Tar.Directory) -> checkPermissions 0o755 (Tar.entryPermissions entry)
        _ -> Nothing
      where
        checkPermissions expected actual =
            if expected .&. actual /= expected
                then Just $ PermissionsError (Tar.entryPath entry) actual
                else Nothing


checkEntries :: (Tar.Entry -> Maybe e) -> Tar.Entries e -> Tar.Entries e
checkEntries checkEntry =
  Tar.foldEntries (\entry rest -> maybe (Tar.Next entry rest) Tar.Fail
                                        (checkEntry entry))
                  Tar.Done Tar.Fail

explainTarError :: CombinedTarErrs -> String
explainTarError (TarBombError filename expectedDir) =
    "Bad file name in package tarball: " ++ quote filename
 ++ "\nAll the file in the package tarball must be in the subdirectory "
 ++ quote expectedDir ++ "."
explainTarError (PortabilityError (Tar.NonPortableFormat Tar.GnuFormat)) =
    "This tarball is in the non-standard GNU tar format. "
 ++ "For portability and long-term data preservation, hackage requires that "
 ++ "package tarballs use the standard 'ustar' format. If you are using GNU "
 ++ "tar, use --format=ustar to get the standard portable format."
explainTarError (PortabilityError (Tar.NonPortableFormat Tar.V7Format)) =
    "This tarball is in the old Unix V7 tar format. "
 ++ "For portability and long-term data preservation, hackage requires that "
 ++ "package tarballs use the standard 'ustar' format. Virtually all tar "
 ++ "programs can now produce ustar format (POSIX 1988). For example if you "
 ++ "are using GNU tar, use --format=ustar to get the standard portable format."
explainTarError (PortabilityError (Tar.NonPortableFormat Tar.UstarFormat)) =
    error "explainTarError: impossible UstarFormat"
explainTarError (PortabilityError Tar.NonPortableFileType) =
    "The package tarball contains a non-portable entry type. "
 ++ "For portability, package tarballs should use the 'ustar' format "
 ++ "and only contain normal files, directories and file links."
explainTarError (PortabilityError (Tar.NonPortableEntryNameChar _)) =
    "The package tarball contains an entry with a non-ASCII file name. "
 ++ "For portability, package tarballs should contain only ASCII file names "
 ++ "(e.g. not UTF8 encoded Unicode)."
explainTarError (PortabilityError (err@Tar.NonPortableFileName {})) =
    show err
 ++ ". For portability, hackage requires that file names be valid on both Unix "
 ++ "and Windows systems, and not refer outside of the tarball."
explainTarError (FormatError formateror) =
    "There is an error in the format of the tar file: " ++ show formateror
 ++ ". Check that it is a valid tar file (e.g. 'tar -xtf thefile.tar'). "
 ++ "You may need to re-create the package tarball and try again."
explainTarError (FutureTimeError entryname time) =
    "The tarball entry " ++ quote entryname ++ " has a file timestamp that is "
 ++ "in the future (" ++ show time ++ "). This tends to cause problems "
 ++ "for build systems and other tools, so hackage does not allow it. This "
 ++ "problem can be caused by having a misconfigured system time, or by bugs "
 ++ "in the tools (tarballs created by 'cabal sdist' on Windows with "
 ++ "cabal-install-1.18.0.2 or older have this problem)."
explainTarError (PermissionsError entryname mode) =
    "The tarball entry " ++ quote entryname ++ " has file permissions that are "
 ++ "broken: " ++ (showMode mode) ++ ". Permissions must be 644 at a minimum "
 ++ "for files and 755 for directories."
  where
    showMode :: Tar.Permissions -> String
    showMode m = printf "%.3o" (fromIntegral m :: Int)

quote :: String -> String
quote s = "'" ++ s ++ "'"

-- | Whether a UTF8 BOM is at the beginning of the input
startsWithBOM :: ByteString -> Bool
startsWithBOM bs = LBS.take 3 bs == LBS.pack [0xEF, 0xBB, 0xBF]
