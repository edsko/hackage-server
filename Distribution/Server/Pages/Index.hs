-- Generate an HTML page listing all available packages

module Distribution.Server.Pages.Index (packageIndex) where

import Distribution.Server.Pages.Template       ( hackagePage )

import Distribution.Package
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
                                ( flattenPackageDescription )
import qualified Distribution.Server.Packages.PackageIndex as PackageIndex
import Distribution.Server.Packages.Types
import Distribution.Simple.Utils (comparing, equating)
import Distribution.ModuleName (toFilePath)

import Text.XHtml.Strict hiding ( p, name )
import qualified Text.XHtml.Strict as XHtml ( name )

import Data.Char (toLower, toUpper, isSpace)
import Data.List (intersperse, sortBy, groupBy, nub, maximumBy)


packageIndex :: PackageIndex.PackageIndex PkgInfo -> Html
packageIndex = formatPkgGroups
                 . map (mkPackageIndexInfo
                      . flattenPackageDescription
                      . pkgDesc
                      . maximumBy (comparing packageVersion))
                 . PackageIndex.allPackagesByName

data PackageIndexInfo = PackageIndexInfo {
                            pii_pkgName :: !PackageName,
                            pii_categories :: ![Category],
                            pii_hasLibrary :: !Bool,
                            pii_numExecutables :: !Int,
                            pii_synopsis :: !String
                        }

mkPackageIndexInfo :: PackageDescription -> PackageIndexInfo
mkPackageIndexInfo pd = PackageIndexInfo {
                            pii_pkgName = pkgName $ package pd,
                            pii_categories = categories pd,
                            pii_hasLibrary = hasLibs pd,
                            pii_numExecutables = length (executables pd),
                            pii_synopsis = synopsis pd
                        }

data Category = Category String | NoCategory
        deriving (Eq, Ord, Show)

-- Packages, grouped by category and ordered by name with each category.
formatPkgGroups :: [PackageIndexInfo] -> Html
formatPkgGroups pkgs = hackagePage "packages by category" docBody
  where docBody =
                (h2 << "Packages by category") :
                -- table of contents
                paragraph ! [theclass "toc"] <<
                        (bold << "Categories:" : toHtml " " :
                         intersperse (toHtml ", ") (map catLink cat_pkgs) ++
                         [toHtml "."]) :
                -- packages grouped by category
                [formatCategory cat +++
                        formatPkgList (sortBy (comparing sortKey) sub_pkgs) |
                        (cat, sub_pkgs) <- cat_pkgs]
        catLink (cat, sub_pkgs) =
                (anchor ! [href ("#" ++ catLabel catName)] << catName) +++
                spaceHtml +++
                toHtml ("(" ++ show (length sub_pkgs) ++ ")")
          where catName = categoryName cat
        cat_pkgs = groupOnFstBy normalizeCategory $ [(capitalize cat, pkg) |
                        pkg <- pkgs, cat <- pii_categories pkg]
        sortKey pkg = map toLower $ unPackageName $ pii_pkgName pkg
        formatCategory cat =
                h3 ! [theclass "category"] <<
                        anchor ! [XHtml.name (catLabel catName)] << catName
          where catName = categoryName cat
        catLabel cat = "cat:" ++ cat
        categoryName (Category cat) = cat
        categoryName NoCategory = "Unclassified"
        capitalize (Category s) =
                Category (unwords [toUpper c : cs | (c:cs) <- words s])
        capitalize NoCategory = NoCategory

formatPkgList :: [PackageIndexInfo] -> Html
formatPkgList pkgs = ulist ! [theclass "packages"] << map formatPkg pkgs

formatPkg :: PackageIndexInfo -> Html
formatPkg pkg = li << (pkgLink : toHtml (" " ++ ptype) : defn)
  where pname = pii_pkgName pkg
        pkgLink = anchor ! [href (packageNameURL pname)] << unPackageName pname
        defn
          | null (pii_synopsis pkg) = []
          | otherwise = [toHtml (": " ++ trim (pii_synopsis pkg))]
        ptype
          | pii_numExecutables pkg == 0 = "library"
          | pii_hasLibrary pkg = "library and " ++ programs
          | otherwise = programs
          where programs
                  | pii_numExecutables pkg > 1 = "programs"
                  | otherwise = "program"
        trim s
          | length s < 90 = s
          | otherwise = reverse (dropWhile (/= ',') (reverse (take 76 s))) ++ " ..."

categories :: PackageDescription -> [Category]
categories pkg
  | not (null cats) && (cats `notElem` blacklist) = split cats
  | not (null top_level_nodes) && length top_level_nodes < 3 &&
        all (`elem` allocatedTopLevelNodes) top_level_nodes =
        map Category top_level_nodes
  | otherwise = [NoCategory]
  where cats = trim (category pkg)
        -- trim will not be necessary with future releases of cabal
        trim = reverse . dropWhile isSpace . reverse
        split cs = case break (== ',') cs of
                (front, _:back) ->
                        Category front : split (dropWhile isSpace back)
                (front, []) -> [Category front]
        -- if no category specified, use top-level of module hierarchy
        top_level_nodes =
                maybe [] (nub . map (takeWhile (/= '.') . toFilePath) . exposedModules)
                (library pkg)

-- categories we ignore
blacklist :: [String]
blacklist = ["Application", "Foreign binding", "Tool", "Type", "Various", "Unclassified"]

groupOnFstBy :: (Ord a, Ord c) => (a -> c) -> [(a, b)] -> [(a, [b])]
groupOnFstBy f xys = [(x, y : map snd xys') |
        (x, y) : xys' <- groupBy (equating (f . fst)) (sortBy (comparing sortKey) xys)]
  where sortKey (x, _) = (f x, x)

normalizeCategory :: Category -> Category
normalizeCategory (Category n) = Category (map toLower n)
normalizeCategory NoCategory = NoCategory

allocatedTopLevelNodes :: [String]
allocatedTopLevelNodes = [
        "Algebra", "Codec", "Control", "Data", "Database", "Debug",
        "Distribution", "DotNet", "Foreign", "Graphics", "Language",
        "Network", "Numeric", "Prelude", "Sound", "System", "Test", "Text"]

packageNameURL :: PackageName -> URL
packageNameURL pkg = "/package/" ++ unPackageName pkg

unPackageName :: PackageName -> String
unPackageName (PackageName name) = name
