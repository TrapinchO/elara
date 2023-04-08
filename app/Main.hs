{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}

module Main (
  main,
) where

import Elara.AST.Module
import Elara.AST.Select hiding (moduleName)
import Elara.ASTToCore qualified as ASTToCore (desugar)
import Elara.Core.Module qualified as Core
import Elara.Data.Pretty
import Elara.Desugar (desugar, runDesugar)
import Elara.Error
import Elara.Error.Codes qualified as Codes (fileReadError)
import Elara.Lexer.Reader
import Elara.Lexer.Token (Lexeme)
import Elara.Lexer.Utils
import Elara.ModuleGraph (ModuleGraph, allEntries, createGraph, traverseGraph, traverseGraphRevTopologically)
import Elara.Parse
import Elara.Parse.Stream
import Elara.Rename (rename, runRenamer)
import Elara.Shunt
import Elara.TypeInfer qualified as Infer
import Elara.TypeInfer.Infer (initialStatus)
import Error.Diagnose (Diagnostic, Report (Err), prettyDiagnostic)
import Polysemy (Member, Sem, runM, subsume_)
import Polysemy.Embed
import Polysemy.Error
import Polysemy.Maybe (MaybeE, justE, nothingE, runMaybe)
import Polysemy.Reader
import Polysemy.State
import Polysemy.Writer (runWriter)
import Prettyprinter.Render.Text
import Print (printPretty)

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  s <- runElara
  putDoc (prettyDiagnostic True 4 s)
  putStrLn ""

runElara :: IO (Diagnostic (Doc ann))
runElara = runM $ execDiagnosticWriter $ runMaybe $ do
  source <- loadModule "source.elr"
  prelude <- loadModule "prelude.elr"
  let graph = createGraph [source, prelude]
  shuntedGraph <- traverseGraph (renameModule graph >=> shuntModule) graph
  typedGraph <- inferModules shuntedGraph
  printPretty (allEntries typedGraph)
  corePath <- traverseGraph (toCore typedGraph) typedGraph
  printPretty (allEntries corePath)

readFileString :: (Member (Embed IO) r, Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r) => FilePath -> Sem r String
readFileString path = do
  contentsBS <- readFileBS path
  case decodeUtf8Strict contentsBS of
    Left err -> do
      writeReport (Err (Just Codes.fileReadError) ("Could not read " <> pretty path <> ": " <> show err) [] []) *> nothingE
    Right contents -> do
      addFile path contents
      justE contents

lexFile :: (Member (Embed IO) r, Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r) => FilePath -> Sem r (String, [Lexeme])
lexFile path = do
  contents <- readFileString path
  case evalLexMonad path contents readTokens of
    Left err -> report err *> nothingE
    Right lexemes -> do
      justE (contents, lexemes)

parseModule :: (Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r) => FilePath -> (String, [Lexeme]) -> Sem r (Module Frontend)
parseModule path (contents, lexemes) = do
  let tokenStream = TokenStream contents lexemes
  case parse path tokenStream of
    Left parseError -> do
      report parseError *> nothingE
    Right m -> justE m

desugarModule :: (Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r) => Module Frontend -> Sem r (Module Desugared)
desugarModule m = do
  case runDesugar (desugar m) of
    Left err -> report err *> nothingE
    Right desugared -> justE desugared

renameModule ::
  (Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r, Member (Embed IO) r) =>
  ModuleGraph (Module Desugared) ->
  Module Desugared ->
  Sem r (Module Renamed)
renameModule mp m = do
  y <- subsume_ $ runRenamer mp (rename m)
  case y of
    Left err -> report err *> nothingE
    Right renamed -> justE renamed

shuntModule :: (Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r) => Module Renamed -> Sem r (Module Shunted)
shuntModule m = do
  x <-
    runError $
      runWriter $
        runReader (fromList []) (shunt m)
  case x of
    Left err -> report err *> nothingE
    Right (warnings, shunted) -> do
      traverse_ report warnings
      justE shunted

inferModules :: (Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r) => ModuleGraph (Module Shunted) -> Sem r (ModuleGraph (Module Typed))
inferModules modules = do
  runErrorOrReport (evalState initialStatus (traverseGraphRevTopologically Infer.inferModule modules))

toCore :: (Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r) => ModuleGraph (Module Typed) -> Module Typed -> Sem r Core.Module
toCore mp m = do
  runErrorOrReport (ASTToCore.desugar mp m)

loadModule :: (Member (DiagnosticWriter (Doc ann)) r, Member (Embed IO) r, Member MaybeE r) => FilePath -> Sem r (Module Desugared)
loadModule fp = (lexFile >=> parseModule fp >=> desugarModule) fp

runErrorOrReport ::
  (Member (DiagnosticWriter (Doc ann)) r, Member MaybeE r, ReportableError e) =>
  Sem (Error e ': r) a ->
  Sem r a
runErrorOrReport e = do
  x <- subsume_ (runError e)
  case x of
    Left err -> report err *> nothingE
    Right a -> justE a
