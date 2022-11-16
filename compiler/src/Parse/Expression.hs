{-# LANGUAGE OverloadedStrings #-}
-- Temporary while implementing gren format
{-# OPTIONS_GHC -Wno-error=unused-do-bind #-}
{-# OPTIONS_GHC -Wno-error=unused-local-binds #-}
{-# OPTIONS_GHC -Wno-error=unused-matches #-}

module Parse.Expression
  ( expression,
  )
where

import AST.Source qualified as Src
import AST.SourceComments qualified as SC
import Data.Name qualified as Name
import Parse.Keyword qualified as Keyword
import Parse.Number qualified as Number
import Parse.Pattern qualified as Pattern
import Parse.Primitives hiding (State)
import Parse.Primitives qualified as P
import Parse.Space qualified as Space
import Parse.String qualified as String
import Parse.Symbol qualified as Symbol
import Parse.Type qualified as Type
import Parse.Variable qualified as Var
import Reporting.Annotation qualified as A
import Reporting.Error.Syntax qualified as E

-- TERMS

term :: Parser E.Expr Src.Expr
term =
  do
    start <- getPosition
    oneOf
      E.Start
      [ variable start >>= accessible start,
        string start,
        number start,
        parenthesizedExpr start >>= accessible start,
        array start,
        record start >>= accessible start,
        accessor start,
        character start,
        wildcard
      ]

string :: A.Position -> Parser E.Expr Src.Expr
string start =
  do
    str <- String.string E.Start E.String
    addEnd start (Src.Str str)

character :: A.Position -> Parser E.Expr Src.Expr
character start =
  do
    chr <- String.character E.Start E.Char
    addEnd start (Src.Chr chr)

number :: A.Position -> Parser E.Expr Src.Expr
number start =
  do
    nmbr <- Number.number E.Start E.Number
    addEnd start $
      case nmbr of
        Number.Int int -> Src.Int int
        Number.Float float -> Src.Float float

parenthesizedExpr :: A.Position -> Parser E.Expr Src.Expr
parenthesizedExpr start@(A.Position row col) =
  inContext E.Parenthesized (word1 0x28 {-(-} E.Start) $
    do
      comments1 <- Space.chompAndCheckIndent E.ParenthesizedSpace E.ParenthesizedIndentOpen
      oneOf
        E.ParenthesizedOpen
        [ do
            op <- Symbol.operator E.ParenthesizedOpen E.ParenthesizedOperatorReserved
            if op == "-"
              then
                oneOf
                  E.ParenthesizedOperatorClose
                  [ do
                      word1 0x29 {-)-} E.ParenthesizedOperatorClose
                      addEnd start (Src.Op op),
                    do
                      ((expr, commentsAfter), end) <-
                        specialize E.ParenthesizedExpr $
                          do
                            negatedExpr@(A.At (A.Region _ end) _) <- term
                            commentsAfterTerm <- Space.chomp E.Space
                            let exprStart = A.Position row (col + 2)
                            let expr = A.at exprStart end (Src.Negate negatedExpr)
                            chompExprEnd exprStart (State [] expr [] end commentsAfterTerm)
                      Space.checkIndent end E.ParenthesizedIndentEnd
                      word1 0x29 {-)-} E.ParenthesizedOperatorClose
                      addEnd start (Src.Parens comments1 expr commentsAfter)
                  ]
              else do
                word1 0x29 {-)-} E.ParenthesizedOperatorClose
                addEnd start (Src.Op op),
          do
            ((expr, commentsAfter), _) <- specialize E.ParenthesizedExpr expression
            word1 0x29 {-)-} E.ParenthesizedEnd
            addEnd start (Src.Parens comments1 expr commentsAfter)
        ]

accessor :: A.Position -> Parser E.Expr Src.Expr
accessor start =
  do
    word1 0x2E {-.-} E.Dot
    field <- Var.lower E.Access
    addEnd start (Src.Accessor field)

variable :: A.Position -> Parser E.Expr Src.Expr
variable start =
  do
    var <- Var.foreignAlpha E.Start
    addEnd start var

wildcard :: Parser E.Expr a
wildcard =
  do
    word1 0x5F {- _ -} E.Start
    -- Note, because this is not optional, this will not match '_' on its own.
    name <- Var.lower E.Start
    P.Parser $ \(P.State _ _ _ _ row col) _ _ cerr _ ->
      cerr row col (E.WildCard $ E.WildCardAttempt name)

accessible :: A.Position -> Src.Expr -> Parser E.Expr Src.Expr
accessible start expr =
  oneOfWithFallback
    [ do
        word1 0x2E {-.-} E.Dot
        pos <- getPosition
        field <- Var.lower E.Access
        end <- getPosition
        accessible start $
          A.at start end (Src.Access expr (A.at pos end field))
    ]
    expr

-- ARRAYS

array :: A.Position -> Parser E.Expr Src.Expr
array start =
  inContext E.Array (word1 0x5B {-[-} E.Start) $
    do
      Space.chompAndCheckIndent E.ArraySpace E.ArrayIndentOpen
      oneOf
        E.ArrayOpen
        [ do
            ((entry, commentsAfterEntry), end) <- specialize E.ArrayExpr expression
            Space.checkIndent end E.ArrayIndentEnd
            chompArrayEnd start [entry],
          do
            word1 0x5D {-]-} E.ArrayOpen
            addEnd start (Src.Array [])
        ]

chompArrayEnd :: A.Position -> [Src.Expr] -> Parser E.Array Src.Expr
chompArrayEnd start entries =
  oneOf
    E.ArrayEnd
    [ do
        word1 0x2C {-,-} E.ArrayEnd
        Space.chompAndCheckIndent E.ArraySpace E.ArrayIndentExpr
        ((entry, commentsAfterEntry), end) <- specialize E.ArrayExpr expression
        Space.checkIndent end E.ArrayIndentEnd
        chompArrayEnd start (entry : entries),
      do
        word1 0x5D {-]-} E.ArrayEnd
        addEnd start (Src.Array (reverse entries))
    ]

