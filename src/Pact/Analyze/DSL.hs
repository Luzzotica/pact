{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Pact.Analyze.DSL
  ( analyzeAndRenderTests
  , _compileTests
  ) where

import Pact.Analyze.Types
import Pact.Typecheck hiding (debug)
import Pact.Types

import Control.Exception
import Data.Decimal
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import SmtLib.Syntax.Syntax
import qualified SmtLib.Syntax.Syntax as Smt
import qualified SmtLib.Syntax.ShowSL as SmtShow

import Text.Parsec hiding (try)
import qualified Text.Parsec as Parsec

data ProverTest =
  ColumnRange
  { _ptcFunc :: String
  , _ptcValue :: Decimal} |
  ConservesMass
  deriving (Show, Eq)

data ProveProperty = ProveProperty
  { _dtTable :: String
  , _dtColumn :: String
  , _dtTests :: [ProverTest]
  } deriving (Show, Eq)

type Parser a = Parsec String () a

parseAsDecimal :: Parser Decimal
parseAsDecimal = do
  a <- many1 digit
  _ <- char '.'
  b <- many1 digit
  return $ read $ a ++ "." ++ b

parserAsInt :: Parser Decimal
parserAsInt = many1 digit >>= return . read

supportedOpSyms :: Parser String
supportedOpSyms = Parsec.try (string ">=" <|> string "<=" <|> string "==") <|> string ">" <|> string "=" <|> string "<"

parseColRange :: Parser ProverTest
parseColRange = do
  _ <- spaces
  _ <- string "Column"
  _ <- spaces
  fn <- supportedOpSyms
  _ <- spaces
  n <- parserAsInt <|> parseAsDecimal
  return $ ColumnRange fn n

parseConservesMass :: Parser ProverTest
parseConservesMass = spaces >> string "ConservesMass" >> spaces >> return ConservesMass

parseColName :: Parser (String,String)
parseColName = do
  _ <- spaces >> char '\''
  module' <- many1 (noneOf ".")
  _ <- char '.'
  table' <- many1 (noneOf ".")
  _ <- char '.'
  column' <- many1 (noneOf "'")
  _ <- char '\''
  return (module' ++ "." ++ table', column')

parseProveTest :: Parser [ProverTest]
parseProveTest = do
  _ <- spaces >> char '['
  tests <- sepBy1 (Parsec.try parseConservesMass <|> parseColRange) (char ',')
  _ <- spaces >> char ']'
  return tests

parseProperty :: Parser ProveProperty
parseProperty = do
  _ <- string "{-#" >> spaces >> string "PROVE"
  (table', column') <- parseColName
  pts <- parseProveTest
  _ <- spaces >> string "#-}" >> spaces
  return $ ProveProperty { _dtTable = table', _dtColumn = column', _dtTests = pts}

parseDocString :: Parser [ProveProperty]
parseDocString = do
  _ <- manyTill anyChar (lookAhead $ Parsec.try $ string "{-#")
  pp <- many1 parseProperty
  return pp

getTestsFromDoc :: TopLevel Node -> [ProveProperty]
getTestsFromDoc (TopFun (FDefun{..})) = case _fDocs of
  Nothing -> throw $ SmtCompilerException "getTestsFromDoc" "No doc string string found!"
  Just docs -> case parse parseDocString "" docs of
    Left err -> throw $ SmtCompilerException "getTestsFromDoc" $ show err
    Right pps -> pps
getTestsFromDoc _ = throw $ SmtCompilerException "getTestsFromDoc" "Not given a top-level defun"

renderProverTest :: String -> String -> ([SymName], [SymName]) -> ProverTest -> [Smt.Command]
renderProverTest table' column' (reads', writes') ColumnRange{..} =
    preamble ++ (constructDomainAssertion <$> reads') ++ [constructRangeAssertion] ++ exitCmds
  where
    preamble = [Push 1, Echo $ "\"Verifying Domain and Range Stability (by attempting to violate it) for: " ++ table' ++ "." ++ column' ++ "\""]
    constructDomainAssertion (SymName sn) = Assert (TermQualIdentifierT (QIdentifier (ISymbol _ptcFunc))
                                         [TermQualIdentifier (QIdentifier (ISymbol sn))
                                         ,TermSpecConstant (SpecConstantDecimal $ show _ptcValue)])
    constructIndividualRangeAsserts (SymName sn) = TermQualIdentifierT (QIdentifier (ISymbol "not"))
                                                   [TermQualIdentifierT (QIdentifier (ISymbol _ptcFunc))
                                                    [TermQualIdentifier (QIdentifier (ISymbol sn)),TermSpecConstant (SpecConstantDecimal $ show _ptcValue)]]
    constructRangeAssertion = Assert (TermQualIdentifierT (QIdentifier (ISymbol "or")) (constructIndividualRangeAsserts <$> writes'))
    exitCmds = [Echo "\"Domain/Range relation holds IFF unsat\"", CheckSat, Pop 1]
renderProverTest table' column' (reads', writes') ConservesMass =
    preamble ++ [mkRelation] ++ exitCmds
  where
    preamble = [Push 1, Echo $ "\"Verifying mass conservation (by attempting to violate it) for: " ++ table' ++ "." ++ column' ++ "\""]
    symNameToTerm (SymName sn) = TermQualIdentifier (QIdentifier (ISymbol sn))
    mkRelation = Assert (TermQualIdentifierT
                         (QIdentifier (ISymbol "not"))
                         [TermQualIdentifierT (QIdentifier (ISymbol "="))
                          [TermQualIdentifierT (QIdentifier (ISymbol "+")) (symNameToTerm <$> reads')
                          ,TermQualIdentifierT (QIdentifier (ISymbol "+")) (symNameToTerm <$> writes')
                          ]])
    exitCmds = [Echo "\"Mass is conserved IFF unsat\"", CheckSat, Pop 1]

-- | Go through declared variables and gather a list of those read from a given table's column and those written to it
varsFromTable :: TableAccess -> String -> String -> CompilerState -> [SymName]
varsFromTable ta table' column' (CompilerState _ tvars) = _svName <$> (Set.toList $ Map.keysSet $ Map.filter (\OfTableColumn{..} -> ta == _otcAccess && table' == _otcTable && column' == _otcColumn) tvars)

renderTestsFromState :: CompilerState -> ProveProperty -> [String]
renderTestsFromState cs ProveProperty{..} =
    let readVars = varsFromTable TableRead _dtTable _dtColumn cs
        writeVars = varsFromTable TableWrite _dtTable _dtColumn cs
        tests = SmtShow.showSL <$> (concat $ renderProverTest _dtTable _dtColumn (readVars, writeVars) <$> _dtTests)
    in
      if null readVars || null writeVars
      then throw $ SmtCompilerException "renderTestsFromState" $ "Unable To Construct Tests: Either no readVars or writeVars found. This is usually an issue with the column specification -- make sure it is '<module-name>.<table-name>.<column-name>'\n" ++ (show $ _csTableAssoc cs)
      else if (length readVars == length writeVars)
       then tests
       else throw $ SmtCompilerException "renderTestsFromState" "Unable To Construct Tests: there was an inequal number of read and written variables for a given column. This is usually an issue with the column specification -- make sure it is '<module-name>.<table-name>.<column-name>'"

analyzeAndRenderTests :: Bool -> TopLevel Node -> IO (Either SmtCompilerException [String])
analyzeAndRenderTests dbg tf = try $ do
  analysisRes <- analyzeFunction tf dbg
  case analysisRes of
    Left err -> throw err
    Right (compState, compiledFn) -> do
      pps <- return $ getTestsFromDoc tf
      tests <- return $ renderTestsFromState compState <$> pps
      return $ (encodeSmt <$> compiledFn) ++ concat tests

_compileTests :: Bool -> FilePath -> String -> String -> IO ()
_compileTests dbg fp mod' func = do
  f <- fst <$> inferFun False fp (ModuleName mod') func
  res <- analyzeAndRenderTests dbg f
  case res of
    Left err -> putStrLn $ show err
    Right smt -> putStrLn $ unlines smt
