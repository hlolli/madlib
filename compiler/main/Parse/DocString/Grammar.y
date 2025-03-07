{
module Parse.DocString.Grammar where

import           Text.Printf
import           Control.Monad.Except
import           Data.Char(isSpace)
import           Data.List(isSuffixOf, foldl')
import           Parse.DocString.Lexer
import           Infer.Type
import           Parse.DocString.DocString
import           Explain.Location
import           Run.Target
import           Text.Regex.TDFA
import           Text.Show.Pretty (ppShow)
}

%name parseDocStrings docs
%tokentype { Token }
%error { parseError }
%monad { Alex }
%lexer { lexerWrap } { TokenEOF }

%token
  'moduleStart'    { TokenModuleDocStringStart _ }
  'functionStart'  { TokenFunctionDocStringStart _ _ }
  'typeDefStart'   { TokenTypeDefDocStringStart _ _ }
  'interfaceStart' { TokenInterfaceDocStringStart _ _ }
  'instanceStart'  { TokenInstanceDocStringStart _ _ }
  'end'            { TokenDocStringEnd _ }
  'docStringPart'  { TokenDocStringCharacter _ _ }
  'exampleStart'   { TokenExampleStart _ }
  'sinceStart'     { TokenSinceStart _ }

%%

docs :: { [DocString] }
  : doc { [$1] }
  | doc docs { $1 : $2 }

doc :: { DocString }
  : 'moduleStart' parts 'end'         { ModuleDoc (tokenTarget $1) (processCharacters $2) }
  | 'functionStart' parts tags 'end'  { FunctionDoc (tokenTarget $1) (getFunctionName $1) (processCharacters $2) $3 }
  | 'typeDefStart' parts tags 'end'   { TypeDefDoc (tokenTarget $1) (getTypeName $1) (processCharacters $2) $3 }
  | 'interfaceStart' parts tags 'end' { InterfaceDoc (tokenTarget $1) (getInterfaceName $1) (processCharacters $2) $3 }
  | 'instanceStart' parts tags 'end'  { InstanceDoc (tokenTarget $1) (trim $ getInstanceName $1) (processCharacters $2) $3 }

parts :: { [String] }
  : 'docStringPart'       { [getDocStringCharacter $1] }
  | 'docStringPart' parts { getDocStringCharacter $1 : $2 }

tags :: { [DocStringTag] }
  : 'exampleStart' parts tags { ExampleTag (tokenTarget $1) (processCharacters $2) : $3 }
  | 'sinceStart' parts tags   { SinceTag (tokenTarget $1) (processCharacters $2) : $3 }
  | {--}                      { [] }


{
toRegex :: String -> Regex
toRegex = makeRegexOpts defaultCompOpt { multiline = False } defaultExecOpt

trim :: String -> String
trim = f . f
  where f = reverse . dropWhile isSpace

regex :: String
regex = "\n[ ]*\\*[ ]?"

sanitizeDescription :: String -> String
sanitizeDescription desc =
  let matched = match (toRegex regex) desc :: (String, String, String)
  in  case matched of
    (before, "", "") ->
      let trimmed = trim desc
      in
        if isSuffixOf "\n" trimmed then
          sanitizeDescription (init $ init trimmed)
        else trimmed
    (before, _, after) ->
      if before == "" then
        sanitizeDescription after
      else if after == "" then
        sanitizeDescription before
      else
        sanitizeDescription $ before <> "\n" <> after


processCharacters :: [String] -> String
processCharacters chars =
  let assembled = foldl' (<>) "" chars
  in  sanitizeDescription assembled


lexerWrap :: (Token -> Alex a) -> Alex a
lexerWrap f = alexMonadScan >>= f

parseError :: Token -> Alex a
parseError token =
  alexError $ "invalid token: " <> ppShow token

parse :: String -> Either String [DocString]
parse s = runAlex s parseDocStrings
}
