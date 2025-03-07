module Optimize.TCE where

import           AST.Core
import qualified Data.Maybe          as Maybe
import qualified Data.Bifunctor as Bifunctor
import Infer.Type

newtype Env
  = Env { envCurrentName :: Maybe String }



getAppName :: Exp -> Maybe String
getAppName exp = case exp of
  Typed _ _ _ (Var n _) ->
    Just n

  Typed _ _ _ (Call fn _) ->
    getAppName fn

  Typed _ _ _ (Placeholder _ e) ->
    getAppName e

  _ ->
    Nothing


resolveTable :: Table -> Table
resolveTable = (resolveAST <$>)


resolveAST :: AST -> AST
resolveAST ast =
  let resolvedExps      = markDefinition (Env Nothing) <$> aexps ast
      resolvedInstances =
        (
          \(Untyped area metadata (Instance name ps n methods)) ->
             let resolvedMethods = Bifunctor.first (markDefinition (Env Nothing)) <$> methods
             in  Untyped area metadata (Instance name ps n resolvedMethods)
        ) <$> ainstances ast
  in  ast { aexps = resolvedExps, ainstances = resolvedInstances }


markDefinition :: Env -> Exp -> Exp
markDefinition env exp = case exp of
  Typed qt area metadata (Export e) ->
    Typed qt area metadata (Export (markDefinition env e))

  Typed qt area metadata (Assignment fnName abs) ->
    Typed qt area metadata (Assignment fnName (markDefinition env { envCurrentName = Just fnName } abs))

  Typed qt@(_ :=> fnType) area metadata (Definition params body) | Maybe.isJust (envCurrentName env) ->
    let Just fnName = envCurrentName env
    in  case findRecursionKind fnType fnName (getValue <$> params) body of
          Just kind ->
            Typed qt area (RecursiveDefinition kind : metadata) (Definition params (markTRCCalls kind fnType fnName . markDefinition env <$> body))
          Nothing ->
            Typed qt area metadata (Definition params (markDefinition env { envCurrentName = Nothing } <$> body))

  Typed qt area metadata (Placeholder ref exp) ->
    Typed qt area metadata (Placeholder ref (markDefinition env exp))

  _ ->
    exp


markIs :: RecursionKind -> Type -> String -> Is -> Is
markIs recursionKind fnType fnName is = case is of
  Typed qt area metadata (Is pat exp) ->
    Typed qt area metadata (Is pat (markTRCCalls recursionKind fnType fnName exp))

  _ ->
    is


findRecursiveConstructorArgIndex :: Int -> String -> [Exp] -> Maybe Int
findRecursiveConstructorArgIndex index fnName args = case args of
  (Typed _ _ _(Call (Typed _ _ _ (Var n _)) _) : more) ->
    if n == fnName then
      Just index
    else
      findRecursiveConstructorArgIndex (index + 1) fnName more

  (_ : more) ->
    findRecursiveConstructorArgIndex (index + 1) fnName more

  _ ->
    Nothing


-- looks for tail recursive calls and marks them
markTRCCalls :: RecursionKind -> Type -> String -> Exp -> Exp
markTRCCalls recursionKind fnType fnName exp = case exp of
  Typed qt area metadata (Call fn@(Typed _ _ _ (Var constructorName True)) args) ->
    case findRecursiveConstructorArgIndex 0 fnName args of
      Just index ->
        Typed qt area (RecursiveCall (ConstructorRecursion (Just (ConstructorRecursionInfo constructorName index))) : metadata) (Call fn args)

      Nothing ->
        Typed qt area (RecursionEnd recursionKind : metadata) (Call fn args)

  Typed qt area metadata (Call fn args) ->
    if Just fnName == getAppName exp then
      Typed qt area (RecursiveCall PlainRecursion : metadata) (Call fn args)
    else
      Typed qt area (RecursionEnd recursionKind : metadata) (Call fn args)

  Typed qt area metadata (If cond truthy falsy) ->
    Typed qt area metadata (If cond (markTRCCalls recursionKind fnType fnName truthy) (markTRCCalls recursionKind fnType fnName falsy))

  Typed qt area metadata (Where exp iss) ->
    Typed qt area metadata (Where exp (markIs recursionKind fnType fnName <$> iss))

  -- TODO: Probably we need to either mark the whole thing, or just the last expression of it
  -- Typed qt area metadata (Do exps) ->
  --   Typed qt area metadata (Do (markTRCCalls markWith fnName <$> exps))

  Typed qt area metadata (Placeholder info exp) ->
    Typed qt area metadata (Placeholder info (markTRCCalls recursionKind fnType fnName exp))

  Typed qt area metadata (ListConstructor [Typed qtLi areaLi metadataLi (ListItem li), Typed qtSpread areaSpread metadataSpread (ListSpread spread)]) ->
    -- we probably need to mark this node as being ListRecursion
    if containsRecursion True fnType fnName spread then
      Typed qt area (RecursiveCall (ListRecursion RightRecursion) : metadata) (ListConstructor [
        Typed qtLi areaLi metadataLi (ListItem li),
        Typed qtSpread areaSpread metadataSpread (ListSpread (markTRCCalls recursionKind fnType fnName spread))
      ])
    else
      Typed qt area (RecursionEnd recursionKind : metadata) (ListConstructor [
        Typed qtLi areaLi metadataLi (ListItem li),
        Typed qtSpread areaSpread metadataSpread (ListSpread spread)
      ])

  Typed qt area metadata e ->
    Typed qt area (RecursionEnd recursionKind : metadata) e
    -- if recursionKind /= PlainRecursion && recursionKind /= NotOptimizable then
      -- Typed qt area (RecursionEnd recursionKind : metadata) e
    -- else
      -- Typed qt area metadata e

  _ ->
    exp