-- RECORDS

record :: A.Position -> Parser E.Expr Src.Expr
record start =
  inContext E.Record (word1 0x7B {- { -} E.Start) $
    do
      Space.chompAndCheckIndent E.RecordSpace E.RecordIndentOpen
      oneOf
        E.RecordOpen
        [ do
            word1 0x7D {-}-} E.RecordEnd
            addEnd start (Src.Record []),
          do
            expr <- specialize E.RecordUpdateExpr term
            Space.chompAndCheckIndent E.RecordSpace E.RecordIndentEquals
            oneOf
              E.RecordEquals
              [ do
                  word1 0x7C {- vertical bar -} E.RecordPipe
                  Space.chompAndCheckIndent E.RecordSpace E.RecordIndentField
                  firstField <- chompField
                  fields <- chompFields [firstField]
                  addEnd start (Src.Update expr fields),
                do
                  word1 0x3D {-=-} E.RecordEquals
                  Space.chompAndCheckIndent E.RecordSpace E.RecordIndentExpr
                  ((value, commentsAfterValue), end) <- specialize E.RecordExpr expression
                  Space.checkIndent end E.RecordIndentEnd
                  case expr of
                    A.At exprRegion (Src.Var Src.LowVar name) -> do
                      fields <- chompFields [(A.At exprRegion name, value)]
                      addEnd start (Src.Record fields)
                    A.At (A.Region (A.Position row col) _) _ ->
                      P.Parser $ \_ _ _ _ eerr ->
                        eerr row col E.RecordField
              ]
        ]

type Field = (A.Located Name.Name, Src.Expr)

chompFields :: [Field] -> Parser E.Record [Field]
chompFields fields =
  oneOf
    E.RecordEnd
    [ do
        word1 0x2C {-,-} E.RecordEnd
        Space.chompAndCheckIndent E.RecordSpace E.RecordIndentField
        f <- chompField
        chompFields (f : fields),
      do
        word1 0x7D {-}-} E.RecordEnd
        return (reverse fields)
    ]

chompField :: Parser E.Record Field
chompField =
  do
    key <- addLocation (Var.lower E.RecordField)
    Space.chompAndCheckIndent E.RecordSpace E.RecordIndentEquals
    word1 0x3D {-=-} E.RecordEquals
    Space.chompAndCheckIndent E.RecordSpace E.RecordIndentExpr
    ((value, commentsAfter), end) <- specialize E.RecordExpr expression
    Space.checkIndent end E.RecordIndentEnd
    return (key, value)

-- EXPRESSIONS

expression :: Space.Parser E.Expr (Src.Expr, [Src.Comment])
expression =
  do
    start <- getPosition
    oneOf
      E.Start
      [ let_ start,
        if_ start,
        case_ start,
        function start,
        do
          expr <- possiblyNegativeTerm start
          end <- getPosition
          commentsAfter <- Space.chomp E.Space
          chompExprEnd start (State [] expr [] end commentsAfter)
      ]

