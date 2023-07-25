{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ViewPatterns #-}

-- | Emits JVM bytecode from Elara AST.
module Elara.Emit where

import Control.Lens hiding (List)
import Data.List.NonEmpty qualified as NE
import Elara.AST.Lenses (HasDeclarationBody' (unlocatedDeclarationBody'))

import Elara.AST.Name (ModuleName (..), Name, NameLike (nameText), Qualified (Qualified))
import Elara.AST.Region (Located (Located))
import Elara.AST.Select (HasDeclarationName (unlocatedDeclarationName), HasModuleName (unlocatedModuleName), Typed)
import Elara.AST.Typed as AST (Declaration, DeclarationBody' (..), Expr (..), Expr' (FunctionCall, Int, Lambda, String, Var), _Expr)
import Elara.AST.VarRef (VarRef' (Global))
import Elara.Data.TopologicalGraph (TopologicalGraph, traverseGraphRevTopologically_)
import Elara.Emit.Operator (translateOperatorName)
import Elara.Prim (fetchPrimitive)
import Elara.TypeInfer.Monotype as Monotype (Scalar (..))
import Elara.TypeInfer.Type (Type (..))
import JVM.Data.Abstract.AccessFlags (FieldAccessFlag (FPublic, FStatic), MethodAccessFlag (MPublic, MStatic))
import JVM.Data.Abstract.Builder
import JVM.Data.Abstract.ClassFile
import JVM.Data.Abstract.Descriptor
import JVM.Data.Abstract.Field (ClassFileField (ClassFileField))
import JVM.Data.Abstract.Instruction (Instruction (..), LDCEntry (LDCInt, LDCString))
import JVM.Data.Abstract.Method (ClassFileMethod (ClassFileMethod), CodeAttributeData (..), MethodAttribute (..))
import JVM.Data.Abstract.Name (ClassName (ClassName), PackageName (PackageName), QualifiedClassName (QualifiedClassName))
import JVM.Data.Abstract.Type as JVM (ClassInfoType (ClassInfoType), FieldType (ArrayFieldType, ObjectFieldType, PrimitiveFieldType), PrimitiveType (..))
import JVM.Data.Convert.Descriptor (convertMethodDescriptor)
import JVM.Data.JVMVersion
import Polysemy
import Polysemy.Reader
import Polysemy.Writer
import Print (debugColored, debugPretty, showPretty)
import Elara.Core.Module (CoreModule (CoreModule), declarations, CoreDeclaration(..))
import TODO

type Emit r = Members '[Reader JVMVersion] r

emitGraph :: forall r. Emit r => TopologicalGraph (CoreModule) -> Sem r [(ModuleName, ClassFile)]
emitGraph g = do
    let tellMod = emitModule >=> tell . one :: CoreModule -> Sem (Writer [(ModuleName, ClassFile)] : r) () -- this breaks without the type signature lol
    fst <$> runWriter (traverseGraphRevTopologically_ tellMod g)

emitModule :: Emit r => CoreModule -> Sem r (ModuleName, ClassFile)
emitModule m = do
    let name = createModuleName (m ^. unlocatedModuleName)
    version <- ask

    (_, clazz) <- runClassBuilderT name version $ do
        traverse_ addDeclaration (m ^. declarations)
        when (isMainModule m) (addMethod (generateMainMethod m))

    pure
        ( m ^. unlocatedModuleName
        , clazz
        )

generateCodeAttribute :: Expr -> ([Instruction] -> [Instruction]) -> MethodAttribute
generateCodeAttribute e codeMod =
    Code $
        CodeAttributeData
            { maxStack = 2 -- TODO: calculate this
            , maxLocals = 2 -- TODO: calculate this too
            , code = codeMod (generateCode e)
            , exceptionTable = []
            , codeAttributes = []
            }

addDeclaration :: (Emit r) => CoreDeclaration -> ClassBuilderT (Sem r) ()
addDeclaration declBody = case declBody of
    CoreValue v -> do
        todo
        -- let (_, type') = v ^. _Expr
        --     declName = translateOperatorName $ decl ^. unlocatedDeclarationName . to nameText
        -- if typeIsValue type'
        --     then addField (ClassFileField [FPublic, FStatic] declName (generateFieldType type') [])
        --     else do
        --         let descriptor@(MethodDescriptor _ returnType) = generateMethodDescriptor type'
        --         addMethod $
        --             ClassFileMethod
        --                 [MPublic, MStatic]
        --                 (declName)
        --                 descriptor
        --                 [generateCodeAttribute v (if returnType == VoidReturn then (<> [Return]) else (<> [AReturn]))]

isMainModule :: CoreModule -> Bool
isMainModule m = m ^. unlocatedModuleName == ModuleName ("Main" :| [])

-- | Generates a main method, which merely loads a IO action field called main and runs it
generateMainMethod :: CoreModule -> ClassFileMethod
generateMainMethod m =
    ClassFileMethod
        [MPublic, MStatic]
        "main"
        ( MethodDescriptor
            [ArrayFieldType (ObjectFieldType "java.lang.String")]
            VoidReturn
        )
        [ Code $
            CodeAttributeData
                { maxStack = 2 -- TODO: calculate this
                , maxLocals = 2 -- TODO: calculate this too
                , code =
                    [ GetStatic (ClassInfoType (createModuleName (m ^. unlocatedModuleName))) "main" (ObjectFieldType "elara.IO")
                    , InvokeVirtual (ClassInfoType "elara.IO") "run" (MethodDescriptor [] VoidReturn)
                    , Return
                    ]
                , exceptionTable = []
                , codeAttributes = []
                }
        ]

createFieldInitialisers :: [Declaration] -> ClassFileMethod
createFieldInitialisers decls =
    ClassFileMethod
        [MStatic]
        "<clinit>"
        (MethodDescriptor [] VoidReturn)
        [ Code $ CodeAttributeData 255 255 (concatMap generateFieldInitialiser decls ++ [Return]) [] []
        ]
  where
    generateFieldInitialiser :: Declaration -> [Instruction]
    generateFieldInitialiser d =
        case d ^. unlocatedDeclarationBody' of
            Value v
                | typeIsValue (v ^. _Expr . _2) ->
                    let fieldClassName = createModuleName (d ^. unlocatedModuleName)
                        fieldName = d ^. unlocatedDeclarationName . to nameText
                        fieldDescriptor = generateFieldType (v ^. _Expr . _2)
                     in generateCode v <> [PutStatic (ClassInfoType fieldClassName) fieldName fieldDescriptor]
            _ -> []

createModuleName :: ModuleName -> QualifiedClassName
createModuleName (ModuleName name) = QualifiedClassName (PackageName $ init name) (ClassName $ last name)

invokeStaticVars :: Expr -> (ClassInfoType, Text, MethodDescriptor)
invokeStaticVars (Expr (Located _ e, exprType)) =
    case e of
        AST.Var (Located _ (Global (Located _ (Qualified vn mn)))) ->
            if typeIsValue exprType
                then error "dunno about global vars"
                else (ClassInfoType $ createModuleName mn, nameText vn, generateMethodDescriptor exprType)
        other -> error (showPretty other)

generateCode ::Expr -> [Instruction]
generateCode (Expr (Located _ e, exprType)) =
    case e of
        FunctionCall
            (Expr (Located _ (Var (Located _ v)), _))
            (Expr (Located _ (AST.String "println"), _))
                | v == fetchPrimitive ->
                    [ ALoad0
                    , InvokeStatic (ClassInfoType "elara.IO") "println" (MethodDescriptor [ObjectFieldType "java.lang.String"] (TypeReturn (ObjectFieldType "elara.IO")))
                    ]
        AST.Var (Located _ (Global (Located _ (Qualified n mn)))) -> [GetStatic (ClassInfoType $ createModuleName mn) (nameText n) (generateFieldType exprType)]
        AST.String c -> [LDC (LDCString c)]
        AST.Int i -> [LDC (LDCInt (fromIntegral i))]
        FunctionCall f x -> do
            let (a, b, c) = invokeStaticVars f
            let outs = generateCode x
            outs ++ [InvokeStatic a b c]
        Lambda _ x -> generateCode x
        e -> error (showPretty e)

{- | Determines if a type is a value type.
 That is, a type that can be compiled to a field rather than a method.
-}
typeIsValue :: Type a -> Bool
typeIsValue (Scalar _ _) = True
typeIsValue (Record _ _) = True
typeIsValue (Tuple _ _) = True
typeIsValue ((Custom _ "IO" _)) = True
typeIsValue _ = False

generateFieldType :: HasCallStack => Show a => Type a -> FieldType
generateFieldType (Scalar _ Bool) = PrimitiveFieldType Boolean
generateFieldType (Scalar _ Integer) = PrimitiveFieldType JVM.Int
generateFieldType (Scalar _ Natural) = PrimitiveFieldType JVM.Int
generateFieldType (Scalar _ Real) = PrimitiveFieldType Double
generateFieldType (Scalar _ Monotype.String) = ObjectFieldType "java.lang.String"
generateFieldType (Scalar _ Monotype.Char) = PrimitiveFieldType JVM.Char
generateFieldType (Custom _ "IO" _) = ObjectFieldType "elara.IO"
generateFieldType (VariableType _ _) = ObjectFieldType "java.lang.Object"
generateFieldType (Function{}) = ObjectFieldType "elara.Func"
generateFieldType (List _ t) = ObjectFieldType "elara.EList"
generateFieldType o = error $ "generateFieldType: " <> showPretty o

generateMethodDescriptor :: HasCallStack => Show a => Type a -> MethodDescriptor
generateMethodDescriptor (Forall _ _ _ _ t) = generateMethodDescriptor t
generateMethodDescriptor f@(Function{}) = do
    -- (a -> b) -> [a] -> [b] gets compiled to List<B> f(Func<A, B> f, List<A> l)
    let
        splitUpFunction :: Type a -> NonEmpty (Type a)
        splitUpFunction (Function _ i o) = i `NE.cons` splitUpFunction o
        splitUpFunction other = pure other

        allParts = splitUpFunction f

        inputs = init allParts
        output = last allParts

    MethodDescriptor (generateFieldType <$> inputs) (generateReturnDescriptor output)
generateMethodDescriptor o = error $ "generateMethodDescriptor: " <> show o

generateReturnDescriptor :: HasCallStack => Show a => Type a -> ReturnDescriptor
generateReturnDescriptor (Scalar _ Unit) = VoidReturn
generateReturnDescriptor other = TypeReturn (generateFieldType other)