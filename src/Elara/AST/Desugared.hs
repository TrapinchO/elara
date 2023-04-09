{-# LANGUAGE TemplateHaskell #-}

module Elara.AST.Desugared where

import Control.Lens.TH
import Elara.AST.Name (LowerAlphaName, MaybeQualified, ModuleName, Name, OpName, TypeName, VarName)
import Elara.AST.Region (Located)

{- |
  This is the second main AST stage, which is very similar to the `Elara.AST.Frontend.Expr` AST, with a few key differences:

    * Lambdas only have 1 argument (ones with multiple arguments are desugared into nested lambdas)
    * Let bindings have no patterns, they are desugared into lambdas
    * Def and Let declarations are merged into a single entity
-}
data Expr'
    = Int Integer
    | Float Double
    | String Text
    | Char Char
    | Unit
    | Var (Located (MaybeQualified VarName))
    | Constructor (Located (MaybeQualified TypeName))
    | Lambda Pattern Expr
    | FunctionCall Expr Expr
    | If Expr Expr Expr
    | BinaryOperator BinaryOperator Expr Expr
    | List [Expr]
    | Match Expr [(Pattern, Expr)]
    | LetIn (Located VarName) Expr Expr
    | Let (Located VarName) Expr
    | Block (NonEmpty Expr)
    | -- | Required for operator shunting
      InParens Expr
    | Tuple (NonEmpty Expr)
    deriving (Show, Eq)

newtype Expr = Expr (Located Expr')
    deriving (Show, Eq)

data Pattern'
    = VarPattern (Located VarName)
    | ConstructorPattern (Located (MaybeQualified TypeName)) [Pattern]
    | ListPattern [Pattern]
    | WildcardPattern
    | IntegerPattern Integer
    | FloatPattern Double
    | StringPattern Text
    | CharPattern Char
    deriving (Show, Eq)

newtype Pattern = Pattern (Located Pattern')
    deriving (Show, Eq)

data BinaryOperator'
    = Op (Located (MaybeQualified OpName))
    | Infixed (Located (MaybeQualified VarName))
    deriving (Show, Eq)

newtype BinaryOperator = MkBinaryOperator (Located BinaryOperator')
    deriving (Show, Eq)

data Type
    = TypeVar LowerAlphaName
    | FunctionType (Located Type) (Located Type)
    | UnitType
    | TypeConstructorApplication (Located Type) (Located Type)
    | UserDefinedType (Located (MaybeQualified TypeName))
    | RecordType (NonEmpty (Located VarName, Located Type))
    | TupleType (NonEmpty (Located Type))
    deriving (Show, Eq)

newtype Declaration = Declaration (Located Declaration')
    deriving (Show, Eq)

data Declaration' = Declaration'
    { _declaration'Module' :: Located ModuleName
    , _declaration'Name :: Located Name
    , _declaration'Body :: DeclarationBody
    }
    deriving (Show, Eq)

newtype DeclarationBody = DeclarationBody (Located DeclarationBody')
    deriving (Show, Eq)

data DeclarationBody'
    = -- | let <p> = <e> and / or def <name> : <type>
      Value
        { _expression :: Expr
        , _valueType :: Maybe (Located Type)
        }
    | -- | Unused for now
      NativeDef (Located Type)
    | -- | type <name> <vars> = <type>
      TypeDeclaration [Located LowerAlphaName] (Located TypeDeclaration)
    deriving (Show, Eq)

data TypeDeclaration
    = ADT (NonEmpty (Located TypeName, [Located Type]))
    | Alias (Located Type)
    deriving (Show, Eq)

makeLenses ''Declaration'
makeClassy ''Declaration
makeClassy ''DeclarationBody'
makePrisms ''Declaration
makePrisms ''DeclarationBody
makePrisms ''TypeDeclaration
makePrisms ''Expr
makePrisms ''Pattern
makePrisms ''BinaryOperator