data State = State
  { _ops :: ![(Src.Expr, [Src.Comment], A.Located Name.Name)],
    _expr :: !Src.Expr,
    _args :: ![([Src.Comment], Src.Expr)],
    _end :: !A.Position,
    _commentsAfter :: [Src.Comment]
  }

chompExprEnd :: A.Position -> State -> Space.Parser E.Expr (Src.Expr, [Src.Comment])
chompExprEnd start (State ops expr args end commentsBefore) =
  oneOfWithFallback
    [ -- argument
      do
        Space.checkIndent end E.Start
        arg <- term
        newEnd <- getPosition
        commentsAfter <- Space.chomp E.Space
        chompExprEnd start (State ops expr ((commentsBefore, arg) : args) newEnd commentsAfter),
      -- operator
      do
        Space.checkIndent end E.Start
        op@(A.At (A.Region opStart opEnd) opName) <- addLocation (Symbol.operator E.Start E.OperatorReserved)
        Space.chompAndCheckIndent E.Space (E.IndentOperatorRight opName)
        newStart <- getPosition
        if "-" == opName && end /= opStart && opEnd == newStart
          then -- negative terms
          do
            negatedExpr <- term
            newEnd <- getPosition
            commentsAfter <- Space.chomp E.Space
            let arg = A.at opStart newEnd (Src.Negate negatedExpr)
            chompExprEnd start (State ops expr ((commentsBefore, arg) : args) newEnd commentsAfter)
          else
            let err = E.OperatorRight opName
             in oneOf
                  err
                  [ -- term
                    do
                      newExpr <- possiblyNegativeTerm newStart
                      newEnd <- getPosition
                      commentsAfter <- Space.chomp E.Space
                      let newOps = (toCall expr args, commentsBefore, op) : ops
                      chompExprEnd start (State newOps newExpr [] newEnd commentsAfter),
                    -- final term
                    do
                      ((newLast, commentsAfter), newEnd) <-
                        oneOf
                          err
                          [ let_ newStart,
                            case_ newStart,
                            if_ newStart,
                            function newStart
                          ]
                      let newOps = (toCall expr args, commentsBefore, op) : ops
                      let finalExpr = Src.Binops (reverse newOps) newLast
                      return ((A.at start newEnd finalExpr, commentsAfter), newEnd)
                  ]
    ]
    -- done
    ( case ops of
        [] ->
          ( (toCall expr args, commentsBefore),
            end
          )
        _ ->
          ( ( A.at start end (Src.Binops (reverse ops) (toCall expr args)),
              commentsBefore
            ),
            end
          )
    )

possiblyNegativeTerm :: A.Position -> Parser E.Expr Src.Expr
possiblyNegativeTerm start =
  oneOf
    E.Start
    [ do
        word1 0x2D {---} E.Start
        expr <- term
        addEnd start (Src.Negate expr),
      term
    ]

toCall :: Src.Expr -> [([Src.Comment], Src.Expr)] -> Src.Expr
toCall func revArgs =
  case revArgs of
    [] ->
      func
    (_, lastArg) : _ ->
      A.merge func lastArg (Src.Call func (reverse revArgs))

-- IF EXPRESSION

if_ :: A.Position -> Space.Parser E.Expr (Src.Expr, [Src.Comment])
if_ start =
  inContext E.If (Keyword.if_ E.Start) $
    chompIfEnd start []

chompIfEnd :: A.Position -> [(Src.Expr, Src.Expr)] -> Space.Parser E.If (Src.Expr, [Src.Comment])
chompIfEnd start branches =
  do
    Space.chompAndCheckIndent E.IfSpace E.IfIndentCondition
    ((condition, commentsAfterCondition), condEnd) <- specialize E.IfCondition expression
    Space.checkIndent condEnd E.IfIndentThen
    Keyword.then_ E.IfThen
    Space.chompAndCheckIndent E.IfSpace E.IfIndentThenBranch
    ((thenBranch, commentsAfterThen), thenEnd) <- specialize E.IfThenBranch expression
    Space.checkIndent thenEnd E.IfIndentElse
    Keyword.else_ E.IfElse
    Space.chompAndCheckIndent E.IfSpace E.IfIndentElseBranch
    let newBranches = (condition, thenBranch) : branches
    oneOf
      E.IfElseBranchStart
      [ do
          Keyword.if_ E.IfElseBranchStart
          chompIfEnd start newBranches,
        do
          ((elseBranch, commentsAfterElse), elseEnd) <- specialize E.IfElseBranch expression
          let ifExpr = Src.If (reverse newBranches) elseBranch
          return ((A.at start elseEnd ifExpr, commentsAfterElse), elseEnd)
      ]

