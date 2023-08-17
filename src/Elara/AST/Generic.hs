{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-partial-type-signatures #-}

module Elara.AST.Generic where

-- import Elara.AST.Frontend qualified as Frontend

import Control.Lens (view, (^.))
import Data.Data (Data)
import Data.Generics.Wrapped
import Data.Kind qualified as Kind
import Elara.AST.Name (ModuleName, VarName (..))
import Elara.AST.Pretty
import Elara.AST.Region (Located, unlocated)
import Elara.AST.Select (LocatedAST, UnlocatedAST)
import Elara.AST.StripLocation (StripLocation (..))
import Elara.Data.Pretty
import GHC.TypeLits
import Relude.Extra (bimapF)
import TODO (todo)
import Prelude hiding (group)

data DataConCantHappen deriving (Generic, Data, Show)

dataConCantHappen :: DataConCantHappen -> a
dataConCantHappen x = case x of {}

data NoFieldValue = NoFieldValue
    deriving (Generic, Data, Show)

instance Pretty NoFieldValue where
    pretty :: HasCallStack => NoFieldValue -> Doc AnsiStyle
    pretty _ = error "This instance should never be used"

{- | Used to select a field type for a given AST.

Conventions for usage:
If a selection is likely to be one of the "principal" newtypes ('Expr', 'Pattern', etc), it should not be wrapped in 'ASTLocate',
as this increases friction and creates redundant 'Located' wrappers.
This means that implementations should manually wrap in 'Locate' if not using one of the principle newtypes
-}
type family Select (s :: Symbol) (ast :: a) = (v :: Kind.Type)

data Expr' (ast :: a)
    = Int Integer
    | Float Double
    | String Text
    | Char Char
    | Unit
    | Var (ASTLocate ast (Select "VarRef" ast))
    | Constructor (ASTLocate ast (Select "ConRef" ast))
    | Lambda
        (ASTLocate ast (Select "LambdaPattern" ast))
        (Expr ast)
    | FunctionCall (Expr ast) (Expr ast)
    | If (Expr ast) (Expr ast) (Expr ast)
    | BinaryOperator (BinaryOperator ast) (Expr ast) (Expr ast)
    | List [Expr ast]
    | Match (Expr ast) [(Pattern ast, Expr ast)]
    | LetIn
        (ASTLocate ast (Select "LetParamName" ast))
        (Select "LetPattern" ast)
        (Expr ast)
        (Expr ast)
    | Let
        (ASTLocate ast (Select "LetParamName" ast))
        (Select "LetPattern" ast)
        (Expr ast)
    | Block (NonEmpty (Expr ast))
    | InParens !(Select "InParens" ast)
    | Tuple (NonEmpty (Expr ast))
    deriving (Generic)

newtype Expr (ast :: a) = Expr (ASTLocate ast (Expr' ast), Select "ExprType" ast)
    deriving (Generic)

typeOf :: forall ast. Expr ast -> Select "ExprType" ast
typeOf (Expr (_, t)) = t

data Pattern' (ast :: a)
    = VarPattern (ASTLocate ast (Select "VarPat" ast))
    | ConstructorPattern (ASTLocate ast (Select "ConPat" ast)) [Pattern ast]
    | ListPattern [Pattern ast]
    | ConsPattern (Pattern ast) (Pattern ast)
    | WildcardPattern
    | IntegerPattern Integer
    | FloatPattern Double
    | StringPattern Text
    | CharPattern Char
    | UnitPattern
    deriving (Generic)

newtype Pattern (ast :: a) = Pattern (ASTLocate ast (Pattern' ast), Select "PatternType" ast)
    deriving (Generic)

data BinaryOperator' (ast :: a)
    = SymOp (ASTLocate ast (Select "SymOp" ast))
    | Infixed (ASTLocate ast (Select "Infixed" ast))
    deriving (Generic)

newtype BinaryOperator ast = MkBinaryOperator (ASTLocate ast (BinaryOperator' ast))
    deriving (Generic)

newtype Declaration ast = Declaration (ASTLocate ast (Declaration' ast))
    deriving (Generic)

data Declaration' (ast :: a) = Declaration'
    { moduleName :: ASTLocate ast ModuleName
    , name :: ASTLocate ast (Select "DeclarationName" ast)
    , body :: DeclarationBody ast
    }
    deriving (Generic)

newtype DeclarationBody (ast :: a) = DeclarationBody (ASTLocate ast (DeclarationBody' ast))
    deriving (Generic)

data DeclarationBody' (ast :: a)
    = -- | let <p> = <e>
      Value
        { _expression :: Expr ast
        , _patterns :: Select "ValuePatterns" ast
        , _valueType :: Select "ValueType" ast
        }
    | -- | def <name> : <type>.
      ValueTypeDef !(Select "ValueTypeDef" ast)
    | -- | type <name> <vars> = <type>
      TypeDeclaration
        [ASTLocate ast (Select "TypeVar" ast)]
        (ASTLocate ast (TypeDeclaration ast))
    deriving (Generic)

data TypeDeclaration ast
    = ADT (NonEmpty (ASTLocate ast (Select "ConstructorName" ast), [Type ast]))
    | Alias (Type ast)
    deriving (Generic)

newtype Type ast = Type (ASTLocate ast (Type' ast))
    deriving (Generic)

data Type' ast
    = TypeVar (ASTLocate ast (Select "TypeVar" ast))
    | FunctionType (Type ast) (Type ast)
    | UnitType
    | TypeConstructorApplication (Type ast) (Type ast)
    | UserDefinedType (ASTLocate ast (Select "UserDefinedType" ast))
    | RecordType (NonEmpty (ASTLocate ast VarName, Type ast))
    | TupleType (NonEmpty (Type ast))
    | ListType (Type ast)
    deriving (Generic)

-- Ttg stuff

type RUnlocate :: ast -> Kind.Constraint
class RUnlocate ast where
    rUnlocate ::
        forall a.
        CleanupLocated (Located a) ~ Located a =>
        ASTLocate ast a ->
        a

    fmapUnlocated ::
        forall a b.
        (CleanupLocated (Located a) ~ Located a, CleanupLocated (Located b) ~ Located b) =>
        (a -> b) ->
        ASTLocate ast a ->
        ASTLocate ast b

instance (ASTLocate' ast ~ Located) => RUnlocate (ast :: LocatedAST) where
    rUnlocate = view unlocated
    fmapUnlocated = fmap

instance (ASTLocate' ast ~ Unlocated) => RUnlocate (ast :: UnlocatedAST) where
    rUnlocate = identity
    fmapUnlocated f = f

type ASTLocate :: a -> Kind.Type -> Kind.Type
type ASTLocate ast a = CleanupLocated (ASTLocate' ast a)

type FullASTQual :: a -> Kind.Type -> Kind.Type
type FullASTQual ast a = ((ASTLocate ast) (ASTQual ast a))

newtype Unlocated a = Unlocated a

-- | Unwraps a single layer of 'Unlocated' from a type.
type family CleanupLocated g where
    CleanupLocated (Unlocated a) = a
    CleanupLocated (Located (Located a)) = CleanupLocated a
    -- Remove located wrappers for the newtypes
    CleanupLocated (Located (Expr a)) = CleanupLocated (Expr a)
    CleanupLocated (Located (Pattern a)) = CleanupLocated (Pattern a)
    CleanupLocated (Located (BinaryOperator a)) = CleanupLocated (BinaryOperator a)
    CleanupLocated (Located (Declaration a)) = CleanupLocated (Declaration a)
    CleanupLocated (Located (DeclarationBody a)) = CleanupLocated (DeclarationBody a)
    CleanupLocated (Located (Type a)) = CleanupLocated (Type a)
    CleanupLocated a = a

type family ASTLocate' (ast :: a) :: Kind.Type -> Kind.Type

type family ASTQual (ast :: a) :: Kind.Type -> Kind.Type

-- Coercions

coerceTypeDeclaration :: _ => TypeDeclaration ast1 -> TypeDeclaration ast2
coerceTypeDeclaration (Alias a) = Alias (coerceType a)
coerceTypeDeclaration (ADT a) = ADT (fmap coerceType <<$>> a)

coerceType :: _ => Type ast1 -> Type ast2
coerceType (Type a) = Type (coerceType' <$> a)

coerceType' :: _ => Type' ast1 -> Type' ast2
coerceType' (TypeVar a) = TypeVar a
coerceType' (FunctionType a b) = FunctionType (coerceType a) (coerceType b)
coerceType' UnitType = UnitType
coerceType' (TypeConstructorApplication a b) = TypeConstructorApplication (coerceType a) (coerceType b)
coerceType' (UserDefinedType a) = UserDefinedType a
coerceType' (RecordType a) = RecordType (fmap coerceType <$> a)
coerceType' (TupleType a) = TupleType (coerceType <$> a)
coerceType' (ListType a) = ListType (coerceType a)

-- Pretty printing

deriving newtype instance Pretty (ASTLocate ast (BinaryOperator' ast)) => Pretty (BinaryOperator ast)

deriving newtype instance Pretty (ASTLocate ast (Type' ast)) => Pretty (Type ast)
instance
    ( Pretty (ASTLocate ast (Declaration' ast))
    ) =>
    Pretty (Declaration ast)
    where
    pretty (Declaration ldb) = pretty ldb

data UnknownPretty = forall a. Pretty a => UnknownPretty a

instance Pretty UnknownPretty where
    pretty (UnknownPretty a) = pretty a

instance
    ( Pretty (Expr ast)
    , Pretty (CleanupLocated (ASTLocate' ast (Select "TypeVar" ast)))
    , Pretty (CleanupLocated (ASTLocate' ast (Select "DeclarationName" ast)))
    , Pretty (CleanupLocated (ASTLocate' ast (TypeDeclaration ast)))
    , Pretty valueType
    , ToMaybe (Select "ValueType" ast) (Maybe valueType)
    , valueType ~ UnwrapMaybe (Select "ValueType" ast)
    , Pretty exprType
    , exprType ~ UnwrapMaybe (Select "ExprType" ast)
    , (ToMaybe (Select "ExprType" ast) (Maybe exprType))
    , RUnlocate (ast :: b)
    ) =>
    Pretty (Declaration' ast)
    where
    pretty (Declaration' _ n b) =
        let val = b ^. _Unwrapped
            y = rUnlocate @b @ast @(DeclarationBody' ast) val
         in prettyDB n y
      where
        -- The type of a 'Value' can appear in 2 places: Either as a field in 'Value''s constructor, or as the second field of the 'Expr' tuple
        -- We know that only one will ever exist at a time (in theory, this isn't a formal invariant) so need to find a way of handling both cases
        -- The fields have different types, but both are required to have a Pretty instance (see constraints above).
        -- 'prettyValueDeclaration' takes a 'Pretty a3 => Maybe a3' as its third argument, representing the type of the value.
        -- To make the two compatible, we create an existential wrapper 'UnknownPretty' which has a 'Pretty' instance, and use that as the type of the third argument.
        -- The converting of values to a 'Maybe' is handled by the 'ToMaybe' class.
        prettyDB n (Value e@(Expr (_, t)) _ t') =
            let typeOfE =
                    (UnknownPretty <$> (toMaybe t :: Maybe exprType)) -- Prioritise the type in the expression
                        <|> (UnknownPretty <$> (toMaybe t' :: Maybe valueType)) -- Otherwise, use the type in the declaration
             in prettyValueDeclaration n e typeOfE
        prettyDB n (TypeDeclaration vars t) = prettyTypeDeclaration n vars t

instance Pretty (TypeDeclaration ast) where
    pretty _ = "TODO"

{- | When fields may be optional, we need a way of representing that generally. This class does that.
 In short, it converts a type to a 'Maybe'. If the type is already a 'Maybe', it is left alone.
 If it is not, it is wrapped in a 'Just'. If it is 'NoFieldValue', it is converted to 'Nothing'.
-}
class ToMaybe i o where
    toMaybe :: i -> o

instance {-# OVERLAPPING #-} ToMaybe NoFieldValue (Maybe a) where
    toMaybe _ = Nothing

instance ToMaybe (Maybe a) (Maybe a) where
    toMaybe = identity

instance {-# INCOHERENT #-} ToMaybe a (Maybe a) where
    toMaybe = Just

-- Sometimes fields are wrapped in functors eg lists, we need a way of transcending them.
-- This class does that.
-- For example, let's say we have `cleanPattern :: Pattern ast1 -> Pattern ast2`, and `x :: Select ast1 "Pattern"`.
-- `x` could be `Pattern ast1`, `[Pattern ast1]`, `Maybe (Pattern ast1)`, or something else entirely.
-- `cleanPattern` will only work on the first of these, so we need a way of lifting it to the others. Obviously, this sounds like a Functor
-- but the problem is that `Pattern ast1` has the wrong kind.
class ApplyAsFunctorish i o a b where
    applyAsFunctorish :: (a -> b) -> i -> o

instance Functor f => ApplyAsFunctorish (f a) (f b) a b where
    applyAsFunctorish = fmap

instance ApplyAsFunctorish a b a b where
    applyAsFunctorish f = f

instance ApplyAsFunctorish NoFieldValue NoFieldValue a b where
    applyAsFunctorish _ = identity

-- | Unwraps 1 level of 'Maybe' from a type. Useful when a type family returns Maybe
type family UnwrapMaybe (a :: Kind.Type) = (k :: Kind.Type) where
    UnwrapMaybe (Maybe a) = a
    UnwrapMaybe a = a

instance
    ( Pretty (CleanupLocated (ASTLocate' ast (Expr' ast)))
    , Pretty a1
    , ToMaybe (Select "ExprType" ast) (Maybe a1)
    , a1 ~ UnwrapMaybe (Select "ExprType" ast)
    ) =>
    Pretty (Expr ast)
    where
    pretty (Expr (e, t)) = group (flatAlt long short)
      where
        te = (":" <+>) . pretty <$> (toMaybe t :: Maybe a1)
        long = pretty e <+> pretty te
        short = align (pretty e <+> pretty te)

instance
    ( Pretty (Expr ast)
    , Pretty (CleanupLocated (ASTLocate' ast (Select "LambdaPattern" ast)))
    , Pretty (CleanupLocated (ASTLocate' ast (Select "ConRef" ast)))
    , Pretty (CleanupLocated (ASTLocate' ast (Select "VarRef" ast)))
    , Pretty (Pattern ast)
    , (Pretty (Select "InParens" ast))
    , (Pretty (CleanupLocated (ASTLocate' ast (Select "LetParamName" ast))))
    , Pretty a2
    , a2 ~ UnwrapMaybe (Select "LetPattern" ast)
    , (ToMaybe (Select "LetPattern" ast) (Maybe a2))
    ) =>
    Pretty (Expr' ast)
    where
    pretty (Int i) = pretty i
    pretty (Float f) = pretty f
    pretty (String s) = pretty '\"' <> pretty s <> pretty '\"'
    pretty (Char c) = "'" <> escapeChar c <> "'"
    pretty Unit = "()"
    pretty (Var v) = pretty v
    pretty (Constructor c) = pretty c
    pretty (Lambda ps e) = prettyLambdaExpr [ps] e
    pretty (FunctionCall e1 e2) = prettyFunctionCallExpr e1 e2
    pretty (If e1 e2 e3) = prettyIfExpr e1 e2 e3
    pretty (List l) = prettyListExpr l
    pretty (Match e m) = prettyMatchExpr e (prettyMatchBranch <$> m)
    pretty (LetIn v p e1 e2) = prettyLetInExpr v (maybeToList $ toMaybe p :: [a2]) e1 (Just e2)
    pretty (Let v p e) = prettyLetExpr v (maybeToList $ toMaybe p :: [a2]) e
    pretty (Block b) = prettyBlockExpr b
    pretty (InParens e) = parens (pretty e)
    pretty (Tuple t) = prettyTupleExpr t

instance
    ( Pretty a1
    , ToMaybe (Select "PatternType" ast) (Maybe a1)
    , a1 ~ UnwrapMaybe (Select "PatternType" ast)
    , (Pretty (CleanupLocated (ASTLocate' ast (Pattern' ast))))
    ) =>
    Pretty (Pattern ast)
    where
    pretty (Pattern (p, t)) = group (flatAlt long short)
      where
        te = (":" <+>) . pretty <$> (toMaybe t :: Maybe a1)
        long = pretty p <+> pretty te
        short = align (pretty p <+> pretty te)

instance
    ( Pretty (CleanupLocated (ASTLocate' ast (Select "VarPat" ast)))
    , Pretty (Pattern ast)
    , Pretty (CleanupLocated (ASTLocate' ast (Select "ConPat" ast)))
    ) =>
    Pretty (Pattern' ast)
    where
    pretty (VarPattern v) = pretty v
    pretty (ConstructorPattern c ps) = prettyConstructorPattern c ps
    pretty (ListPattern l) = prettyListPattern l
    pretty (ConsPattern p1 p2) = prettyConsPattern p1 p2
    pretty WildcardPattern = "_"
    pretty (IntegerPattern i) = pretty i
    pretty (FloatPattern f) = pretty f
    pretty (StringPattern s) = pretty '\"' <> pretty s <> pretty '\"'
    pretty (CharPattern c) = "'" <> escapeChar c <> "'"
    pretty UnitPattern = "()"

instance
    ( Pretty (ASTLocate ast (Type' ast))
    , Pretty (ASTLocate ast VarName)
    , Pretty (ASTLocate ast (Select "TypeVar" ast))
    , Pretty (ASTLocate ast (Select "UserDefinedType" ast))
    ) =>
    Pretty (Type' ast)
    where
    pretty = \case
        TypeVar name -> pretty name
        FunctionType a b -> parens (pretty a <+> "->" <+> pretty b)
        UnitType -> "()"
        TypeConstructorApplication a b -> pretty a <+> pretty b
        UserDefinedType name -> pretty name
        RecordType fields -> "{" <+> prettyFields fields <+> "}"
        TupleType fields -> tupled (map pretty (toList fields))
        ListType a -> "[" <+> pretty a <+> "]"
      where
        prettyFields = hsep . punctuate "," . map (\(name, value) -> pretty name <+> ":" <+> pretty value) . toList

stripExprLocation ::
    forall (ast1 :: LocatedAST) (ast2 :: UnlocatedAST).
    ( ASTLocate' ast1 ~ Located
    , ASTLocate' ast2 ~ Unlocated
    , ApplyAsFunctorish (Select "LambdaPattern" ast1) (Select "LambdaPattern" ast2) (Pattern ast1) (Pattern ast2)
    , _
    ) =>
    Expr ast1 ->
    Expr ast2
stripExprLocation (Expr (e :: ASTLocate ast1 (Expr' ast1), t)) =
    let e' = fmapUnlocated @LocatedAST @ast1 stripExprLocation' e
     in Expr (stripLocation e', fmap stripTypeLocation t)
  where
    stripExprLocation' :: Expr' ast1 -> Expr' ast2
    stripExprLocation' (Int i) = Int i
    stripExprLocation' (Float f) = Float f
    stripExprLocation' (String s) = String s
    stripExprLocation' (Char c) = Char c
    stripExprLocation' Unit = Unit
    stripExprLocation' (Var v) = Var (stripLocation v)
    stripExprLocation' (Constructor c) = Constructor (stripLocation c)
    stripExprLocation' (Lambda ps e) =
        let ps' = stripLocation ps
            ps'' =
                applyAsFunctorish @(Select "LambdaPattern" ast1) @(Select "LambdaPattern" ast2) @(Pattern ast1) @(Pattern ast2)
                    stripPatternLocation
                    ps'
         in Lambda ps'' (stripExprLocation e)
    stripExprLocation' (FunctionCall e1 e2) = FunctionCall (stripExprLocation e1) (stripExprLocation e2)
    stripExprLocation' (If e1 e2 e3) = If (stripExprLocation e1) (stripExprLocation e2) (stripExprLocation e3)
    stripExprLocation' (BinaryOperator op e1 e2) = BinaryOperator (stripBinaryOperatorLocation op) (stripExprLocation e1) (stripExprLocation e2)
    stripExprLocation' (List l) = List (stripExprLocation <$> l)
    stripExprLocation' (Match e m) = Match (stripExprLocation e) (bimapF stripPatternLocation stripExprLocation m)
    stripExprLocation' (LetIn v p e1 e2) =
        let p' = stripLocation p
            p'' =
                applyAsFunctorish @(Select "LetPattern" ast1) @(Select "LetPattern" ast2) @(Pattern ast1) @(Pattern ast2)
                    stripPatternLocation
                    p'
         in LetIn
                (stripLocation v)
                p''
                (stripExprLocation e1)
                (stripExprLocation e2)
    stripExprLocation' (Let v p e) =
        let p' = stripLocation p
            p'' =
                applyAsFunctorish @(Select "LetPattern" ast1) @(Select "LetPattern" ast2) @(Pattern ast1) @(Pattern ast2)
                    stripPatternLocation
                    p'
         in Let (stripLocation v) p'' (stripExprLocation e)
    stripExprLocation' (Block b) = Block (stripExprLocation <$> b)
    stripExprLocation' (InParens e) = InParens (stripExprLocation e)
    stripExprLocation' (Tuple t) = Tuple (stripExprLocation <$> t)

stripPatternLocation ::
    forall (ast1 :: LocatedAST) (ast2 :: UnlocatedAST).
    ( (ASTLocate' ast1 ~ Located)
    , ASTLocate' ast2 ~ Unlocated
    , _
    ) =>
    Pattern ast1 ->
    Pattern ast2
stripPatternLocation (Pattern (p :: ASTLocate ast1 (Pattern' ast1), t)) =
    let p' = fmapUnlocated @LocatedAST @ast1 stripPatternLocation' p
     in Pattern (stripLocation p', fmap stripTypeLocation t)
  where
    stripPatternLocation' :: Pattern' ast1 -> Pattern' ast2
    stripPatternLocation' (VarPattern v) = VarPattern (stripLocation v)
    stripPatternLocation' (ConstructorPattern c ps) = ConstructorPattern (stripLocation c) (stripPatternLocation <$> ps)
    stripPatternLocation' (ListPattern l) = ListPattern (stripPatternLocation <$> l)
    stripPatternLocation' (ConsPattern p1 p2) = ConsPattern (stripPatternLocation p1) (stripPatternLocation p2)
    stripPatternLocation' WildcardPattern = WildcardPattern
    stripPatternLocation' (IntegerPattern i) = IntegerPattern i
    stripPatternLocation' (FloatPattern f) = FloatPattern f
    stripPatternLocation' (StringPattern s) = StringPattern s
    stripPatternLocation' (CharPattern c) = CharPattern c
    stripPatternLocation' UnitPattern = UnitPattern

stripBinaryOperatorLocation ::
    forall (ast1 :: LocatedAST) (ast2 :: UnlocatedAST).
    ( (ASTLocate' ast1 ~ Located)
    , ASTLocate' ast2 ~ Unlocated
    , _
    ) =>
    BinaryOperator ast1 ->
    BinaryOperator ast2
stripBinaryOperatorLocation (MkBinaryOperator (op :: ASTLocate ast1 (BinaryOperator' ast1))) =
    let op' = fmapUnlocated @LocatedAST @ast1 stripBinaryOperatorLocation' op
     in MkBinaryOperator (stripLocation op')
  where
    stripBinaryOperatorLocation' :: BinaryOperator' ast1 -> BinaryOperator' ast2
    stripBinaryOperatorLocation' (SymOp name) = SymOp (stripLocation name)
    stripBinaryOperatorLocation' (Infixed name) = Infixed (stripLocation name)

stripTypeLocation ::
    forall (ast1 :: LocatedAST) (ast2 :: UnlocatedAST).
    ( (ASTLocate' ast1 ~ Located)
    , ASTLocate' ast2 ~ Unlocated
    , _
    ) =>
    Type ast1 ->
    Type ast2
stripTypeLocation (Type (t :: ASTLocate ast1 (Type' ast1))) =
    let t' = fmapUnlocated @LocatedAST @ast1 stripTypeLocation' t
     in Type (stripLocation t')
  where
    stripTypeLocation' :: Type' ast1 -> Type' ast2
    stripTypeLocation' (TypeVar name) = TypeVar (rUnlocate @LocatedAST @ast1 name)
    stripTypeLocation' (FunctionType a b) = FunctionType (stripTypeLocation a) (stripTypeLocation b)
    stripTypeLocation' UnitType = UnitType
    stripTypeLocation' (TypeConstructorApplication a b) = TypeConstructorApplication (stripTypeLocation a) (stripTypeLocation b)

-- stripTypeLocation' (UserDefinedType name) = UserDefinedType (_ name)

{-  =====================
    Messy deriving stuff
    ====================
-}

-- Eq instances

deriving instance
    ( (Eq (Select "LetPattern" ast))
    , (Eq (ASTLocate ast (Select "VarRef" ast)))
    , (Eq (ASTLocate ast (Select "LambdaPattern" ast)))
    , (Eq (ASTLocate ast (Select "ConRef" ast)))
    , (Eq (ASTLocate ast (Select "LetParamName" ast)))
    , (Eq (ASTLocate ast (BinaryOperator' ast)))
    , (Eq (Select "InParens" ast))
    , (Eq (Select "ExprType" ast))
    , (Eq (Select "PatternType" ast))
    , Eq (ASTLocate ast (Expr' ast))
    , Eq (ASTLocate ast (Pattern' ast))
    ) =>
    Eq (Expr' ast)

deriving instance (Eq (ASTLocate ast (Expr' ast)), Eq (Select "ExprType" ast)) => Eq (Expr ast)

deriving instance
    ( Eq (ASTLocate ast (Select "VarPat" ast))
    , Eq (ASTLocate ast (Select "ConPat" ast))
    , (Eq (Select "PatternType" ast))
    , Eq (ASTLocate ast (Pattern' ast))
    ) =>
    Eq (Pattern' ast)

deriving instance (Eq (ASTLocate ast (Pattern' ast)), Eq (Select "PatternType" ast)) => Eq (Pattern ast)

deriving instance
    ( Eq (ASTLocate ast (Select "TypeVar" ast))
    , Eq (ASTLocate ast (Select "UserDefinedType" ast))
    , Eq (ASTLocate ast (Type' ast))
    , Eq (ASTLocate ast VarName)
    , Eq (Type ast)
    ) =>
    Eq (Type' ast)

deriving instance (Eq (ASTLocate ast (Type' ast))) => Eq (Type ast)

deriving instance
    ( Eq (ASTLocate ast (Select "SymOp" ast))
    , Eq (ASTLocate ast (Select "Infixed" ast))
    ) =>
    Eq (BinaryOperator' ast)

deriving instance Eq (ASTLocate ast (BinaryOperator' ast)) => Eq (BinaryOperator ast)

-- Show instances

deriving instance
    ( (Show (Select "LetPattern" ast))
    , (Show (ASTLocate ast (Select "VarRef" ast)))
    , (Show (ASTLocate ast (Select "LambdaPattern" ast)))
    , (Show (ASTLocate ast (Select "ConRef" ast)))
    , (Show (ASTLocate ast (Select "LetParamName" ast)))
    , (Show (ASTLocate ast (BinaryOperator' ast)))
    , (Show (Select "InParens" ast))
    , (Show (Select "ExprType" ast))
    , (Show (Select "PatternType" ast))
    , Show (ASTLocate ast (Expr' ast))
    , Show (ASTLocate ast (Pattern' ast))
    ) =>
    Show (Expr' ast)

deriving instance (Show (ASTLocate ast (Expr' ast)), Show (Select "ExprType" ast)) => Show (Expr ast)

deriving instance
    ( Show (ASTLocate ast (Select "VarPat" ast))
    , Show (ASTLocate ast (Select "ConPat" ast))
    , (Show (Select "PatternType" ast))
    , Show (ASTLocate ast (Pattern' ast))
    ) =>
    Show (Pattern' ast)

deriving instance (Show (ASTLocate ast (Pattern' ast)), Show (Select "PatternType" ast)) => Show (Pattern ast)

deriving instance
    ( Show (ASTLocate ast (Select "TypeVar" ast))
    , Show (ASTLocate ast (Select "UserDefinedType" ast))
    , Show (ASTLocate ast (Type' ast))
    , Show (ASTLocate ast VarName)
    , Show (Type ast)
    ) =>
    Show (Type' ast)

deriving instance (Show (ASTLocate ast (Type' ast))) => Show (Type ast)

deriving instance
    ( Show (ASTLocate ast (Select "SymOp" ast))
    , Show (ASTLocate ast (Select "Infixed" ast))
    ) =>
    Show (BinaryOperator' ast)

deriving instance Show (ASTLocate ast (BinaryOperator' ast)) => Show (BinaryOperator ast)

deriving instance
    ( Show (DeclarationBody ast)
    , Show (ASTLocate ast (Select "DeclarationName" ast))
    , Show (ASTLocate ast ModuleName)
    ) =>
    Show (Declaration' ast)

deriving instance Show (ASTLocate ast (Declaration' ast)) => Show (Declaration ast)

deriving instance
    ( (Show (Select "ValueTypeDef" ast))
    , (Show (Select "ValuePatterns" ast))
    , (Show (Select "ValueType" ast))
    , Show (Select "ExprType" ast)
    , Show (ASTLocate ast (Select "TypeVar" ast))
    , Show (ASTLocate ast (Expr' ast))
    , Show (ASTLocate ast (TypeDeclaration ast))
    ) =>
    Show (DeclarationBody' ast)

deriving instance Show (ASTLocate ast (DeclarationBody' ast)) => Show (DeclarationBody ast)

deriving instance
    ( Show (ASTLocate ast (Select "ConstructorName" ast))
    , Show (Type ast)
    ) =>
    Show (TypeDeclaration ast)

-- Ord instances

deriving newtype instance Ord (ASTLocate ast (BinaryOperator' ast)) => Ord (BinaryOperator ast)

deriving instance
    ( Ord (ASTLocate ast (Select "SymOp" ast))
    , Ord (ASTLocate ast (Select "Infixed" ast))
    ) =>
    Ord (BinaryOperator' ast)
