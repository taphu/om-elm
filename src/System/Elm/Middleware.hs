{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

{- |
  This module contains utilities for compiling and bundling Elm programs
  directly into your Haskell executable binary. It is useful for the
  case where you want to bundle a front-end Elm web app along with the
  backing services that support it, and especially for when the two
  components are part of the same codebase. It produces WAI Middleware,
  and is thus compatible with a wide range server-side frameworks.

  Usage is designed to be as simple as possible. There are 3 steps:

  1) Change your .cabal file to use a \"Custom\" build type, and add
  the appropriate custom build dependencies.

  > build-type: Custom
  > ...
  > custom-setup
  >   setup-depends:
  >     Cabal,
  >     base,
  >     om-elm

  2) Modify your @Setup.hs@ file, using 'requireElm'.

  3) Include a 'Middleware' template-haskell splice, using 'elmSite',
  in the appropriate place in your code.

  See the function documnetation for more details.

-}
module System.Elm.Middleware (
  requireElm,
  elmSite,
  elmSiteDebug,
  PathInfo,
) where


import Control.Exception.Safe (tryAny)
import Control.Monad (void)
import Data.Bool (bool)
import Data.Map (Map)
import Data.Monoid ((<>))
import Data.String (IsString, fromString)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Distribution.Simple (hookedPrograms, simpleUserHooks, preConf,
   UserHooks)
import Distribution.Simple.Program (simpleProgram, Program,
   configureAllKnownPrograms, requireProgram, defaultProgramDb)
import Distribution.Simple.Setup (fromFlagOrDefault, configVerbosity)
import Distribution.Verbosity (normal)
import Language.Haskell.TH (Q, TExp, runIO)
import Language.Haskell.TH.Syntax (addDependentFile)
import Network.HTTP.Types (ok200, methodNotAllowed405)
import Network.Wai (Middleware, Application, pathInfo, requestMethod,
   responseLBS)
import Safe (lastMay)
import System.Directory (removeDirectoryRecursive, createDirectory)
import System.Exit (ExitCode(ExitSuccess))
import System.Posix (ProcessStatus(Exited), forkProcess, executeFile,
   getProcessStatus)
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import qualified Data.Text as T


{- |
  Add the elm-make program requirements to a set of build hooks. This is
  expected to be used in your Setup.hs file thusly:

  > import Distribution.Simple (defaultMainWithHooks, simpleUserHooks)
  > import System.Elm.Middleware (requireElm)
  > 
  > main = defaultMainWithHooks (requireElm simpleUserHooks)

-}
requireElm :: UserHooks -> UserHooks
requireElm hooks =
    hooks {
      hookedPrograms = hookedPrograms hooks ++ [elmProg],

      preConf = \args flags -> do
        let verbosity = fromFlagOrDefault normal (configVerbosity flags)
        db <- configureAllKnownPrograms verbosity defaultProgramDb
        _ <- requireProgram verbosity elmProg db
        preConf simpleUserHooks args flags
    }
  where
    {- | A description of the elm-make program.  -}
    elmProg :: Program
    elmProg = simpleProgram "elm-make"


{- |
  Template Haskell method to create a 'Middleware' that serves a set of
  elm programs. The elm programs are compiled into HTML at compile time,
  and that HTML is included directly in your executable.

  The parameter is a map of 'pathInfo's to elm program module file. The
  elm program located at the file is served whenever the pathInfo matches
  that of the request. Any non-matching request is forwarded to the
  downstream 'Application'.

  The typed template-haskell splice:

  > $$(elmSite $ Map.fromList [
  >     (["app.js"], "elm/Your/Elm/Module/App.elm")
  >   ])

  will construct a WAI 'Middleware' which serves the compiled elm program on
  @/app.js@.

-}
elmSite :: Map PathInfo FilePath -> Q (TExp Middleware)
elmSite = elmSite2 False


{- | Like 'elmSite', but serve the debug elm runtime. -}
elmSiteDebug :: Map PathInfo FilePath -> Q (TExp Middleware)
elmSiteDebug = elmSite2 True


elmSite2 :: Bool -> Map PathInfo FilePath -> Q (TExp Middleware)
elmSite2 debug spec =
    buildMiddleware =<< (
      mapM (\(u, c) -> (u,) <$> c) [
        (uriPath, compileElm uriPath elmFile)
        | (fmap T.unpack -> uriPath, elmFile) <- Map.toList spec
      ]
    )
  where
    {- | Construct the middleware from a set of compiled elm resources. -}
    buildMiddleware :: [([String], (String, String))] -> Q (TExp Middleware)
    buildMiddleware resources = [||
        let
          apps = Map.fromList[
              (uriPath, buildApp contentType content)
              | (fmap T.pack -> uriPath, (contentType, content)) <- resources
            ]
          {- | Build the application that serves a single elm resource. -}
          buildApp :: String -> String -> Application
          buildApp contentType content req respond = respond $
            case requestMethod req of
              "GET" ->
                responseLBS
                  ok200
                  [("Content-Type", fromString contentType)]
                  (fromString content)
              _ -> responseLBS methodNotAllowed405 [("Allow", "GET")] ""
        in
          \downstream req respond ->
            case Map.lookup (pathInfo req) apps of
              Nothing -> downstream req respond
              Just app -> app req respond
      ||]

    compileElm :: [String] -> FilePath -> Q (String, String)
    compileElm uriPath elmFile = do
        addDependentFile elmFile
        runIO $ do
          void . tryAny $ removeDirectoryRecursive buildDir
          createDirectory buildDir
          putStrLn $ "Compiling elm file: " ++ elmFile
          forkProcess (executeFile "elm-make" True ([
              elmFile,
              "--yes",
              "--output=" <> buildFile
            ] ++ bool [] ["--debug"] debug) Nothing) >>= getProcessStatus True True >>= \case
              Nothing -> fail "elm-make should have ended."
              Just (Exited ExitSuccess) ->
                (contentType,)
                . T.unpack
                . decodeUtf8
                <$> BS.readFile buildFile
              e -> fail $ "elm-make failed with: " ++ show e
      where
        {- |
          The name of the build directory. We have to have a build
          directory because elm-make won't output compile results to
          stdout. It will only output them to files.
        -}
        buildDir :: (IsString a) => a
        buildDir = ".om-elm-build-dir"

        {- | Figure out if we are compiling to javascript or html. -}
        contentType :: String
        contentType = case lastMay uriPath of
          Just (endsWith ".js" -> True) -> "text/javascript"
          _ -> "text/html"

        buildFile :: FilePath
        buildFile = buildDir <> case lastMay uriPath of
          Just (endsWith ".js" -> True) -> "/elm.js"
          _ -> "/elm.html"

        endsWith :: String -> String -> Bool
        endsWith ending str =
          take (length ending) (reverse str) == reverse ending


{- | A WAI uri path, as per the meaning of 'pathInfo'. -}
type PathInfo = [Text]