-- LAMBDA EXPRESSION

function :: A.Position -> Space.Parser E.Expr (Src.Expr, [Src.Comment])
function start =
  inContext E.Func (word1 0x5C {-\-} E.Start) $
    do
      commentsBeforeFirstArg <- Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArg
      arg <- specialize E.FuncArg Pattern.term
      commentsAfterFirstArg <- Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArrow
      (revArgs, commentsAfterArgs) <- chompArgs [(commentsBeforeFirstArg, arg)] commentsAfterFirstArg
      commentsAfterArrow <- Space.chompAndCheckIndent E.FuncSpace E.FuncIndentBody
      ((body, commentsAfterBody), end) <- specialize E.FuncBody expression
      let comments = SC.LambdaComments commentsAfterArgs commentsAfterArrow
      let funcExpr = Src.Lambda (reverse revArgs) body comments
      return ((A.at start end funcExpr, commentsAfterBody), end)

chompArgs :: [([Src.Comment], Src.Pattern)] -> [Src.Comment] -> Parser E.Func ([([Src.Comment], Src.Pattern)], [Src.Comment])
chompArgs revArgs commentsBefore =
  oneOf
    E.FuncArrow
    [ do
        arg <- specialize E.FuncArg Pattern.term
        commentsAfterArg <- Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArrow
        chompArgs ((commentsBefore, arg) : revArgs) commentsAfterArg,
      do
        word2 0x2D 0x3E {-->-} E.FuncArrow
        return (revArgs, commentsBefore)
    ]

-- CASE EXPRESSIONS

case_ :: A.Position -> Space.Parser E.Expr (Src.Expr, [Src.Comment])
case_ start =
  inContext E.Case (Keyword.case_ E.Start) $
    do
      Space.chompAndCheckIndent E.CaseSpace E.CaseIndentExpr
      ((expr, commentsAfterExpr), exprEnd) <- specialize E.CaseExpr expression
      Space.checkIndent exprEnd E.CaseIndentOf
      Keyword.of_ E.CaseOf
      commentsAfterOf <- Space.chompAndCheckIndent E.CaseSpace E.CaseIndentPattern
      withIndent $
        do
          ((branchPat, branchExpr, commentsAfterFirstBranch), firstEnd) <- chompBranch
          let firstBranch = (commentsAfterOf, branchPat, branchExpr)
          ((branches, commentsAfterLastBranch), end) <- chompCaseEnd [firstBranch] commentsAfterFirstBranch firstEnd
          return
            ( (A.at start end (Src.Case expr branches), commentsAfterLastBranch),
              end
            )

chompBranch :: Space.Parser E.Case (Src.Pattern, Src.Expr, [Src.Comment])
chompBranch =
  do
    (pattern, patternEnd) <- specialize E.CasePattern Pattern.expression
    Space.checkIndent patternEnd E.CaseIndentArrow
    word2 0x2D 0x3E {-->-} E.CaseArrow
    Space.chompAndCheckIndent E.CaseSpace E.CaseIndentBranch
    ((branchExpr, commentsAfterBranch), end) <- specialize E.CaseBranch expression
    return ((pattern, branchExpr, commentsAfterBranch), end)

chompCaseEnd :: [([Src.Comment], Src.Pattern, Src.Expr)] -> [Src.Comment] -> A.Position -> Space.Parser E.Case ([([Src.Comment], Src.Pattern, Src.Expr)], [Src.Comment])
chompCaseEnd branches commentsBetween end =
  oneOfWithFallback
    [ do
        Space.checkAligned E.CasePatternAlignment
        ((pat, expr, commentsAfter), newEnd) <- chompBranch
        let branch = (commentsBetween, pat, expr)
        chompCaseEnd (branch : branches) commentsAfter newEnd
    ]
    ((reverse branches, commentsBetween), end)

-- LET EXPRESSION

let_ :: A.Position -> Space.Parser E.Expr (Src.Expr, [Src.Comment])
let_ start =
  inContext E.Let (Keyword.let_ E.Start) $
    do
      ((defs, commentsBeforeIn), defsEnd) <-
        withBacksetIndent 3 $
          do
            commentsBeforeDef <- Space.chompAndCheckIndent E.LetSpace E.LetIndentDef
            withIndent $
              do
                ((def, commentsAfterDef), end) <- chompLetDef
                chompLetDefs [(commentsBeforeDef, def)] commentsAfterDef end

      Space.checkIndent defsEnd E.LetIndentIn
      Keyword.in_ E.LetIn
      commentsAfterIn <- Space.chompAndCheckIndent E.LetSpace E.LetIndentBody
      ((body, commentsAfter), end) <- specialize E.LetBody expression
      let comments = SC.LetComments commentsBeforeIn commentsAfterIn
      return
        ( (A.at start end (Src.Let defs body comments), commentsAfter),
          end
        )

