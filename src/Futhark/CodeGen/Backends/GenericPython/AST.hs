module Futhark.CodeGen.Backends.GenericPython.AST
  ( PyExp(..)
  , PyIdx (..)
  , PyStmt(..)
  , module Language.Futhark.Core
  , PyFunc(..)
  , PyProg(..)
  , PyExcept(..)
  , PyDefinition
  , PyImport
  )
  where

import Language.Futhark.Core
import Text.PrettyPrint.Mainland hiding (space)


data UnOp = Not -- ^ Boolean negation.
          | Complement -- ^ Bitwise complement.
          | Negate -- ^ Numerical negation.
          | Abs -- ^ Absolute/numerical value.
            deriving (Eq, Show)

data PyExp = Constant BasicValue
           | StringLiteral String
           | Var String
           | BinaryOp String PyExp PyExp
           | UnOp String PyExp
           | Cond PyExp PyExp PyExp
           | Index PyExp PyIdx
           | Call String [PyExp]
           | Cast PyExp String
           | Tuple [PyExp]
           | Field PyExp String
           | None
           | ParamAssign PyExp PyExp
             deriving (Eq, Show)

data PyIdx = IdxRange PyExp PyExp
           | IdxExp PyExp
             deriving (Eq, Show)

data PyStmt = If PyExp [PyStmt] [PyStmt]
            | Try [PyStmt] [PyExcept]
            | While PyExp [PyStmt]
            | For String PyExp [PyStmt]
            | Assign PyExp PyExp
            | Comment String [PyStmt]
            | Assert PyExp String
            | Exp PyExp
            | Return PyExp
            | Pass
            deriving (Eq, Show)

data PyExcept = Catch PyExp [PyStmt] deriving (Eq, Show)

data PyFunc = PyFunc String [String] [PyStmt]

type PyDefinition = String

type PyImport = String

data PyProg = PyProg [PyFunc] [PyImport] [PyDefinition]

instance Pretty PyIdx where
  ppr (IdxExp e) = ppr e
  ppr (IdxRange from to) = ppr from <> text ":" <> ppr to

instance Pretty PyExp where
    ppr (Constant chr@(CharVal _)) = text "b" <> ppr chr
    ppr (Constant v) = ppr v
    ppr (StringLiteral s) = text "\"" <> ppr s <> text "\""
    ppr (Var n) = text $ map (\x -> if x == '\'' then 'm' else x) n
    ppr (Field e s) = ppr e <> text "." <> text s
    ppr (BinaryOp s e1 e2) = parens(ppr e1 <+> text s <+> ppr e2)
    ppr (UnOp s e) = text s <> parens (ppr e)
    ppr (Cond e1 e2 e3) = ppr e2 <+> text "if" <+> ppr e1 <+> text "else" <+> ppr e3
    ppr (Cast src bt) = text "cast" <> parens(ppr src <> text "," <+> text "POINTER" <> parens(text bt))
    ppr (Index src idx) = ppr src <> brackets(ppr idx)
    ppr (Call fname exps) = text fname <> parens(commasep $ map ppr exps)
    ppr (Tuple [dim]) = parens(ppr dim <> text ",")
    ppr (Tuple dims) = parens(commasep $ map ppr dims)
    ppr None = text "None"
    ppr (ParamAssign e1 e2) = ppr e1 <+> text "=" <+> ppr e2

instance Pretty PyStmt where
  ppr (If cond tbranch [Pass]) =
    text "if" <+> ppr cond <+> text ":" </>
    indent 2 (stack $ map ppr tbranch)

  ppr (If cond tbranch fbranch) =
    text "if" <+> ppr cond <+> text ":" </>
    indent 2 (stack $ map ppr tbranch) </>
    text "else:" </>
    indent 2 (stack $ map ppr fbranch)

  ppr (Try pystms pyexcepts) =
    text "try:" </>
    indent 2 (stack $ map ppr pystms) </>
    stack (map ppr pyexcepts)

  ppr (While cond body) =
    text "while" <+> ppr cond <+> text ":" </>
    indent 2 (stack $ map ppr body)

  ppr (For i limit body) =
    text  "for" <+> ppr i <+> text "in range" <+> parens (ppr limit) <+> text ":" </>
    indent 2 (stack $ map ppr body)

  ppr (Assign e1 e2) = ppr e1 <+> text "=" <+> ppr e2

  ppr (Comment s body) = text "#" <> text s </> stack (map ppr body)

  ppr (Assert e s) = text "assert" <+> ppr e <> text "," <+> squotes(text s)

  ppr (Exp c) = ppr c

  ppr (Return e) = text "return" <+> ppr e

  ppr Pass = text "pass"

instance Pretty PyExcept where
  ppr (Catch pyexp stms) =
    text "except" <+> ppr pyexp <+> text "as e:" </>
    indent 2 (stack $ map ppr stms)

instance Pretty PyFunc where
  ppr (PyFunc fname params body) =
    text "def" <+> text fname <> parens (commasep $ map ppr params) <> text ":" </>
    indent 2 (stack (map ppr body))

instance Pretty PyProg where
  ppr (PyProg funcs imports defines) =
    stack(map ppr imports) </>
    stack(map ppr defines) </>
    stack(map ppr funcs)