combineRecursionKinds :: [Maybe RecursionKind] -> Maybe RecursionKind
combineRecursionKinds kinds = case kinds of
  (Just (ListRecursion side) : _) ->
    Just (ListRecursion side)

  (Just (ConstructorRecursion _) : _) ->
    Just (ConstructorRecursion Nothing)

  (Just PlainRecursion : more) ->
    case combineRecursionKinds more of
      Nothing ->
        Just PlainRecursion

      or ->
        or

  (Nothing : more) ->
    combineRecursionKinds more

  _ ->
    Nothing




findRecursionKindInIss :: Type -> String -> [String] -> [Is] -> Maybe RecursionKind
findRecursionKindInIss fnType fnName params iss = case iss of
  [] ->
    Just PlainRecursion

  [Typed _ _ _ (Is _ isExp)] ->
    if containsRecursion True fnType fnName isExp then
      Just PlainRecursion
    else
      findRecursionKind fnType fnName params [isExp]

  (Typed _ _ _ (Is _ isExp) : next) ->
    let current =
          if containsRecursion True fnType fnName isExp then
            Just PlainRecursion
          else
            findRecursionKind fnType fnName params [isExp]
        next' = findRecursionKindInIss fnType fnName params next
    in  combineRecursionKinds [current, next']

  _ ->
    Nothing


findRecursionKind :: Type -> String -> [String] -> [Exp] -> Maybe RecursionKind
findRecursionKind fnType fnName params exps = case exps of
  [] ->
    Nothing

  [lastExp] -> case lastExp of
    Typed _ _ _ (Call (Typed _ _ _ (Var _ True)) args) ->
      if any (containsRecursion True fnType fnName) args then
        Just (ConstructorRecursion Nothing)
      else
        Nothing

    Typed _ _ _ (Call (Typed (_ :=> t) _ _ _) _) | t == fnType && containsRecursion True fnType fnName lastExp ->
      Just PlainRecursion

    Typed _ _ _ (If _ truthy falsy) ->
       combineRecursionKinds
          [ findRecursionKind fnType fnName params [truthy]
          , findRecursionKind fnType fnName params [falsy]
          ]

    Typed _ _ _ (Where _ iss) ->
      findRecursionKindInIss fnType fnName params iss

    Typed _ _ _ (ListConstructor [Typed _ _ _ (ListItem li), Typed _ _ _ (ListSpread spread)]) ->
      if not (containsRecursion False fnType fnName li) && containsRecursion True fnType fnName spread then
        Just (ListRecursion RightRecursion)
      else
        Nothing

    _ ->
      Nothing

  _ ->
    Nothing


containsRecursion :: Bool -> Type -> String  -> Exp -> Bool
containsRecursion direct fnType fnName exp = case exp of
  Typed (_ :=> t) _ _ Call {} ->
    Just fnName == getAppName exp && t == getReturnType fnType

  Typed _ _ _ (Access rec accessor) ->
    not direct && (containsRecursion direct fnType fnName rec || containsRecursion direct fnType fnName accessor)

  Typed _ _ _ (Definition _ exps) ->
    not direct && any (containsRecursion direct fnType fnName) exps

  Typed _ _ _ (Assignment _ exp) ->
    not direct && containsRecursion direct fnType fnName exp

  Typed _ _ _ (ListConstructor exps) ->
    not direct && any (containsRecursion direct fnType fnName) (getListItemExp <$> exps)

  Typed _ _ _ (TupleConstructor exps) ->
    not direct && any (containsRecursion direct fnType fnName) exps

  Typed _ _ _ (Record fields) ->
    not direct && any (containsRecursion direct fnType fnName) (getFieldExp <$> fields)

  Typed _ _ _ (If cond truthy falsy) ->
    not direct &&
      (
        containsRecursion direct fnType fnName cond
        || containsRecursion direct fnType fnName truthy
        || containsRecursion direct fnType fnName falsy
      )

  Typed _ _ _ (Do exps) ->
    not direct && any (containsRecursion direct fnType fnName) exps

  Typed _ _ _ (Where exp iss) ->
    not direct &&
      (
        containsRecursion direct fnType fnName exp
        || any (containsRecursion direct fnType fnName) (getIsExpression <$> iss)
      )

  Typed _ _ _ (Placeholder _ exp) ->
    not direct && containsRecursion direct fnType fnName exp

  _ ->
    False
