{-# LANGUAGE NamedFieldPuns #-}
module Canonicalize.Derive where

import           Canonicalize.CanonicalM
import           Canonicalize.InstanceToDerive
import           AST.Canonical
import           Infer.Type
import           Explain.Location
import qualified Data.Map                               as Map
import qualified Data.Set                               as Set
import           Data.Maybe (mapMaybe)
import           Data.ByteString.Char8 (intersperse)
import qualified Data.List                              as List


searchTypeInConstructor :: Id -> Type -> Maybe Type
searchTypeInConstructor id t = case t of
  TVar (TV n _) ->
    if n == id then Just t else Nothing

  TCon _ _ ->
    Nothing

  TApp l r ->
    case (l, r) of
      (TVar (TV n _), _) | n == id ->
        Just t

      _ ->
        case (searchTypeInConstructor id l, searchTypeInConstructor id r) of
          (Just x, _     ) -> Just x
          (_     , Just x) -> Just x
          _                -> Nothing

  _ ->
    Nothing


-- utility to create an empty canonical node
ec :: a -> Canonical a
ec = Canonical emptyArea


chars :: [String]
chars = ("f_"++) . show <$> [0..]


generateCtorParamPatternNames :: Char -> [Typing] -> [String]
generateCtorParamPatternNames prefix typings =
  (prefix:) . show . fst <$> zip [0..] typings


buildConstructorIsForEq :: Constructor -> Is
buildConstructorIsForEq ctor = case ctor of
  Canonical _ (Constructor name typings _ _) ->
    let aVars = generateCtorParamPatternNames 'a' typings
        bVars = generateCtorParamPatternNames 'b' typings
        conditions =
          if null typings then
            ec $ LBool "true"
          else
            foldr
              (\(aVar, bVar) previousCondition ->
                  ec $ App
                    (ec $ App
                      (ec $ Var "&&")
                      (ec $ App
                        (ec $ App
                          (ec $ Var "==")
                          (ec $ Var aVar)
                          False
                        )
                        (ec $ Var bVar)
                        True
                      )
                      False
                    )
                    previousCondition
                    True
              )
              (ec $ LBool "true")
              (zip aVars bVars)
    in
      ec $ Is (ec $ PTuple [
        ec $ PCon name (ec . PVar <$> aVars),
        ec $ PCon name (ec . PVar <$> bVars)
      ]) conditions


buildFieldConditions :: [String] -> Exp
buildFieldConditions =
  foldr
    (\fieldName previousCondition ->
      ec $ App
        (ec $ App
          (ec $ Var "&&")
          (ec $ App
            (ec $ App
              (ec $ Var "==")
              (ec $ Access (ec $ Var "__$a__") (ec $ Var ('.':fieldName)))
              False
            )
            (ec $ Access (ec $ Var "__$b__") (ec $ Var ('.':fieldName)))
            True
          )
          False
        )
        previousCondition
        True
    )
    (ec $ LBool "true")


deriveEqInstance :: InstanceToDerive -> Maybe Instance
deriveEqInstance toDerive = case toDerive of
  TypeDeclToDerive (Canonical _ ADT { adtparams, adtconstructors, adtType }) ->
    let constructorTypes = getCtorType <$> adtconstructors
        varsInType  = Set.toList $ Set.fromList $ concat $ (\t -> mapMaybe (`searchTypeInConstructor` t) adtparams) <$> constructorTypes
        instPreds  =
          (\varInType ->
              IsIn "Eq" [varInType] Nothing
          ) <$> varsInType
        inst =
          ec (
            Instance
            "Eq"
            instPreds
            (IsIn "Eq" [adtType] Nothing)
            (
              Map.singleton
              "=="
              (
                ec (Assignment "==" (ec $ Abs (ec "__$a__") [ec $ Abs (ec "__$b__") [
                  ec $ Where (ec (TupleConstructor [ec $ Var "__$a__", ec $ Var "__$b__"]))
                    (
                      (buildConstructorIsForEq <$> adtconstructors)
                        ++  [
                              -- if no previous pattern matches then the two values are not equal
                              ec $ Is (ec PAny) (ec $ LBool "false")
                            ]
                    )
                ]]))
              )
            )
          )
    in  Just inst

  RecordToDerive fieldNames ->
    let fieldNamesWithVars = zip (Set.toList fieldNames) chars
        fields             = TVar . (`TV` Star) <$> Map.fromList fieldNamesWithVars
        recordType         = TRecord fields Nothing
        instPreds          = (\var -> IsIn "Eq" [var] Nothing) <$> Map.elems fields
    in  Just $ ec (Instance "Eq" instPreds (IsIn "Eq" [recordType] Nothing) (
          Map.singleton
          "=="
          (
            ec (Assignment "==" (ec $ Abs (ec "__$a__") [ec $ Abs (ec "__$b__") [
              buildFieldConditions (Set.toList fieldNames)
            ]]))
          )
        ))


  _ ->
    undefined


inspectFields :: [String] -> Exp
inspectFields fieldNames =
  let fields =
        (\fieldName ->
            let fieldNameStr = ec $ LStr ("\""<> fieldName <> ": \"")
                fieldValue   = ec $ Access (ec $ Var "__$a__") (ec $ Var ('.':fieldName))
                inspectedFieldValue = ec $ App (ec $ Var "inspect") fieldValue True
            in  ec $ App (ec $ App (ec $ Var "++") fieldNameStr False) inspectedFieldValue True
        ) <$> fieldNames
      commaSeparated = List.intersperse (ec $ LStr "\", \"") fields
  in  ec $ TemplateString ([ec $ LStr "\"{ \""] ++ commaSeparated ++ [ec $ LStr "\" }\""])


buildConstructorIsForInspect :: Constructor -> Is
buildConstructorIsForInspect ctor = case ctor of
  Canonical _ (Constructor name typings _ _) ->
    let vars = generateCtorParamPatternNames 'a' typings
        inspected =
          if null typings then
            ec $ LStr ("\"" <> name <> "\"")
          else
            let constructorNameLStr = ec $ LStr ("\"" <> name <> "(\"")
                closingParenthesis  = ec $ LStr "\")\""
                inspectedValues     = (\var -> ec $ App (ec $ Var "inspect") (ec $ Var var) True) <$> vars
                commaSeparated      = List.intersperse (ec $ LStr "\", \"") inspectedValues
            in  ec $ TemplateString ([constructorNameLStr] ++ commaSeparated ++ [closingParenthesis])
    in
      ec $ Is (ec $ PCon name (ec . PVar <$> vars)) inspected


deriveInspectInstance :: InstanceToDerive -> Maybe Instance
deriveInspectInstance toDerive = case toDerive of
  TypeDeclToDerive (Canonical _ ADT { adtparams, adtconstructors, adtType }) ->
    let constructorTypes = getCtorType <$> adtconstructors
        varsInType  = Set.toList $ Set.fromList $ concat $ (\t -> mapMaybe (`searchTypeInConstructor` t) adtparams) <$> constructorTypes
        instPreds   = (\varInType -> IsIn "Inspect" [varInType] Nothing) <$> varsInType
        inst =
          ec (
            Instance
            "Inspect"
            instPreds
            (IsIn "Inspect" [adtType] Nothing)
            (
              Map.singleton
              "inspect"
              (
                ec (Assignment "inspect" (ec $ Abs (ec "__$a__") [
                  ec $ Where (ec $ Var "__$a__")
                    (
                      (buildConstructorIsForInspect <$> adtconstructors)
                        ++  [
                              -- if no previous pattern matches then the two values are not equal
                              ec $ Is (ec PAny) (ec $ LStr "\"Unknown\"")
                            ]
                    )
                ]))
              )
            )
          )
    in  Just inst

  RecordToDerive fieldNames ->
    let fieldNamesWithVars = zip (Set.toList fieldNames) chars
        fields             = TVar . (`TV` Star) <$> Map.fromList fieldNamesWithVars
        recordType         = TRecord fields Nothing
        instPreds          = (\var -> IsIn "Inspect" [var] Nothing) <$> Map.elems fields
    in  Just $ ec (Instance "Inspect" instPreds (IsIn "Inspect" [recordType] Nothing) (
          Map.singleton
          "inspect"
          (
            ec (Assignment "inspect" (ec $ Abs (ec "__$a__") [
              inspectFields (Set.toList fieldNames)
            ]))
          )
        ))


  _ ->
    undefined
