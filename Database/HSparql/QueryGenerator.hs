{-# LANGUAGE ExtendedDefaultRules, FlexibleInstances, Rank2Types #-}

-- |The query generator DSL for SPARQL, used when connecting to remote
--  endpoints.
module Database.HSparql.QueryGenerator
    ( -- * Creating Queries
      createQuery

    -- * Query Actions
    , prefix
    , var
    , triple
    , optional
    , union
    , filterExpr

    -- ** Duplicate handling
    , distinct
    , reduced

    -- ** Order handling
    , orderNext
    , orderNextAsc
    , orderNextDesc

    -- ** Auxiliary
    , (.:.)
    , iriRef

    -- * Term Manipulation

    -- ** Operations
    , (.+.), (.-.), (.*.), (./.)

    -- ** Relations
    , (.==.), (.!=.), (.<.), (.>.), (.<=.), (.>=.)

    -- ** Negation
    , notExpr

    -- ** Builtin Functions
    , str
    , lang
    , langMatches
    , datatype
    , bound
    , sameTerm
    , isIRI
    , isURI
    , isBlank
    , isLiteral
    , regex

    -- * Printing Queries
    , qshow

    -- * Types
    , Query
    , Variable
    )
where

import Control.Monad.State
import Data.List (intercalate)

-- State monads

-- |The 'State' monad applied to 'QueryData'.
type Query a = State QueryData a

-- |Execute a 'Query' action, starting with the empty 'queryData', then process
-- the resulting 'QueryData'.
execQuery :: Query a -> (QueryData -> b) -> b
execQuery q f = f $ execState q queryData

-- |Execute a 'Query' action, returning the 'String' representation of the query.
createQuery :: Query [Variable] -> String
createQuery q = execQuery specifyVars qshow
    where specifyVars :: Query ()
          specifyVars = do vs <- q
                           modify $ \s -> s { vars = vs }

-- Manipulate data within monad

-- |Add a prefix to the query, given an IRI reference, and return it.
prefix :: IRIRef -> Query Prefix
prefix ref = do n <- gets prefixIdx
                let p = Prefix n ref
                modify $ \s -> s { prefixIdx = n + 1, prefixes = p : prefixes s }
                return p

-- |Create and return a variable to the query, usable in later expressions.
var :: Query Variable
var = do n <- gets varsIdx
         modify $ \s -> s { varsIdx = n + 1 }
         return $ Variable n

-- |Restrict the query to only results for which values match constants in this
--  triple, or for which the variables can be bound.
triple :: (TermLike a, TermLike b, TermLike c) => a -> b -> c -> Query Pattern
triple a b c = do
    let t = Triple (varOrTerm a) (varOrTerm b) (varOrTerm c)
    modify $ \s -> s { pattern = appendPattern t (pattern s) }
    return t

-- |Add optional constraints on matches. Variable bindings within the optional
--  action are lost, so variables must always be defined prior to opening the
--  optional block.
optional :: Query a -> Query Pattern
optional q = do
    -- Determine the patterns by executing the action on a blank QueryData, and
    -- then pulling the patterns out from there.
    let option  = execQuery q $ OptionalGraphPattern . pattern
    modify $ \s -> s { pattern = appendPattern option (pattern s) }
    return option

-- |Add a union structure to the query pattern. As with 'optional' blocks,
--  variables must be defined prior to the opening of any block.
union :: Query a -> Query b -> Query Pattern
union q1 q2 = do 
    let p1    = execQuery q1 pattern
        p2    = execQuery q2 pattern
        union = UnionGraphPattern p1 p2
    modify $ \s -> s { pattern = appendPattern union (pattern s) }
    return union

-- |Restrict results to only those for which the given expression is true.
filterExpr :: (TermLike a) => a -> Query Pattern
filterExpr e = do
    let f = Filter (expr e)
    modify $ \s -> s { pattern = appendPattern f (pattern s) }
    return f

-- Random auxiliary

-- |Form a 'PrefixedName' 'IRIRef', with the 'Prefix' and reference name.
(.:.) :: Prefix -> String -> IRIRef
(.:.) = PrefixedName

-- |Create an 'IRIRef' with an absolute reference to the address at which it is
--  located.
iriRef :: String -> IRIRef
iriRef = IRIRef

-- Duplicate handling

-- |Set duplicate handling to 'Distinct'. By default, there are no reductions.
distinct :: Query Duplicates
distinct = do modify $ \s -> s { duplicates = Distinct }
              gets duplicates

-- |Set duplicate handling to 'Reduced'. By default, there are no reductions.
reduced :: Query Duplicates
reduced = do modify $ \s -> s { duplicates = Reduced }
             gets duplicates

-- Order handling

-- |Alias of 'orderNextAsc'.
orderNext :: (TermLike a) => a -> Query ()
orderNext = orderNextAsc 

-- |Order the results, after any previous ordering, based on the term, in
--  ascending order.
orderNextAsc :: (TermLike a) => a -> Query ()
orderNextAsc x  = do modify $ \s -> s { ordering = (ordering s) ++ [Asc  $ expr x] }

-- |Order the results, after any previous ordering, based on the term, in
--  descending order.
orderNextDesc :: (TermLike a) => a -> Query ()
orderNextDesc x = do modify $ \s -> s { ordering = (ordering s) ++ [Desc $ expr x] }

-- Permit variables and values to seemlessly be put into argument for 'triple'
-- and similar functions
class TermLike a where
  varOrTerm :: a -> VarOrTerm

  expr :: a -> Expr
  expr = VarOrTermExpr . varOrTerm

instance TermLike Variable where
  varOrTerm = Var

instance TermLike IRIRef where
  varOrTerm = Term . IRIRefTerm

instance TermLike Expr where
  varOrTerm = error "cannot use an expression as a term"
  expr = id

instance TermLike Integer where
  varOrTerm = Term . NumericLiteralTerm
  expr = NumericExpr . NumericLiteralExpr

instance TermLike [Char] where
  varOrTerm = Term . RDFLiteralTerm . RDFLiteral

instance TermLike ([Char], [Char]) where
  varOrTerm (s, lang) = Term . RDFLiteralTerm $ RDFLiteralLang s lang

instance TermLike ([Char], IRIRef) where
  varOrTerm (s, ref) = Term . RDFLiteralTerm $ RDFLiteralIRIRef s ref

instance TermLike Bool where
  varOrTerm = Term . BooleanLiteralTerm

-- Operations
operation :: (TermLike a, TermLike b) => Operation -> a -> b -> Expr
operation op x y = NumericExpr $ OperationExpr op (expr x) (expr y)

-- |Add two terms.
(.+.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.+.) = operation Add

-- |Find the difference between two terms.
(.-.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.-.) = operation Subtract

-- |Multiply two terms.
(.*.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.*.) = operation Multiply

-- |Divide two terms.
(./.) :: (TermLike a, TermLike b) => a -> b -> Expr
(./.) = operation Divide

-- Relations
relation :: (TermLike a, TermLike b) => Relation -> a -> b -> Expr
relation rel x y = RelationalExpr rel (expr x) (expr y)

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their equivalence.
(.==.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.==.) = relation Equal

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their equivalence.
(.!=.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.!=.) = relation NotEqual

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their relative value.
(.<.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.<.) = relation LessThan

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their relative value.
(.>.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.>.) = relation GreaterThan

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their relative value.
(.<=.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.<=.) = relation LessThanOrEqual

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their relative value.
(.>=.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.>=.) = relation GreaterThanOrEqual

-- Negation

-- |Negate any term-like expression, for use, e.g., in filtering.
notExpr :: (TermLike a) => a -> Expr
notExpr = NegatedExpr . expr

-- Builtin Functions
type BuiltinFunc1 = (TermLike a) => a -> Expr
builtinFunc1 :: Function -> BuiltinFunc1
builtinFunc1 f x = BuiltinCall f [expr x]

type BuiltinFunc2 = (TermLike a, TermLike b) => a -> b -> Expr
builtinFunc2 :: Function -> BuiltinFunc2
builtinFunc2 f x y = BuiltinCall f [expr x, expr y]

str :: BuiltinFunc1
str = builtinFunc1 StrFunc

lang :: BuiltinFunc1
lang = builtinFunc1 LangFunc

langMatches :: BuiltinFunc2
langMatches = builtinFunc2 LangMatchesFunc

datatype :: BuiltinFunc1
datatype = builtinFunc1 DataTypeFunc

bound :: Variable -> Expr
bound x = BuiltinCall BoundFunc [expr x]

sameTerm :: BuiltinFunc2
sameTerm = builtinFunc2 SameTermFunc

isIRI :: BuiltinFunc1
isIRI = builtinFunc1 IsIRIFunc

isURI :: BuiltinFunc1
isURI = builtinFunc1 IsURIFunc

isBlank :: BuiltinFunc1
isBlank = builtinFunc1 IsBlankFunc

isLiteral :: BuiltinFunc1
isLiteral = builtinFunc1 IsLiteralFunc

regex :: BuiltinFunc2
regex = builtinFunc2 RegexFunc

-- Default QueryData
queryData :: QueryData
queryData = QueryData
    { prefixIdx  = 0
    , prefixes   = []
    , varsIdx    = 0
    , vars       = []
    , pattern    = GroupGraphPattern []
    , duplicates = NoLimits
    , ordering   = []
    }

-- Query representation
class QueryShow a where
  -- |Convert most query-related types to a 'String', most importantly
  --  'QueryData's.
  qshow :: a -> String

data Duplicates = NoLimits | Distinct | Reduced

data Prefix = Prefix Int IRIRef

data Variable = Variable Int

data IRIRef = IRIRef String
            | PrefixedName Prefix String 

data RDFLiteral = RDFLiteral String
                | RDFLiteralLang String String
                | RDFLiteralIRIRef String IRIRef

-- Should support numeric literals, too
data GraphTerm = IRIRefTerm IRIRef
               | RDFLiteralTerm RDFLiteral
               | NumericLiteralTerm Integer
               | BooleanLiteralTerm Bool

data VarOrTerm = Var Variable
               | Term GraphTerm

data Operation = Add | Subtract | Multiply | Divide

data NumericExpr = NumericLiteralExpr Integer
                 | OperationExpr Operation Expr Expr

data Relation = Equal | NotEqual | LessThan | GreaterThan | LessThanOrEqual | GreaterThanOrEqual

data Function = StrFunc | LangFunc | LangMatchesFunc | DataTypeFunc | BoundFunc
              | SameTermFunc | IsIRIFunc | IsURIFunc | IsBlankFunc
              | IsLiteralFunc | RegexFunc

data Expr = OrExpr [Expr]
          | AndExpr [Expr]
          | NegatedExpr Expr
          | RelationalExpr Relation Expr Expr
          | NumericExpr NumericExpr
          | BuiltinCall Function [Expr]
          | VarOrTermExpr VarOrTerm

data Pattern = Triple VarOrTerm VarOrTerm VarOrTerm
             | Filter Expr
             | OptionalGraphPattern GroupGraphPattern
             | UnionGraphPattern GroupGraphPattern GroupGraphPattern
data GroupGraphPattern = GroupGraphPattern [Pattern]

data OrderBy = Asc Expr
             | Desc Expr

-- Auxiliary, but fairly useful
appendPattern :: Pattern -> GroupGraphPattern -> GroupGraphPattern
appendPattern p (GroupGraphPattern ps) = GroupGraphPattern (ps ++ [p])

data QueryData = QueryData
    { prefixIdx  :: Int
    , prefixes   :: [Prefix]
    , varsIdx    :: Int
    , vars       :: [Variable]
    , pattern    :: GroupGraphPattern
    , duplicates :: Duplicates
    , ordering   :: [OrderBy]
    }

-- QueryShow instances
instance (QueryShow a) => QueryShow [a] where
  qshow xs = intercalate " " $ map qshow xs

instance QueryShow Duplicates where
  qshow NoLimits = ""
  qshow Distinct = "DISTINCT"
  qshow Reduced  = "REDUCED"

instance QueryShow Prefix where
  qshow (Prefix n ref) = "PREFIX p" ++ show n ++ ": " ++ qshow ref

instance QueryShow Variable where
  qshow (Variable v) = "?x" ++ show v

instance QueryShow IRIRef where
  qshow (IRIRef r) = "<" ++ r ++ ">"
  qshow (PrefixedName (Prefix n ref) s) = "p" ++ show n ++ ":" ++ s

instance QueryShow RDFLiteral where
  -- Always use triple-quoted strings to avoid having to deal with quote-escaping
  qshow (RDFLiteral s)           = "\"\"\"" ++ s ++ "\"\"\""
  qshow (RDFLiteralLang s lang)  = "\"\"\"" ++ s ++ "\"\"\"@" ++ lang
  qshow (RDFLiteralIRIRef s ref) = "\"\"\"" ++ s ++ "\"\"\"^^" ++ qshow ref

instance QueryShow GraphTerm where
  qshow (IRIRefTerm ref)           = qshow ref
  qshow (RDFLiteralTerm s)         = qshow s
  qshow (BooleanLiteralTerm True)  = show "true"
  qshow (BooleanLiteralTerm False) = show "false"

instance QueryShow VarOrTerm where
  qshow (Var  v) = qshow v
  qshow (Term t) = qshow t

instance QueryShow Operation where
  qshow Add      = "+"
  qshow Subtract = "-"
  qshow Multiply = "*"
  qshow Divide   = "/"

instance QueryShow NumericExpr where
  qshow (NumericLiteralExpr n) = show n
  qshow (OperationExpr op x y) = qshow x ++ qshow op ++ qshow y

instance QueryShow Relation where
  qshow Equal              = "="
  qshow NotEqual           = "!="
  qshow LessThan           = "<"
  qshow GreaterThan        = ">"
  qshow LessThanOrEqual    = "<="
  qshow GreaterThanOrEqual = ">="

instance QueryShow Function where
  qshow StrFunc         = "STR"
  qshow LangFunc        = "LANG"
  qshow LangMatchesFunc = "LANGMATCHES"
  qshow DataTypeFunc    = "DATATYPE"
  qshow BoundFunc       = "BOUND"
  qshow SameTermFunc    = "sameTerm"
  qshow IsIRIFunc       = "isIRI"
  qshow IsURIFunc       = "isURI"
  qshow IsBlankFunc     = "isBlank"
  qshow IsLiteralFunc   = "isLiteral"
  qshow RegexFunc       = "REGEX"

instance QueryShow Expr where
  qshow (VarOrTermExpr vt) = qshow vt
  qshow e = "(" ++ qshow' e ++ ")"
    where qshow' (OrExpr es)        = intercalate " || " $ map qshow es
          qshow' (AndExpr es)       = intercalate " && " $ map qshow es
          qshow' (NegatedExpr e)    = '!' : qshow e
          qshow' (RelationalExpr rel e1 e2) = qshow e1 ++ qshow rel ++ qshow e2
          qshow' (NumericExpr e)    = qshow e
          qshow' (BuiltinCall f es) = qshow f ++ "(" ++ (intercalate ", " $ map qshow es) ++ ")"

instance QueryShow Pattern where
  qshow (Triple a b c) = qshow [a, b, c] ++ "."
  qshow (Filter e)     = "FILTER " ++ qshow e ++ "."

  qshow (OptionalGraphPattern p)  = "OPTIONAL " ++ qshow p
  qshow (UnionGraphPattern p1 p2) = qshow p1 ++ " UNION " ++ qshow p2

instance QueryShow GroupGraphPattern where
  qshow (GroupGraphPattern ps) = "{" ++ qshow ps ++ "}"

instance QueryShow OrderBy where
  qshow (Asc e)  = "ASC(" ++ qshow e ++ ")"
  qshow (Desc e) = "DESC(" ++ qshow e ++ ")"

instance QueryShow QueryData where
  qshow qd = intercalate " " $ [ qshow (prefixes qd)
                               , "SELECT"
                               , qshow (duplicates qd)
                               , qshow (vars qd)
                               , "WHERE"
                               , qshow (pattern qd)
                               ] ++ case ordering qd of
                                      [] -> []
                                      os -> ["ORDER BY"] ++ map qshow os

