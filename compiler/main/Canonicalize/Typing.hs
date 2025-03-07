{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
module Canonicalize.Typing where


import qualified AST.Source                    as Src
import qualified AST.Canonical                 as Can
import           Canonicalize.CanonicalM
import           Canonicalize.Env
import           Canonicalize.EnvUtils
import           Infer.Type
import           Infer.Scheme
import           Infer.Unify
import           Infer.Infer
import           Infer.Instantiate
import           Infer.Substitute
import qualified Data.Set                      as S
import qualified Data.Map                      as M
import           Data.Char
import           Error.Error
import           Error.Context
import           Control.Monad.Except
import           Data.List
import Debug.Trace
import Text.Show.Pretty
import qualified Data.Maybe as Maybe


canonicalizeTyping :: Src.Typing -> CanonicalM Can.Typing
canonicalizeTyping (Src.Source area _ t) = case t of
  Src.TRSingle name -> do
    let nameToPush = if "." `isInfixOf` name then takeWhile (/= '.') name else name
    pushNameAccess nameToPush
    return $ Can.Canonical area (Can.TRSingle name)

  Src.TRComp name typings -> do
    let nameToPush = if "." `isInfixOf` name then takeWhile (/= '.') name else name
    pushNameAccess nameToPush
    typings' <- mapM canonicalizeTyping typings
    return $ Can.Canonical area (Can.TRComp name typings')

  Src.TRArr left right -> do
    left'  <- canonicalizeTyping left
    right' <- canonicalizeTyping right
    return $ Can.Canonical area (Can.TRArr left' right')

  Src.TRRecord fields base -> do
    fields' <- mapM (\(area, t) -> (area,) <$> canonicalizeTyping t) fields
    base'   <- mapM canonicalizeTyping base
    return $ Can.Canonical area (Can.TRRecord fields' base')

  Src.TRTuple typings -> do
    typings' <- mapM canonicalizeTyping typings
    return $ Can.Canonical area (Can.TRTuple typings')

  Src.TRConstrained constraints typing -> do
    constraints' <- mapM canonicalizeTyping constraints
    typing'      <- canonicalizeTyping typing
    return $ Can.Canonical area (Can.TRConstrained constraints' typing')


canonicalizeTyping' :: Src.Typing -> Can.Typing
canonicalizeTyping' (Src.Source area _ t) = case t of
  Src.TRSingle name ->
    Can.Canonical area (Can.TRSingle name)

  Src.TRComp name typings ->
    let typings' = canonicalizeTyping' <$> typings
    in  Can.Canonical area (Can.TRComp name typings')

  Src.TRArr left right -> do
    let left'  = canonicalizeTyping' left
    let right' = canonicalizeTyping' right
    Can.Canonical area (Can.TRArr left' right')

  Src.TRRecord fields base ->
    let fields' = (\(area, t) -> (area, canonicalizeTyping' t)) <$> fields
        base'   = canonicalizeTyping' <$> base
    in  Can.Canonical area (Can.TRRecord fields' base')

  Src.TRTuple typings -> 
    let typings' = canonicalizeTyping' <$> typings
    in  Can.Canonical area (Can.TRTuple typings')

  Src.TRConstrained constraints typing -> 
    let constraints' = canonicalizeTyping' <$> constraints
        typing'      = canonicalizeTyping' typing
    in  Can.Canonical area (Can.TRConstrained constraints' typing')



typingToScheme :: Env -> Src.Typing -> CanonicalM Scheme
typingToScheme env typing = do
  (ps :=> t) <- qualTypingToQualType env typing
  let vars = S.toList $ S.fromList $ collectVars t <> concat (collectPredVars <$> ps)
  return $ quantify vars (ps :=> t)


qualTypingToQualType :: Env -> Src.Typing -> CanonicalM (Qual Type)
qualTypingToQualType env t@(Src.Source _ _ typing) = case typing of
  Src.TRConstrained constraints typing' -> do
    t  <- typingToType env (KindRequired Star) typing'
    ps <- mapM (constraintToPredicate env t) constraints
    return $ ps :=> t

  _ -> ([] :=>) <$> typingToType env (KindRequired Star) t


constraintToPredicate :: Env -> Type -> Src.Typing -> CanonicalM Pred
constraintToPredicate env t (Src.Source _ _ (Src.TRComp n typings)) = do
  let s = buildVarSubsts t
  ts <- mapM
    (\case
      Src.Source _ _ (Src.TRSingle var)                   -> return $ apply s $ TVar $ TV var Star

      fullTyping@(Src.Source _ _ (Src.TRComp _ _)) -> do
        apply s <$> typingToType env (KindRequired Star) fullTyping

      _ -> undefined
    )
    typings

  return $ IsIn n ts Nothing

constraintToPredicate _ _ _ = undefined


data KindRequirement
  = KindRequired Kind
  | AnyKind


typingToType :: Env -> KindRequirement -> Src.Typing -> CanonicalM Type
typingToType env kindNeeded (Src.Source area _ (Src.TRSingle t))
  | t == "Integer" = return tInteger
  | t == "Float"   = return tFloat
  | t == "Byte"    = return tByte
  | t == "Boolean" = return tBool
  | t == "String"  = return tStr
  | t == "Char"    = return tChar
  | t == "{}" = return tUnit
  | isLower $ head t = return (TVar $ TV t Star)
  | otherwise = do
    pushTypeAccess t
    h <- catchError
      (lookupADT env t)
      (\(CompilationError e _) -> throwError $ CompilationError e (Context (envCurrentPath env) area))

    parsedType <- case h of
      (TAlias _ id vars _) ->
        if not (null vars) then
          throwError $ CompilationError (WrongAliasArgCount id (length vars) 0) (Context (envCurrentPath env) area)
        else
          updateAliasVars (getConstructorCon h) []

      t                -> return $ getConstructorCon t

    case kindNeeded of
      AnyKind ->
        return parsedType

      KindRequired k ->
        if k == kind parsedType then
          return parsedType
        else
          throwError $ CompilationError (TypingHasWrongKind parsedType k (kind parsedType)) (Context (envCurrentPath env) area)



typingToType env kindNeeded (Src.Source area _ (Src.TRComp t ts))
  | isLower . head $ t = do
    params <- mapM (typingToType env AnyKind) ts
    return $ foldl' TApp (TVar $ TV t (buildKind (length ts))) params
  | otherwise = do
    pushTypeAccess t
    h <- catchError
      (lookupADT env t)
      (\(CompilationError e _) -> throwError $ CompilationError e (Context (envCurrentPath env) area))

    let (Forall ks (_ :=> rr)) = quantify (ftv h) ([] :=> h)

    let kargs =
          (\case
              (TGen x) -> ks !! x
              _        -> Star
            )
            <$> getConstructorArgs rr

    params <- mapM
      (\(typin, k) -> do
        pt <- typingToType env (KindRequired k) typin
        case pt of
          TVar (TV n _) -> return $ TVar (TV n k)
          _             -> return pt
      )
      (zip ts kargs)

    parsedType <- case h of
      TAlias _ id tvs _ ->
        if length tvs /= length ts then
          throwError $ CompilationError (WrongAliasArgCount id (length tvs) (length ts)) (Context (envCurrentPath env) area)
        else
          updateAliasVars (getConstructorCon h) params

      t ->
        return $ foldl' TApp (getConstructorCon t) params

    case kindNeeded of
      AnyKind ->
        return parsedType

      KindRequired k ->
        if k == kind parsedType && length kargs >= length ts then
          return parsedType
        else
          throwError $ CompilationError (TypingHasWrongKind parsedType k (kind parsedType)) (Context (envCurrentPath env) area)


typingToType env _ (Src.Source _ _ (Src.TRArr l r)) = do
  l' <- typingToType env (KindRequired Star) l
  r' <- typingToType env (KindRequired Star) r
  return $ l' `fn` r'

typingToType env _ (Src.Source _ _ (Src.TRRecord fields base)) = do
  fields' <- mapM (typingToType env (KindRequired Star)) (snd <$> fields)
  base'   <- mapM (typingToType env (KindRequired Star)) base
  when (Maybe.isNothing base) $ do
    let fieldNames = M.keys fields'
    pushRecordToDerive fieldNames
  return $ TRecord fields' base'

typingToType env _ (Src.Source _ _ (Src.TRTuple elems)) = do
  elems' <- mapM (typingToType env (KindRequired Star)) elems
  let tupleT = getTupleCtor (length elems)
  return $ foldl' TApp tupleT elems'

-- Never happens as it's handled in the qualTypingToQualType function
typingToType _ _ (Src.Source _ _ (Src.TRConstrained _ _)) = undefined


getConstructorArgs :: Type -> [Type]
getConstructorArgs t = case t of
  TApp l r -> getConstructorArgs l <> [r]
  TCon _ _ -> []
  _        -> [t]


updateAliasVars :: Type -> [Type] -> CanonicalM Type
updateAliasVars t args = do
  case t of
    TAlias _ _ vars t' ->
      let instArgs = M.fromList $ zip vars args

          update :: Type -> CanonicalM Type
          update ty = case ty of
            TVar tv -> case M.lookup tv instArgs of
              Just x  -> return x
              Nothing -> case tv of
                TV _ k -> return $ TVar (TV "p" k)

            TApp l r -> do
              l' <- update l
              r' <- update r
              return $ TApp l' r'
            TCon    _  _    -> return ty
            TRecord fs base -> do
              fs'   <- mapM update fs
              base' <- mapM update base
              return $ TRecord fs' base'
            _ -> undefined
      in  update t'

    _ -> return t
