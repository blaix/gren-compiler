{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

module Data.Name
  ( Name,
    --
    toChars,
    toGrenString,
    toBuilder,
    --
    fromPtr,
    fromChars,
    --
    getKernel,
    hasDot,
    splitDots,
    isKernel,
    isNumberType,
    isComparableType,
    isAppendableType,
    isCompappendType,
    fromVarIndex,
    fromWords,
    fromManyNames,
    fromTypeVariable,
    fromTypeVariableScheme,
    sepBy,
    --
    int,
    float,
    bool,
    char,
    string,
    unit,
    maybe,
    result,
    array,
    dict,
    task,
    router,
    cmd,
    sub,
    portError,
    platform,
    virtualDom,
    debug,
    debugger,
    bitwise,
    basics,
    math,
    utils,
    negate,
    true,
    false,
    value,
    node,
    program,
    _main,
    _Main,
    dollar,
    identity,
    replModule,
    replValueToPrint,
  )
where

import Control.Exception (assert)
import Data.Binary qualified as Binary
import Data.ByteString.Builder.Internal qualified as B
import Data.Coerce qualified as Coerce
import Data.List qualified as List
import Data.String qualified as Chars
import Data.Utf8 qualified as Utf8
import GHC.Exts
  ( Int (I#),
    Ptr,
    isTrue#,
  )
import GHC.Prim
import GHC.ST (ST (ST), runST)
import GHC.Word (Word8 (W8#))
import Gren.String qualified as ES
import Prelude hiding (length, maybe, negate)

-- NAME

type Name =
  Utf8.Utf8 GREN_NAME

data GREN_NAME

-- INSTANCES

instance Chars.IsString (Utf8.Utf8 GREN_NAME) where
  fromString = Utf8.fromChars

instance Binary.Binary (Utf8.Utf8 GREN_NAME) where
  get = Utf8.getUnder256
  put = Utf8.putUnder256

-- TO

toChars :: Name -> [Char]
toChars =
  Utf8.toChars

toGrenString :: Name -> ES.String
toGrenString =
  Coerce.coerce

toBuilder :: Name -> B.Builder
toBuilder =
  Utf8.toBuilder

-- FROM

fromPtr :: Ptr Word8 -> Ptr Word8 -> Name
fromPtr =
  Utf8.fromPtr

fromChars :: [Char] -> Name
fromChars =
  Utf8.fromChars

-- HAS DOT

hasDot :: Name -> Bool
hasDot name =
  Utf8.contains 0x2E {- . -} name

splitDots :: Name -> [Name]
splitDots name =
  Utf8.split 0x2E {- . -} name

-- GET KERNEL

getKernel :: Name -> Name
getKernel name@(Utf8.Utf8 ba#) =
  assert
    (isKernel name)
    ( runST
        ( let !size# = sizeofByteArray# ba# -# 12#
           in ST $ \s ->
                case newByteArray# size# s of
                  (# s, mba# #) ->
                    case copyByteArray# ba# 12# mba# 0# size# s of
                      s ->
                        case unsafeFreezeByteArray# mba# s of
                          (# s, ba# #) -> (# s, Utf8.Utf8 ba# #)
        )
    )

-- STARTS WITH

isKernel :: Name -> Bool
isKernel = Utf8.startsWith prefix_kernel

isNumberType :: Name -> Bool
isNumberType = Utf8.startsWith prefix_number

isComparableType :: Name -> Bool
isComparableType = Utf8.startsWith prefix_comparable

isAppendableType :: Name -> Bool
isAppendableType = Utf8.startsWith prefix_appendable

isCompappendType :: Name -> Bool
isCompappendType = Utf8.startsWith prefix_compappend

prefix_kernel :: Name
prefix_kernel = fromChars "Gren.Kernel."

prefix_number :: Name
prefix_number = fromChars "number"

prefix_comparable :: Name
prefix_comparable = fromChars "comparable"

prefix_appendable :: Name
prefix_appendable = fromChars "appendable"

prefix_compappend :: Name
prefix_compappend = fromChars "compappend"

-- FROM VAR INDEX

fromVarIndex :: Int -> Name
fromVarIndex n =
  runST
    ( do
        let !size = 2 + getIndexSize n
        mba <- newByteArray size
        writeWord8 mba 0 0x5F {- _ -}
        writeWord8 mba 1 0x76 {- v -}
        writeDigitsAtEnd mba size n
        freeze mba
    )

getIndexSize :: Int -> Int
getIndexSize n
  | n < 10 = 1
  | n < 100 = 2
  | True = ceiling (logBase 10 (fromIntegral n + 1) :: Float)

writeDigitsAtEnd :: MBA s -> Int -> Int -> ST s ()
writeDigitsAtEnd !mba !oldOffset !n =
  do
    let (q, r) = quotRem n 10
    let !newOffset = oldOffset - 1
    writeWord8 mba newOffset (0x30 + fromIntegral r)
    if q <= 0
      then return ()
      else writeDigitsAtEnd mba newOffset q

-- FROM TYPE VARIABLE

fromTypeVariable :: Name -> Int -> Name
fromTypeVariable name@(Utf8.Utf8 ba#) index =
  if index <= 0
    then name
    else
      let len# = sizeofByteArray# ba#
          end# = word8ToWord# (indexWord8Array# ba# (len# -# 1#))
       in if isTrue# (leWord# 0x30## end#) && isTrue# (leWord# end# 0x39##)
            then
              runST
                ( do
                    let !size = I# len# + 1 + getIndexSize index
                    mba <- newByteArray size
                    copyToMBA name mba
                    writeWord8 mba (I# len#) 0x5F {- _ -}
                    writeDigitsAtEnd mba size index
                    freeze mba
                )
            else
              runST
                ( do
                    let !size = I# len# + getIndexSize index
                    mba <- newByteArray size
                    copyToMBA name mba
                    writeDigitsAtEnd mba size index
                    freeze mba
                )

-- FROM TYPE VARIABLE SCHEME

fromTypeVariableScheme :: Int -> Name
fromTypeVariableScheme scheme =
  runST
    ( if scheme < 26
        then do
          mba <- newByteArray 1
          writeWord8 mba 0 (0x61 + fromIntegral scheme)
          freeze mba
        else do
          let (extra, letter) = quotRem scheme 26
          let !size = 1 + getIndexSize extra
          mba <- newByteArray size
          writeWord8 mba 0 (0x61 + fromIntegral letter)
          writeDigitsAtEnd mba size extra
          freeze mba
    )

-- FROM MANY NAMES
--
-- Creating a unique name by combining all the subnames can create names
-- longer than 256 bytes relatively easily. So instead, the first given name
-- (e.g. foo) is prefixed chars that are valid in JS but not Gren (e.g. _M$foo)
--
-- This should be a unique name since shadowing is dissallowed. It would not
-- be possible for multiple top-level cycles to include values with the same
-- name, so the important thing is to make the cycle name distinct from the
-- normal name. Same logic for destructuring patterns like (x,y)

fromManyNames :: [Name] -> Name
fromManyNames names =
  case names of
    [] ->
      blank
    -- NOTE: this case is needed for (let _ = Debug.log "x" x in ...)
    -- but maybe unused patterns should be stripped out instead

    Utf8.Utf8 ba# : _ ->
      let len# = sizeofByteArray# ba#
       in runST
            ( ST $ \s ->
                case newByteArray# (len# +# 3#) s of
                  (# s, mba# #) ->
                    case writeWord8Array# mba# 0# (wordToWord8# 0x5F## {-_-}) s of
                      s ->
                        case writeWord8Array# mba# 1# (wordToWord8# 0x4D## {-M-}) s of
                          s ->
                            case writeWord8Array# mba# 2# (wordToWord8# 0x24##) s of
                              s ->
                                case copyByteArray# ba# 0# mba# 3# len# s of
                                  s ->
                                    case unsafeFreezeByteArray# mba# s of
                                      (# s, ba# #) -> (# s, Utf8.Utf8 ba# #)
            )

blank :: Name
blank =
  fromWords [0x5F, 0x4D, 0x24 {-_M$-}]

-- FROM WORDS

fromWords :: [Word8] -> Name
fromWords words =
  runST
    ( do
        mba <- newByteArray (List.length words)
        writeWords mba 0 words
        freeze mba
    )

writeWords :: MBA s -> Int -> [Word8] -> ST s ()
writeWords !mba !i words =
  case words of
    [] ->
      return ()
    w : ws ->
      do
        writeWord8 mba i w
        writeWords mba (i + 1) ws

-- SEP BY

sepBy :: Word8 -> Name -> Name -> Name
sepBy (W8# sep#) (Utf8.Utf8 ba1#) (Utf8.Utf8 ba2#) =
  let !len1# = sizeofByteArray# ba1#
      !len2# = sizeofByteArray# ba2#
   in runST
        ( ST $ \s ->
            case newByteArray# (len1# +# len2# +# 1#) s of
              (# s, mba# #) ->
                case copyByteArray# ba1# 0# mba# 0# len1# s of
                  s ->
                    case writeWord8Array# mba# len1# sep# s of
                      s ->
                        case copyByteArray# ba2# 0# mba# (len1# +# 1#) len2# s of
                          s ->
                            case unsafeFreezeByteArray# mba# s of
                              (# s, ba# #) -> (# s, Utf8.Utf8 ba# #)
        )

-- PRIMITIVES

data MBA s
  = MBA# (MutableByteArray# s)

newByteArray :: Int -> ST s (MBA s)
newByteArray (I# len#) =
  ST $ \s ->
    case newByteArray# len# s of
      (# s, mba# #) -> (# s, MBA# mba# #)

freeze :: MBA s -> ST s Name
freeze (MBA# mba#) =
  ST $ \s ->
    case unsafeFreezeByteArray# mba# s of
      (# s, ba# #) -> (# s, Utf8.Utf8 ba# #)

writeWord8 :: MBA s -> Int -> Word8 -> ST s ()
writeWord8 (MBA# mba#) (I# offset#) (W8# w#) =
  ST $ \s ->
    case writeWord8Array# mba# offset# w# s of
      s -> (# s, () #)

copyToMBA :: Name -> MBA s -> ST s ()
copyToMBA (Utf8.Utf8 ba#) (MBA# mba#) =
  ST $ \s ->
    case copyByteArray# ba# 0# mba# 0# (sizeofByteArray# ba#) s of
      s -> (# s, () #)

-- COMMON NAMES

int :: Name
int = fromChars "Int"

float :: Name
float = fromChars "Float"

bool :: Name
bool = fromChars "Bool"

char :: Name
char = fromChars "Char"

string :: Name
string = fromChars "String"

unit :: Name
unit = fromChars "Unit"

maybe :: Name
maybe = fromChars "Maybe"

result :: Name
result = fromChars "Result"

array :: Name
array = fromChars "Array"

dict :: Name
dict = fromChars "Dict"

task :: Name
task = fromChars "Task"

router :: Name
router = fromChars "Router"

cmd :: Name
cmd = fromChars "Cmd"

sub :: Name
sub = fromChars "Sub"

portError :: Name
portError = fromChars "PortError"

platform :: Name
platform = fromChars "Platform"

virtualDom :: Name
virtualDom = fromChars "VirtualDom"

debug :: Name
debug = fromChars "Debug"

debugger :: Name
debugger = fromChars "Debugger"

bitwise :: Name
bitwise = fromChars "Bitwise"

basics :: Name
basics = fromChars "Basics"

math :: Name
math = fromChars "Math"

utils :: Name
utils = fromChars "Utils"

negate :: Name
negate = fromChars "negate"

true :: Name
true = fromChars "True"

false :: Name
false = fromChars "False"

value :: Name
value = fromChars "Value"

node :: Name
node = fromChars "Node"

program :: Name
program = fromChars "Program"

_main :: Name
_main = fromChars "main"

_Main :: Name
_Main = fromChars "Main"

dollar :: Name
dollar = fromChars "$"

identity :: Name
identity = fromChars "identity"

replModule :: Name
replModule = fromChars "Gren_Repl"

replValueToPrint :: Name
replValueToPrint = fromChars "repl_input_value_"
