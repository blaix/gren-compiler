{-# LANGUAGE EmptyDataDecls #-}
{-# OPTIONS_GHC -Wall #-}

module AST.Source
  ( Comment,
    Comment_ (..),
    GREN_COMMENT,
    Expr,
    Expr_ (..),
    VarType (..),
    Def (..),
    Pattern,
    Pattern_ (..),
    RecordFieldPattern,
    RecordFieldPattern_ (..),
    Type,
    Type_ (..),
    SourceOrder,
    Module (..),
    getName,
    getImportName,
    Import (..),
    Value (..),
    Union (..),
    Alias (..),
    Infix (..),
    Port (..),
    Effects (..),
    Manager (..),
    Docs (..),
    DocComment (..),
    Exposing (..),
    Exposed (..),
    Privacy (..),
  )
where

import AST.SourceComments (Comment, Comment_, GREN_COMMENT)
import AST.SourceComments qualified as SC
import AST.Utils.Binop qualified as Binop
import Data.List.NonEmpty (NonEmpty)
import Data.Name (Name)
import Data.Name qualified as Name
import Gren.Float qualified as EF
import Gren.String qualified as ES
import Parse.Primitives qualified as P
import Reporting.Annotation qualified as A

-- EXPRESSIONS

type Expr = A.Located Expr_

data Expr_
  = Chr ES.String
  | Str ES.String
  | Int Int
  | Float EF.Float
  | Var VarType Name
  | VarQual VarType Name Name
  | Array [Expr]
  | Op Name
  | Negate Expr
  | Binops [(Expr, [Comment], A.Located Name)] Expr
  | Lambda [Pattern] Expr
  | Call Expr [([Comment], Expr)]
  | If [(Expr, Expr)] Expr
  | Let [A.Located Def] Expr
  | Case Expr [([Comment], Pattern, Expr)]
  | Accessor Name
  | Access Expr (A.Located Name)
  | Update Expr [(A.Located Name, Expr)]
  | Record [(A.Located Name, Expr)]
  | Parens [Comment] Expr [Comment]
  deriving (Show)

data VarType = LowVar | CapVar
  deriving (Show)

-- DEFINITIONS

data Def
  = Define (A.Located Name) [([Comment], Pattern)] Expr (Maybe Type)
  | Destruct Pattern Expr
  deriving (Show)

-- PATTERN

type Pattern = A.Located Pattern_

data Pattern_
  = PAnything Name
  | PVar Name
  | PRecord [RecordFieldPattern]
  | PAlias Pattern (A.Located Name)
  | PCtor A.Region Name [Pattern]
  | PCtorQual A.Region Name Name [Pattern]
  | PArray [Pattern]
  | PChr ES.String
  | PStr ES.String
  | PInt Int
  deriving (Show)

type RecordFieldPattern = A.Located RecordFieldPattern_

data RecordFieldPattern_ = RFPattern (A.Located Name) Pattern
  deriving (Show)

-- TYPE

type Type =
  A.Located Type_

data Type_
  = TLambda Type Type
  | TVar Name
  | TType A.Region Name [([Comment], Type)]
  | TTypeQual A.Region Name Name [([Comment], Type)]
  | TRecord [(A.Located Name, Type)] (Maybe (A.Located Name))
  deriving (Show)

-- MODULE

type SourceOrder = Int

data Module = Module
  { _name :: Maybe (A.Located Name),
    _exports :: A.Located Exposing,
    _docs :: Docs,
    _imports :: [([Comment], Import)],
    _values :: [(SourceOrder, A.Located Value)],
    _unions :: [(SourceOrder, A.Located Union)],
    _aliases :: [(SourceOrder, A.Located Alias)],
    _binops :: [A.Located Infix],
    _topLevelComments :: [(SourceOrder, NonEmpty Comment)],
    _headerComments :: SC.HeaderComments,
    _effects :: Effects
  }
  deriving (Show)

getName :: Module -> Name
getName (Module maybeName _ _ _ _ _ _ _ _ _ _) =
  case maybeName of
    Just (A.At _ name) ->
      name
    Nothing ->
      Name._Main

getImportName :: Import -> Name
getImportName (Import (A.At _ name) _ _ _ _) =
  name

data Import = Import
  { _import :: A.Located Name,
    _alias :: Maybe (Name, SC.ImportAliasComments),
    _exposing :: Exposing,
    _exposingComments :: Maybe SC.ImportExposingComments,
    _importComments :: SC.ImportComments
  }
  deriving (Show)

data Value = Value (A.Located Name) [([Comment], Pattern)] Expr (Maybe Type) SC.ValueComments
  deriving (Show)

data Union = Union (A.Located Name) [A.Located Name] [(A.Located Name, [([Comment], Type)])]
  deriving (Show)

data Alias = Alias (A.Located Name) [A.Located Name] Type
  deriving (Show)

data Infix = Infix Name Binop.Associativity Binop.Precedence Name
  deriving (Show)

data Port = Port (A.Located Name) Type
  deriving (Show)

data Effects
  = NoEffects
  | Ports [(SourceOrder, Port)] SC.PortsComments
  | Manager A.Region Manager SC.ManagerComments
  deriving (Show)

data Manager
  = Cmd (A.Located Name) SC.CmdComments
  | Sub (A.Located Name) SC.SubComments
  | Fx (A.Located Name) (A.Located Name) SC.FxComments
  deriving (Show)

data Docs
  = NoDocs A.Region
  | YesDocs DocComment [(Name, DocComment)]
  deriving (Show)

newtype DocComment
  = DocComment P.Snippet
  deriving (Show)

-- EXPOSING

data Exposing
  = Open
  | Explicit [Exposed]
  deriving (Show)

data Exposed
  = Lower (A.Located Name)
  | Upper (A.Located Name) Privacy
  | Operator A.Region Name
  deriving (Show)

data Privacy
  = Public A.Region
  | Private
  deriving (Show)
