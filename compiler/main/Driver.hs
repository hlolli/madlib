{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}

module Driver where


import           Control.Monad.Trans.Control
import           Control.Monad.Identity
import           Data.Constraint.Extras           (has')
import           Data.Dependent.HashMap           (DHashMap)
import qualified Data.Dependent.HashMap           as DHashMap
import           Data.Dependent.Sum               (DSum ((:=>)))
import           Data.HashMap.Lazy                (HashMap)
import qualified Data.HashMap.Lazy                as HashMap
import           Data.HashSet                     (HashSet)
import qualified Data.HashSet                     as HashSet
import           Data.IORef.Lifted
import qualified Data.Text.IO                     as Text
import           Driver.Query (Query)
import qualified Driver.Query                     as Query
import           Rock
import qualified Driver.Rules as Rules
import           Data.Functor.Const
import           Data.Text (Text)
import qualified Data.Text                        as Text
import           Control.Exception
import           Error.Error                      (CompilationError(CompilationError))
import qualified Utils.Path as Path
import           Data.Hashable                    (Hashable (hash))
import           Run.Options
import           Error.Warning                    (CompilationWarning(CompilationWarning))
import           GHC.IO.Handle.FD (stderr)
import           Control.Arrow (first)
import qualified Data.Set                             as Set
import qualified Data.List                            as List
import           Text.Show.Pretty (ppShow)
import qualified Data.Map                             as Map
import           Run.Target                           (Target(TNode, TLLVM))
import           Utils.PathUtils                      (defaultPathUtils)
import qualified Utils.PathUtils                      as PathUtils
import           Control.Concurrent                   (MVar)
import qualified Explain.Format                       as Explain
import           Control.Monad.IO.Class               (liftIO)
import           Driver.Rules                         (rules)
import           Control.Concurrent                   (threadDelay, forkIO, ThreadId)
import qualified Control.FoldDebounce                 as Debounce
import           System.FSNotify
import           Data.Time.Clock



data State err = State
  { _startedVar :: !(IORef (DHashMap Query MemoEntry))
  , _hashesVar :: !(IORef (DHashMap Query (Const Int)))
  , _reverseDependenciesVar :: !(IORef (ReverseDependencies Query))
  , _tracesVar :: !(IORef (Traces Query (Const Int)))
  , _errorsVar :: !(IORef (DHashMap Query (Const [err])))
  , _warningsVar :: !(IORef (DHashMap Query (Const [CompilationWarning])))
  }


initialState :: IO (State err)
initialState = do
  startedVar             <- newIORef mempty
  hashesVar              <- newIORef mempty
  reverseDependenciesVar <- newIORef mempty
  tracesVar              <- newIORef mempty
  errorsVar              <- newIORef mempty
  warningsVar            <- newIORef mempty
  return
    State
      { _startedVar             = startedVar
      , _hashesVar              = hashesVar
      , _reverseDependenciesVar = reverseDependenciesVar
      , _tracesVar              = tracesVar
      , _errorsVar              = errorsVar
      , _warningsVar            = warningsVar
      }


setQueryResult :: IORef (DHashMap Query MemoEntry) -> Query a -> a -> IO ()
setQueryResult ref query value = do
  started <- readIORef ref
  let inserted = DHashMap.insert query (Done value) started
  atomicWriteIORef ref inserted


resetState :: State err -> IO ()
resetState state = do
  atomicWriteIORef (_startedVar state) mempty
  atomicWriteIORef (_hashesVar state) mempty
  atomicWriteIORef (_reverseDependenciesVar state) mempty
  atomicWriteIORef (_tracesVar state) mempty
  atomicWriteIORef (_errorsVar state) mempty
  atomicWriteIORef (_warningsVar state) mempty


data Prune
  = Don'tPrune
  | Prune


runIncrementalTask ::
  State CompilationError ->
  Options ->
  [FilePath] ->
  Map.Map FilePath String ->
  Prune ->
  Task Query a ->
  IO (a, [CompilationWarning], [CompilationError])
runIncrementalTask state options changedFiles fileUpdates prune task = handleException $ do
  reverseDependencies <- readIORef $ _reverseDependenciesVar state
  started             <- readIORef $ _startedVar state
  hashes              <- readIORef $ _hashesVar state

  let (keysToInvalidate, reverseDependencies') =
        List.foldl'
          ( \(keysToInvalidate_, reverseDependencies_) file ->
              first (<> keysToInvalidate_) $ reachableReverseDependencies (Query.File file) reverseDependencies_
          )
          (mempty, reverseDependencies)
          changedFiles
  let started' = DHashMap.difference started keysToInvalidate
      hashes'  = DHashMap.difference hashes keysToInvalidate

  atomicWriteIORef (_startedVar state) started'
  atomicWriteIORef (_hashesVar state) hashes'
  atomicWriteIORef (_reverseDependenciesVar state) reverseDependencies'

  threadDepsVar <- newIORef mempty
  let readSourceFile_ file
        | Just text <- Map.lookup file fileUpdates =
          return text
        | otherwise =
          readFile file `catch` \(_ :: IOException) -> pure mempty

      traceFetch_ ::
        GenRules (Writer TaskKind Query) Query ->
        GenRules (Writer TaskKind Query) Query
      traceFetch_ = id
      -- traceFetch_ =
      --   traceFetch
      --     (\(Writer key) -> modifyMVar_ printVar $ \n -> do
      --       putText $ fold (replicate n "| ") <> "fetching " <> show key
      --       return $ n + 1)
      --     (\_ _ -> modifyMVar_ printVar $ \n -> do
      --       putText $ fold (replicate (n - 1) "| ") <> "*"
      --       return $ n - 1)

      writeErrorsAndWarnings :: Writer TaskKind Query a -> ([CompilationWarning], [CompilationError]) -> Task Query ()
      writeErrorsAndWarnings (Writer key) (warns, errs) = do
        atomicModifyIORef' (_warningsVar state) $
          (,()) . if null warns then DHashMap.delete key else DHashMap.insert key (Const warns)
        atomicModifyIORef' (_errorsVar state) $
          (,()) . if null errs then DHashMap.delete key else DHashMap.insert key (Const errs)
        return ()

      rules :: Rules Query
      rules =
        memoiseWithCycleDetection (_startedVar state) threadDepsVar $
          trackReverseDependencies (_reverseDependenciesVar state) $
            verifyTraces
              (_tracesVar state)
              ( \query value -> do
                  hashed <- readIORef $ _hashesVar state
                  case DHashMap.lookup query hashed of
                    Just h ->
                      pure h
                    Nothing -> do
                      let h =
                            Const $ has' @Hashable @Identity query $ hash $ Identity value
                      atomicModifyIORef' (_hashesVar state) $
                        (,()) . DHashMap.insert query h
                      pure h
              )
              $ traceFetch_
              $ writer writeErrorsAndWarnings
              $ Rules.rules
                  options
                    { optPathUtils = (optPathUtils options) { PathUtils.readFile = readSourceFile_ } }

  result    <- Rock.runTask rules task
  started   <- readIORef $ _startedVar state
  errorsMap <- case prune of
    Don'tPrune ->
      readIORef $ _errorsVar state

    Prune -> do
      atomicModifyIORef' (_tracesVar state) $
        (,()) . DHashMap.intersectionWithKey (\_ _ t -> t) started
      atomicModifyIORef' (_errorsVar state) $ \errors -> do
        let errors' = DHashMap.intersectionWithKey (\_ _ e -> e) started errors
        (errors', errors')

  warningsMap <- case prune of
    Don'tPrune ->
      readIORef $ _warningsVar state

    Prune -> do
      atomicModifyIORef' (_tracesVar state) $
        (,()) . DHashMap.intersectionWithKey (\_ _ t -> t) started
      atomicModifyIORef' (_warningsVar state) $ \warnings -> do
        let warnings' = DHashMap.intersectionWithKey (\_ _ e -> e) started warnings
        (warnings', warnings')

  let errors = do
        (_ :=> Const errs) <- DHashMap.toList errorsMap
        errs
  let warnings = do
        (_ :=> Const warns) <- DHashMap.toList warningsMap
        warns

  atomicModifyIORef' (_errorsVar state) $ \errMap ->
    let filtered = DHashMap.filterWithKey
                    (\k _ -> case k of
                      Query.DetectImportCycle _ _ ->
                        False

                      _ ->
                        True
                    )
                    errMap
    in  (filtered, filtered)

  pure (result, warnings, errors)
  where
    handleException m =
      m `catch` \e -> do
        -- TODO: test if we can just restore the initial state here instead
        resetState state
        throw (e :: SomeException)


ignoreTaskKind :: Rock.GenRules (Rock.Writer Rock.TaskKind f) f -> Rock.Rules f
ignoreTaskKind rs key = fst <$> rs (Rock.Writer key)


typeCheckFileTask :: FilePath -> Rock.Task Query.Query ()
typeCheckFileTask path = do
  Rock.fetch $ Query.SolvedASTWithEnv path
  return ()


compilationTask :: FilePath -> Rock.Task Query ()
compilationTask path = do
  Rock.fetch $ Query.BuiltTarget path


detectCyleTask :: FilePath -> Rock.Task Query ()
detectCyleTask path = do
  Rock.fetch $ Query.DetectImportCycle [] path
  return ()


-- Measure time

recordAndPrintDuration :: String -> IO a -> IO a
recordAndPrintDuration title action = do
  startT       <- getCurrentTime
  actionResult <- action
  endT         <- getCurrentTime
  let diff = diffUTCTime endT startT
  let (ms, _) = properFraction $ diff * 1000
  putStrLn $ title <> show ms <> "ms"
  return actionResult

-- Watch

watch :: FilePath -> ([FilePath] -> IO ()) -> IO ThreadId
watch root action = do
  withManager $ \mgr -> do
    trigger <-
      Debounce.new
        Debounce.Args
          { Debounce.cb = action
          , Debounce.fold = \l v -> List.nub $ v:l
          , Debounce.init = []
          }
        Debounce.def
          { Debounce.delay = 50000 -- 50ms
          , Debounce.alwaysResetTimer = True
          }

    -- start a watching job (in the background)
    watchTree
      mgr          -- manager
      root         -- directory to watch
      (const True) -- predicate
      (\e -> do
        let
          f = case e of
                Added f _ _ ->
                  f

                Modified f _ _ ->
                  f

                Removed f _ _ ->
                  f

                Unknown f _ _ ->
                  f

          -- @TODO it would be better to not listen to these folders in the `watchTree` when available
          -- https://github.com/haskell-fswatch/hfsnotify/issues/101
          shouldTrigger = ".mad" `List.isSuffixOf` f

        when shouldTrigger $ Debounce.send trigger f
      )

    -- sleep forever (until interrupted)
    forever $ threadDelay 1000000
