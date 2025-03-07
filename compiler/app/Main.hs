{-# LANGUAGE MultiParamTypeClasses   #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE NamedFieldPuns   #-}
module Main where

import           GHC.IO.Encoding
import           Run.Run
import           Run.GenerateDocumentation
import           Run.Utils
import           Run.GeneratePackage
import           Run.Compile
import           Run.CommandLine
import           Run.PackageInstaller
import           Run.TestRunner
import           Run.Package
import           Run.Format
import           Run.LanguageServer
import           Run.Config


main :: IO ()
main = do
  setLocaleEncoding utf8
  runCommandParser >>= run

run :: Command -> IO ()
run cmd = do
  coverage <- isCoverageEnabled

  case cmd of
    Compile{} ->
      let sanitizedOutput = sanitizeOutputPath cmd
      in  case sanitizedOutput of
            Right s ->
              runCompilation cmd { compileOutput = s } coverage

            Left  e ->
              putStrLn e

    Test entrypoint target watch ->
      runTests entrypoint target watch

    Install ->
      runPackageInstaller

    Package{ packageSubCommand, rebuild } ->
      runPackage packageSubCommand rebuild

    New path ->
      runPackageGenerator path

    Doc path ->
      runDocumentationGenerator path

    Run path args ->
      runRun path args

    Format path code fix width ->
      runFormatter width fix path code

    LanguageServer -> do
      runLanguageServer

    Config configCommand ->
      runConfigurationCommand configCommand
