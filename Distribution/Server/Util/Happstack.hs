
{-|

Functions and combinators to expose functioanlity buiding
on happstack bit is not really specific to any one area
of Hackage.

-}

module Distribution.Server.Util.Happstack (
    remainingPath,
    remainingPathString,
    mime,
    consumeRequestBody,
    checkCachingETag,

    uriEscape
  ) where

import Happstack.Server
import qualified Data.Map as Map
import System.FilePath.Posix (takeExtension, (</>))
import Control.Monad
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Network.URI as URI

import Distribution.Server.Framework.ResponseContentTypes (ETag, formatETag)  -- TODO: move to this module

-- |Passes a list of remaining path segments in the URL. Does not
-- include the query string. This call only fails if the passed in
-- handler fails.
remainingPath :: Monad m => ([String] -> ServerPartT m a) -> ServerPartT m a
remainingPath handle = do
    rq <- askRq
    localRq (\newRq -> newRq{rqPaths=[]}) $ handle (rqPaths rq)

-- | Gets the string without altering the request.
remainingPathString :: Monad m => ServerPartT m String
remainingPathString = do
    strs <- liftM rqPaths askRq
    return $ if null strs then "" else foldr1 (</>) . map uriEscape $ strs

-- This disappeared from happstack in 7.1.7
uriEscape :: String -> String
uriEscape = URI.escapeURIString URI.isAllowedInURI

-- |Returns a mime-type string based on the extension of the passed in
-- file.
mime :: FilePath -> String
mime x  = Map.findWithDefault "text/plain" (drop 1 (takeExtension x)) mimeTypes


-- | Get the raw body of a PUT or POST request.
--
-- Note that for performance reasons, this consumes the data and it cannot be
-- called twice.
--
consumeRequestBody :: Happstack m => m BS.ByteString
consumeRequestBody = do
    mRq <- takeRequestBody =<< askRq
    case mRq of
      Nothing -> escape $ internalServerError $ toResponse
                   "consumeRequestBody cannot be called more than once."
      Just (Body b) -> return b


-- | Check the request for an ETag and return 304 if it matches.
checkCachingETag :: Monad m => ETag -> ServerPartT m ()
checkCachingETag expectedtag = do
    rq <- askRq
    case getHeader "if-none-match" rq of
      Just etag -> checkEtag (BS8.unpack etag)
      _ -> return ()
    --return $ composeFilter (\r -> setHeader "ETag" (formatETag expectedtag))
    where checkEtag actualtag =
            when ((formatETag expectedtag) == actualtag) $
                finishWith (noContentLength . result 304 $ "")
