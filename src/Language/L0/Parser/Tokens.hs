-- | Lexical tokens generated by the lexer and consumed by the parser.
--
-- Probably the most boring module in the compiler.
module Language.L0.Parser.Tokens
  ( Token(..)
  )
  where

import Language.L0.Core

-- | A lexical token.  It does not itself contain position
-- information, so in practice the parser will consume tokens tagged
-- with a source position.
data Token = IF
           | THEN
           | ELSE
           | LET
           | LOOP
           | IN
           | INT
           | BOOL
           | CERT
           | CHAR
           | REAL
           | ID { idName :: Name }
           | STRINGLIT { stringLit :: String }
           | INTLIT { intLit :: Int }
           | REALLIT { realLit :: Double }
           | CHARLIT { charLit :: Char }
           | PLUS
           | MINUS
           | TIMES
           | DIVIDE
           | MOD
           | EQU
           | LTH
           | GTH
           | LEQ
           | POW
           | SHIFTL
           | SHIFTR
           | BOR
           | BAND
           | XOR
           | LPAR
           | RPAR
           | LBRACKET
           | RBRACKET
           | LCURLY
           | RCURLY
           | COMMA
           | UNDERSCORE
           | FUN
           | FN
           | ARROW
           | SETTO
           | FOR
           | DO
           | WITH
           | SIZE
           | IOTA
           | REPLICATE
           | MAP
           | REDUCE
           | RESHAPE
           | REARRANGE
           | ROTATE
           | TRANSPOSE
           | ZIP
           | UNZIP
           | SCAN
           | SPLIT
           | CONCAT
           | FILTER
           | REDOMAP
           | TRUE
           | FALSE
           | CHECKED
           | NOT
           | NEGATE
           | AND
           | OR
           | OP
           | EMPTY
           | COPY
           | ASSERT
           | CONJOIN
           | EOF
             deriving (Show, Eq)