chompLetDefs :: [([Src.Comment], A.Located Src.Def)] -> [Src.Comment] -> A.Position -> Space.Parser E.Let ([([Src.Comment], A.Located Src.Def)], [Src.Comment])
chompLetDefs revDefs commentsBefore end =
  oneOfWithFallback
    [ do
        Space.checkAligned E.LetDefAlignment
        ((def, commentsAfter), newEnd) <- chompLetDef
        chompLetDefs ((commentsBefore, def) : revDefs) commentsAfter newEnd
    ]
    ((reverse revDefs, commentsBefore), end)

-- LET DEFINITIONS

chompLetDef :: Space.Parser E.Let (A.Located Src.Def, [Src.Comment])
chompLetDef =
  oneOf
    E.LetDefName
    [ definition,
      destructure
    ]

-- DEFINITION

definition :: Space.Parser E.Let (A.Located Src.Def, [Src.Comment])
definition =
  do
    aname@(A.At (A.Region start _) name) <- addLocation (Var.lower E.LetDefName)
    specialize (E.LetDef name) $
      do
        commentsAfterName <- Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
        oneOf
          E.DefEquals
          [ do
              word1 0x3A {-:-} E.DefEquals
              let commentsBeforeColon = commentsAfterName
              Space.chompAndCheckIndent E.DefSpace E.DefIndentType
              ((tipe, commentsAfterTipe), _) <- specialize E.DefType Type.expression
              Space.checkAligned E.DefAlignment
              defName <- chompMatchingName name
              commentsAfterMatchingName <- Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
              chompDefArgsAndBody start defName (Just tipe) [] commentsAfterMatchingName,
            chompDefArgsAndBody start aname Nothing [] commentsAfterName
          ]

chompDefArgsAndBody :: A.Position -> A.Located Name.Name -> Maybe Src.Type -> [([Src.Comment], Src.Pattern)] -> [Src.Comment] -> Space.Parser E.Def (A.Located Src.Def, [Src.Comment])
chompDefArgsAndBody start name tipe revArgs commentsBefore =
  oneOf
    E.DefEquals
    [ do
        arg <- specialize E.DefArg Pattern.term
        commentsAfterArg <- Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
        chompDefArgsAndBody start name tipe ((commentsBefore, arg) : revArgs) commentsAfterArg,
      do
        word1 0x3D {-=-} E.DefEquals
        commentsAfterEquals <- Space.chompAndCheckIndent E.DefSpace E.DefIndentBody
        ((body, commentsAfterBody), end) <- specialize E.DefBody expression
        return
          ( (A.at start end (Src.Define name (reverse revArgs) body tipe), commentsAfterBody),
            end
          )
    ]

chompMatchingName :: Name.Name -> Parser E.Def (A.Located Name.Name)
chompMatchingName expectedName =
  let (P.Parser parserL) = Var.lower E.DefNameRepeat
   in P.Parser $ \state@(P.State _ _ _ _ sr sc) cok eok cerr eerr ->
        let cokL name newState@(P.State _ _ _ _ er ec) =
              if expectedName == name
                then cok (A.At (A.Region (A.Position sr sc) (A.Position er ec)) name) newState
                else cerr sr sc (E.DefNameMatch name)

            eokL name newState@(P.State _ _ _ _ er ec) =
              if expectedName == name
                then eok (A.At (A.Region (A.Position sr sc) (A.Position er ec)) name) newState
                else eerr sr sc (E.DefNameMatch name)
         in parserL state cokL eokL cerr eerr

-- DESTRUCTURE

destructure :: Space.Parser E.Let (A.Located Src.Def, [Src.Comment])
destructure =
  specialize E.LetDestruct $
    do
      start <- getPosition
      pattern <- specialize E.DestructPattern Pattern.term
      Space.chompAndCheckIndent E.DestructSpace E.DestructIndentEquals
      word1 0x3D {-=-} E.DestructEquals
      Space.chompAndCheckIndent E.DestructSpace E.DestructIndentBody
      ((expr, commentsAfter), end) <- specialize E.DestructBody expression
      return ((A.at start end (Src.Destruct pattern expr), commentsAfter), end)
