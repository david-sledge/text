{-# LANGUAGE BangPatterns, CPP, GeneralizedNewtypeDeriving, MagicHash,
    UnliftedFFITypes #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Module      : Data.Text.Encoding
-- Copyright   : (c) 2009, 2010, 2011 Bryan O'Sullivan,
--               (c) 2009 Duncan Coutts,
--               (c) 2008, 2009 Tom Harper
--               (c) 2021 Andrew Lelechenko
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Portability : portable
--
-- Functions for converting 'Text' values to and from 'ByteString',
-- using several standard encodings.
--
-- To gain access to a much larger family of encodings, use the
-- <http://hackage.haskell.org/package/text-icu text-icu package>.

module Data.Text.Encoding
    (
    -- * ByteString validation
    -- $validation
      Utf8ValidState
    , partialUtf8CodePoint
    , utf8CodePointState
    , validateUtf8Chunk
    , validateNextUtf8Chunk
    , startUtf8ValidState

    -- * Decoding ByteStrings to Text
    -- $strict

    -- ** Total Functions #total#
    -- $total
    , decodeLatin1
    , decodeAsciiPrefix
    , TextDataStack
    , dataStack
    , stackLen
    , emptyStack
    , pushText
    , stackToText
    , decodeNextUtf8Chunk
    , decodeUtf8Chunk
    , decodeUtf8Lenient

    -- *** Catchable failure
    , decodeUtf8'

    -- *** Controllable error handling
    , handleUtf8Err
    , decodeUtf8With
    , decodeUtf16LEWith
    , decodeUtf16BEWith
    , decodeUtf32LEWith
    , decodeUtf32BEWith

    -- *** Stream oriented decoding
    -- $stream
    , streamDecodeUtf8With
    , Decoding(..)

    -- ** Partial Functions
    -- $partial
    , decodeASCII
    , decodeUtf8
    , decodeUtf16LE
    , decodeUtf16BE
    , decodeUtf32LE
    , decodeUtf32BE

    -- *** Stream oriented decoding
    , streamDecodeUtf8

    -- * Encoding Text to ByteStrings
    , encodeUtf8
    , encodeUtf16LE
    , encodeUtf16BE
    , encodeUtf32LE
    , encodeUtf32BE

    -- * Encoding Text using ByteString Builders
    , encodeUtf8Builder
    , encodeUtf8BuilderEscaped
    ) where

import Control.Monad.ST.Unsafe (unsafeIOToST, unsafeSTToIO)

import Control.Exception (evaluate, try)
import Control.Monad.ST (runST)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import Data.Text.Encoding.Error (OnDecodeError, UnicodeException, strictDecode, lenientDecode)
import Data.Text.Internal (Text(..), empty)
import Data.Text.Internal.Unsafe (unsafeWithForeignPtr)
import Data.Text.Show as T (singleton)
import Data.Text.Unsafe (unsafeDupablePerformIO)
import Data.Word (Word8)
import Foreign.C.Types (CSize(..))
import Foreign.Ptr (Ptr, minusPtr, plusPtr)
import Foreign.Storable (poke, peekByteOff)
import GHC.Exts (byteArrayContents#, unsafeCoerce#)
import GHC.ForeignPtr (ForeignPtr(..), ForeignPtrContents(PlainPtr))
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Builder.Internal as B hiding (empty, append)
import qualified Data.ByteString.Builder.Prim as BP
import qualified Data.ByteString.Builder.Prim.Internal as BP
import Data.Text.Internal.Encoding.Utf8 (Utf8CodePointState, utf8StartState, updateUtf8State, isUtf8StateIsComplete)
import qualified Data.Text.Array as A
import qualified Data.Text.Internal.Encoding.Fusion as E
import qualified Data.Text.Internal.Fusion as F
import Data.Text.Internal.ByteStringCompat
#if defined(ASSERTS)
import GHC.Stack (HasCallStack)
#endif

#ifdef SIMDUTF
import Foreign.C.Types (CInt(..))
#elif !MIN_VERSION_bytestring(0,11,2)
import qualified Data.ByteString.Unsafe as B
#endif

-- $validation
-- These functions are for validating 'ByteString's as encoded text.

-- $strict
--
-- All of the single-parameter functions for decoding bytestrings
-- encoded in one of the Unicode Transformation Formats (UTF) operate
-- in a /strict/ mode: each will throw an exception if given invalid
-- input.
--
-- Each function has a variant, whose name is suffixed with -'With',
-- that gives greater control over the handling of decoding errors.
-- For instance, 'decodeUtf8' will throw an exception, but
-- 'decodeUtf8With' allows the programmer to determine what to do on a
-- decoding error.

-- $total
--
-- These functions facilitate total decoding and should be preferred
-- over their partial counterparts.

-- $partial
--
-- These functions are partial and should only be used with great caution
-- (preferably not at all). See "Data.Text.Encoding#g:total" for better
-- solutions.

-- | Decode a 'ByteString' containing 7-bit ASCII encoded text.
--
-- This is a total function. The 'ByteString' is decoded until either
-- the end is reached or it errors with the first non-ASCII 'Word8' is
-- encountered. In either case the function will return the 'Text'
-- value of the longest prefix that is valid ASCII. On error, the index
-- of the non-ASCII 'Word8' is also returned.
--
-- @since 2.0.2
decodeAsciiPrefix ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> (Text, Maybe (Word8, Int))
decodeAsciiPrefix bs = if B.null bs
  then (empty, Nothing)
  else unsafeDupablePerformIO $ withBS bs $ \ fp len ->
    unsafeWithForeignPtr fp $ \src -> do
      asciiPrefixLen <- fmap fromIntegral . c_is_ascii src $ src `plusPtr` len
      let !prefix = if asciiPrefixLen == 0
            then empty
            else runST $ do
              dst <- A.new asciiPrefixLen
              A.copyFromPointer dst 0 src asciiPrefixLen
              arr <- A.unsafeFreeze dst
              pure $ Text arr 0 asciiPrefixLen
      let suffix = if asciiPrefixLen < len
            then Just (B.index bs asciiPrefixLen, asciiPrefixLen)
            else Nothing
      pure (prefix, suffix)

-- | Decode a 'ByteString' containing 7-bit ASCII encoded text.
--
-- This is a partial function: it checks that input does not contain
-- anything except ASCII and copies buffer or throws an error otherwise.
--
decodeASCII :: ByteString -> Text
decodeASCII bs =
  case decodeAsciiPrefix bs of
    (_, Just (word, errPos)) -> error $ "decodeASCII: detected non-ASCII codepoint " ++ show word ++ " at position " ++ show errPos
    (t, Nothing) -> t

-- | Decode a 'ByteString' containing Latin-1 (aka ISO-8859-1) encoded text.
--
-- 'decodeLatin1' is semantically equivalent to
--  @Data.Text.pack . Data.ByteString.Char8.unpack@
--
-- This is a total function. However, bear in mind that decoding Latin-1 (non-ASCII)
-- characters to UTf-8 requires actual work and is not just buffer copying.
--
decodeLatin1 ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> Text
decodeLatin1 bs = withBS bs $ \fp len -> runST $ do
  dst <- A.new (2 * len)
  let inner srcOff dstOff = if srcOff >= len then return dstOff else do
        asciiPrefixLen <- fmap fromIntegral $ unsafeIOToST $ unsafeWithForeignPtr fp $ \src ->
          c_is_ascii (src `plusPtr` srcOff) (src `plusPtr` len)
        if asciiPrefixLen == 0
        then do
          byte <- unsafeIOToST $ unsafeWithForeignPtr fp $ \src -> peekByteOff src srcOff
          A.unsafeWrite dst dstOff (0xC0 + (byte `shiftR` 6))
          A.unsafeWrite dst (dstOff + 1) (0x80 + (byte .&. 0x3F))
          inner (srcOff + 1) (dstOff + 2)
        else do
          unsafeIOToST $ unsafeWithForeignPtr fp $ \src ->
            unsafeSTToIO $ A.copyFromPointer dst dstOff (src `plusPtr` srcOff) asciiPrefixLen
          inner (srcOff + asciiPrefixLen) (dstOff + asciiPrefixLen)

  actualLen <- inner 0 0
  dst' <- A.resizeM dst actualLen
  arr <- A.unsafeFreeze dst'
  return $ Text arr 0 actualLen

foreign import ccall unsafe "_hs_text_is_ascii" c_is_ascii
    :: Ptr Word8 -> Ptr Word8 -> IO CSize

-- | This data type represents the state of a 'ByteString' representing
-- UTF-8-encoded text. It consists of a value representing whether or
-- not the last byte is a complete code point, and on incompletion what
-- the 1 to 3 end bytes are that make up the incomplete code point.
data Utf8ValidState = Utf8ValidState
  { -- | Get the incomplete UTF-8 code point of the 'ByteString's that
    -- have been validated thus far.
    partialUtf8CodePoint :: [ByteString]
    -- | Get the current UTF-8 code point state of the 'ByteString's
    -- that have been validated thus far.
  , utf8CodePointState :: Utf8CodePointState
  }
  deriving (Eq, Ord, Show)

-- | This represtents the starting state of a UTF-8 validation check.
startUtf8ValidState :: Utf8ValidState 
startUtf8ValidState = Utf8ValidState [] utf8StartState

#ifdef SIMDUTF
foreign import ccall unsafe "_hs_text_is_valid_utf8" c_is_valid_utf8
    :: Ptr Word8 -> CSize -> IO CInt
#endif

-- | Validate a 'ByteString' as a UTF-8-encoded text.
--
-- @validateUtf8Chunk chunk = (n, es)@
--
-- This function returns two values:
--
-- * The value 'n' indicates the longest prefix of the 'ByteString'
--   that is valid UTF-8-encoded data.
-- * The value 'es' indicates whether the 'ByteString'
--
--     * (@Left p@) contains an invalid code point and where the next
--       (potentially valid) code point begins, so that @p - n@ is the
--       number of invalid bytes, or
--     * (@Right s@) is valid, and all of the remaining bytes starting
--       at inbex 'n' are the beginning of an incomplete UTF-8 code
--       point, and 's' is the resulting 'Utf8ValidState' value, which
--       can be used to validate against a following 'ByteString' with
--       'validateNextUtf8Chunk'.
validateUtf8Chunk ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> (Int, Either Int Utf8ValidState)
validateUtf8Chunk bs@(B.length -> len)
#if defined(SIMDUTF) || MIN_VERSION_bytestring(0,11,2)
  | guessUtf8Boundary > 0 &&
    -- the rest of the bytestring valid utf-8 up to the boundary
    (
#ifdef SIMDUTF
      withBS bs $ \ fp _ -> unsafeDupablePerformIO $
        unsafeWithForeignPtr fp $ \ptr -> (/= 0) <$>
          c_is_valid_utf8 ptr (fromIntegral guessUtf8Boundary)
#else
      B.isValidUtf8 $ B.take guessUtf8Boundary bs
#endif
    ) = getEndState guessUtf8Boundary
    -- No
  | otherwise = getEndState 0
    where
      getEndState ndx = validateUtf8 ndx ndx utf8StartState
      w n word8 = len >= n && word8 <= (B.index bs $ len - n)
      guessUtf8Boundary
        | w 3 0xf0 = len - 3  -- third to last char starts a four-byte code point
        | w 2 0xe0 = len - 2  -- pre-last char starts a three-or-four-byte code point
        | w 1 0xc2 = len - 1  -- last char starts a two-(or more-)byte code point
        | otherwise = len
#else
  = validateUtf8 0 0 utf8StartState
    where
#endif
      validateUtf8 !ndx0 ndx s
        | ndx < len =
          let ndx' = ndx + 1 in
          case updateUtf8State (B.index bs ndx) s of
            Just s' ->
              validateUtf8 (
                if isUtf8StateIsComplete s'
                then ndx'
                else ndx0
              ) ndx' s'
            Nothing -> (ndx0, Left $ if ndx == ndx0 then ndx' else ndx)
        | otherwise = (ndx0, Right $ Utf8ValidState (if ndx0 < len then [B.drop ndx0 bs] else []) s)

-- | Validate a 'ByteString' as a contiuation of UTF-8-encoded text.
--
-- @validateNextUtf8Chunk chunk s = (n, es)@
--
-- This function returns two values:
--
-- * The value 'n' indicates the end position of longest prefix of the
--   'ByteString' that is valid UTF-8-encoded data from the starting
--   state 's'. If 's' contains an incomplete code point, the input
--   'ByteString' is considered a continuation. As a result 'n' will be
--   negative if the code point is still incomplete or is proven to be
--   invalid.
--   
-- * The value 'es' indicates whether the 'ByteString'
--
--     * (@Left p@) contains an invalid code point and where the next
--       (potentially valid) code point begins, so that @p - n@ is the
--       number of invalid bytes, or
--     * (@Right s'@) is valid, and all of the remaining bytes starting
--       at inbex 'n' are the beginning of an incomplete UTF-8 code
--       point, and `s'` is the resulting 'Utf8ValidState' value, which
--       can be used to validate against a following 'ByteString'.
validateNextUtf8Chunk ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> Utf8ValidState -> (Int, Either Int Utf8ValidState)
validateNextUtf8Chunk bs@(B.length -> len) st@(Utf8ValidState lead s)
  | len > 0 =
    let g pos s'
          -- first things first. let's try to get to the start of the next code point
          | isUtf8StateIsComplete s' =
            -- found the beginning of the next code point, hand this off to someone else
            case validateUtf8Chunk $ B.drop pos bs of
              (len', mS) -> (pos + len', case mS of Left p -> Left (p + pos); _ -> mS)
          -- code point is not complete yet
          -- walk the rest of the code point until error, complete, or no more data
          | pos < len =
            case updateUtf8State (B.index bs pos) s' of
              -- error
              Nothing -> (leadPos, Left pos)
              -- keep going
              Just s'' -> g (pos + 1) s''
          -- no more data
          | otherwise = (leadPos, Right $ Utf8ValidState (lead ++ [bs]) s')
    in g 0 s
  | otherwise = (leadPos, Right st)
    where leadPos = -(foldr (\ bs' len' -> len' + B.length bs') 0 lead)

-- | Validated UTF-8 data to be converted into a 'Text' value.
data TextDataStack = TextDataStack
  { -- | Returns a list of 'Text' and UTF-8-valid 'ByteString' values.
    dataStack :: [Either Text ByteString]
    -- | Returns total number of UTF-8 valid bytes in the stack.
  , stackLen :: Int
  }
  deriving Show

-- | Empty stack
emptyStack :: TextDataStack
emptyStack = TextDataStack [] 0

-- | Push a text value onto the stack
pushText :: Text -> TextDataStack -> TextDataStack
pushText t@(Text _ _ tLen) tds@(TextDataStack stack sLen) =
  if tLen > 0
  then TextDataStack (Left t : stack) $ sLen + tLen
  else tds

-- | Create a 'Text' value from the contents of a 'TextDataStack'.
stackToText ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  TextDataStack -> Text
stackToText (TextDataStack stack sLen)
  | sLen > 0 = runST $
    do
      dst <- A.new sLen
      let g (dat : dataStack') tLen' =
              (case dat of
                Left (Text arr0 off utf8Len) -> do
                  let dstOff = tLen' - utf8Len
                  A.copyI utf8Len dst dstOff arr0 off
                  pure dstOff
                Right bs@(B.length -> utf8Len) -> do
                  let dstOff = tLen' - utf8Len
                  withBS bs $ \ fp _ ->
                    unsafeIOToST . unsafeWithForeignPtr fp $ \ src ->
                      unsafeSTToIO $ A.copyFromPointer dst dstOff src utf8Len
                  pure dstOff) >>= g dataStack'
          g _ _ = pure ()
      g stack sLen
      arr <- A.unsafeFreeze dst
      pure $ Text arr 0 sLen
  | otherwise = empty

-- | Decode a 'ByteString' in the context of what has been already been decoded.
--
-- The 'ByteString' is validated against the 'Utf8ValidState' using the rules
-- governing 'validateNextUtf8Chunk'. The longest valid UTF-8 prefix is added
-- to the input 'TextDataStack' which is returned with the end position of the
-- valid prefix, and either the resulting 'Utf8ValidState'
-- (@Right Utf8ValidState@) or the position of the of the first (potentially)
-- valid byte after the invalid bytes with remainder of the 'ByteString'
-- (@Left (Int, ByteString)@).
decodeNextUtf8Chunk ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString
  -> Utf8ValidState
  -> TextDataStack
  -> ((Int, Either (Int, ByteString) Utf8ValidState), TextDataStack)
decodeNextUtf8Chunk bs s tds =
  case validateNextUtf8Chunk bs s of
    (len, res) ->
      let stackedData'
            | len >= 0 =
              let stackedData@(TextDataStack stack' sLen') =
                    foldl (\ tds'@(TextDataStack stack sLen) bs'@(B.length -> bLen) ->
                      if bLen > 0
                      then TextDataStack (Right bs' : stack) $ sLen + bLen
                      else tds'
                      ) tds $ partialUtf8CodePoint s
              in
              if len > 0
              then TextDataStack (Right (B.take len bs) : stack') $ sLen' + len
              else stackedData
            | otherwise = tds
      in
      ( ( len
        , case res of
            Left pos -> Left (pos, B.drop pos bs)
            Right s' -> Right s'
        )
      , stackedData'
      )

-- | Decode a 'ByteString' against a start 'Utf8ValidState' with an empty
-- 'TextDataStack'.
--
-- @decodeUtf8Chunk bs = 'decodeNextUtf8Chunk' bs 'startUtf8ValidState' 'emptyStack'@
decodeUtf8Chunk :: ByteString -> ((Int, Either (Int, ByteString) Utf8ValidState), TextDataStack)
decodeUtf8Chunk bs = decodeNextUtf8Chunk bs startUtf8ValidState emptyStack

-- | Call an error handler with the give 'String' message for each byte
-- in given 'ByteString' and lead data in the given 'Utf8ValidState'
-- value. The bytes are the positions from 'errStart' (inclusive) to
-- 'errEnd' (exclusive). Any substite characters are pushed onto the
-- supplied 'TextDataStack' argument.
handleUtf8Err
  :: OnDecodeError
  -> String
  -> Int
  -> Int
  -> Utf8ValidState
  -> ByteString
  -> TextDataStack
  -> TextDataStack
handleUtf8Err onErr errMsg errStart errEnd s bs tds =
  let h errPos errEndPos bss tds'
        | errPos < errEndPos =
          let errPos' = errPos + 1 in
          case bss of
            bs'@(B.length -> len) : bss' ->
              ( if errPos' < len
                then h errPos' errEndPos bss
                else h 0 (errEndPos - len) bss'
              ) $ case onErr errMsg . Just $ B.index bs' errPos of
                Just c -> pushText (T.singleton c) tds'
                Nothing -> tds'
            [] -> tds'
        | otherwise = tds'
  in
  ( if errStart < 0
    then h 0 (errEnd - errStart) $ partialUtf8CodePoint s ++ [B.take errEnd bs]
    else h errStart errEnd [bs]
  ) tds

invalidUtf8Msg :: String
invalidUtf8Msg = "Data.Text.Internal.Encoding: Invalid UTF-8 stream"

-- | Decode a 'ByteString' containing UTF-8 encoded text.
--
-- Surrogate code points in replacement character returned by 'OnDecodeError'
-- will be automatically remapped to the replacement char @U+FFFD@.
decodeUtf8With ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  OnDecodeError -> ByteString -> Text
decodeUtf8With onErr bs =
  let g bs'@(B.length -> bLen) res =
        case res of
          ((len, eS), tds) ->
            let h msg pos s = handleUtf8Err onErr msg len pos s bs' tds in
            case eS of
              Left (pos, bs'') -> g bs'' . decodeNextUtf8Chunk bs'' startUtf8ValidState $ h invalidUtf8Msg pos startUtf8ValidState
              Right s -> stackToText $ h "Data.Text.Internal.Encoding: Incomplete UTF-8 code point" bLen s
  in
  g bs $ decodeUtf8Chunk bs

-- $stream
--
-- The 'streamDecodeUtf8' and 'streamDecodeUtf8With' functions accept
-- a 'ByteString' that represents a possibly incomplete input (e.g. a
-- packet from a network stream) that may not end on a UTF-8 boundary.
--
-- 1. The maximal prefix of 'Text' that could be decoded from the
--    given input.
--
-- 2. The suffix of the 'ByteString' that could not be decoded due to
--    insufficient input.
--
-- 3. A function that accepts another 'ByteString'.  That string will
--    be assumed to directly follow the string that was passed as
--    input to the original function, and it will in turn be decoded.
--
-- To help understand the use of these functions, consider the Unicode
-- string @\"hi &#9731;\"@. If encoded as UTF-8, this becomes @\"hi
-- \\xe2\\x98\\x83\"@; the final @\'&#9731;\'@ is encoded as 3 bytes.
--
-- Now suppose that we receive this encoded string as 3 packets that
-- are split up on untidy boundaries: @[\"hi \\xe2\", \"\\x98\",
-- \"\\x83\"]@. We cannot decode the entire Unicode string until we
-- have received all three packets, but we would like to make progress
-- as we receive each one.
--
-- @
-- ghci> let s0\@('Some' _ _ f0) = 'streamDecodeUtf8' \"hi \\xe2\"
-- ghci> s0
-- 'Some' \"hi \" \"\\xe2\" _
-- @
--
-- We use the continuation @f0@ to decode our second packet.
--
-- @
-- ghci> let s1\@('Some' _ _ f1) = f0 \"\\x98\"
-- ghci> s1
-- 'Some' \"\" \"\\xe2\\x98\"
-- @
--
-- We could not give @f0@ enough input to decode anything, so it
-- returned an empty string. Once we feed our second continuation @f1@
-- the last byte of input, it will make progress.
--
-- @
-- ghci> let s2\@('Some' _ _ f2) = f1 \"\\x83\"
-- ghci> s2
-- 'Some' \"\\x2603\" \"\" _
-- @
--
-- If given invalid input, an exception will be thrown by the function
-- or continuation where it is encountered.

-- | A stream oriented decoding result.
--
-- @since 1.0.0.0
data Decoding = Some !Text !ByteString (ByteString -> Decoding)

instance Show Decoding where
    showsPrec d (Some t bs _) = showParen (d > prec) $
                                showString "Some " . showsPrec prec' t .
                                showChar ' ' . showsPrec prec' bs .
                                showString " _"
      where prec = 10; prec' = prec + 1

-- | Decode, in a stream oriented way, a 'ByteString' containing UTF-8
-- encoded text that is known to be valid.
--
-- If the input contains any invalid UTF-8 data, an exception will be
-- thrown (either by this function or a continuation) that cannot be
-- caught in pure code.  For more control over the handling of invalid
-- data, use 'streamDecodeUtf8With'.
--
-- @since 1.0.0.0
streamDecodeUtf8 ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> Decoding
streamDecodeUtf8 = streamDecodeUtf8With strictDecode

-- | Decode, in a stream oriented way, a lazy 'ByteString' containing UTF-8
-- encoded text.
--
-- @since 1.0.0.0
streamDecodeUtf8With ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  OnDecodeError -> ByteString -> Decoding
streamDecodeUtf8With onErr bs =
  let g bs' s tds =
        case decodeNextUtf8Chunk bs' s tds of
          ((len, eS), tds') ->
            case eS of
              Left (pos, bs'') -> g bs'' startUtf8ValidState $ handleUtf8Err onErr invalidUtf8Msg len pos s bs' tds'
              Right s' -> let bss' = partialUtf8CodePoint s' in
                Some (stackToText tds') (B.concat bss') $ \ bs'' ->
                  g bs'' s' emptyStack
  in
  g bs startUtf8ValidState emptyStack

-- | Decode a 'ByteString' containing UTF-8 encoded text that is known
-- to be valid.
--
-- If the input contains any invalid UTF-8 data, an exception will be
-- thrown that cannot be caught in pure code.  For more control over
-- the handling of invalid data, use 'decodeUtf8'' or
-- 'decodeUtf8With'.
--
-- This is a partial function: it checks that input is a well-formed
-- UTF-8 sequence and copies buffer or throws an error otherwise.
--
decodeUtf8 :: ByteString -> Text
decodeUtf8 = decodeUtf8With strictDecode
{-# INLINE[0] decodeUtf8 #-}

-- | Decode a 'ByteString' containing UTF-8 encoded text.
--
-- If the input contains any invalid UTF-8 data, the relevant
-- exception will be returned, otherwise the decoded text.
decodeUtf8' ::
#if defined(ASSERTS)
  HasCallStack =>
#endif
  ByteString -> Either UnicodeException Text
decodeUtf8' = unsafeDupablePerformIO . try . evaluate . decodeUtf8With strictDecode
{-# INLINE decodeUtf8' #-}

-- | Decode a 'ByteString' containing UTF-8 encoded text.
--
-- Any invalid input bytes will be replaced with the Unicode replacement
-- character U+FFFD.
decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = decodeUtf8With lenientDecode

-- | Encode text to a ByteString 'B.Builder' using UTF-8 encoding.
--
-- @since 1.1.0.0
encodeUtf8Builder :: Text -> B.Builder
encodeUtf8Builder =
    -- manual eta-expansion to ensure inlining works as expected
    \txt -> B.builder (step txt)
  where
    step txt@(Text arr off len) !k br@(B.BufferRange op ope)
      -- Ensure that the common case is not recursive and therefore yields
      -- better code.
      | op' <= ope = do
          unsafeSTToIO $ A.copyToPointer arr off op len
          k (B.BufferRange op' ope)
      | otherwise = textCopyStep txt k br
      where
        op' = op `plusPtr` len
{-# INLINE encodeUtf8Builder #-}

textCopyStep :: Text -> B.BuildStep a -> B.BuildStep a
textCopyStep (Text arr off len) k =
    go off (off + len)
  where
    go !ip !ipe (B.BufferRange op ope)
      | inpRemaining <= outRemaining = do
          unsafeSTToIO $ A.copyToPointer arr ip op inpRemaining
          let !br = B.BufferRange (op `plusPtr` inpRemaining) ope
          k br
      | otherwise = do
          unsafeSTToIO $ A.copyToPointer arr ip op outRemaining
          let !ip' = ip + outRemaining
          return $ B.bufferFull 1 ope (go ip' ipe)
      where
        outRemaining = ope `minusPtr` op
        inpRemaining = ipe - ip

-- | Encode text using UTF-8 encoding and escape the ASCII characters using
-- a 'BP.BoundedPrim'.
--
-- Use this function is to implement efficient encoders for text-based formats
-- like JSON or HTML.
--
-- @since 1.1.0.0
{-# INLINE encodeUtf8BuilderEscaped #-}
-- TODO: Extend documentation with references to source code in @blaze-html@
-- or @aeson@ that uses this function.
encodeUtf8BuilderEscaped :: BP.BoundedPrim Word8 -> Text -> B.Builder
encodeUtf8BuilderEscaped be =
    -- manual eta-expansion to ensure inlining works as expected
    \txt -> B.builder (mkBuildstep txt)
  where
    bound = max 4 $ BP.sizeBound be

    mkBuildstep (Text arr off len) !k =
        outerLoop off
      where
        iend = off + len

        outerLoop !i0 !br@(B.BufferRange op0 ope)
          | i0 >= iend       = k br
          | outRemaining > 0 = goPartial (i0 + min outRemaining inpRemaining)
          -- TODO: Use a loop with an integrated bound's check if outRemaining
          -- is smaller than 8, as this will save on divisions.
          | otherwise        = return $ B.bufferFull bound op0 (outerLoop i0)
          where
            outRemaining = (ope `minusPtr` op0) `quot` bound
            inpRemaining = iend - i0

            goPartial !iendTmp = go i0 op0
              where
                go !i !op
                  | i < iendTmp = do
                    let w = A.unsafeIndex arr i
                    if w < 0x80
                      then BP.runB be w op >>= go (i + 1)
                      else poke op w >> go (i + 1) (op `plusPtr` 1)
                  | otherwise = outerLoop i (B.BufferRange op ope)

-- | Encode text using UTF-8 encoding.
encodeUtf8 :: Text -> ByteString
encodeUtf8 (Text arr off len)
  | len == 0  = B.empty
  -- It would be easier to use Data.ByteString.Short.fromShort and slice later,
  -- but this is undesirable when len is significantly smaller than length arr.
  | otherwise = unsafeDupablePerformIO $ do
    marr@(A.MutableByteArray mba) <- unsafeSTToIO $ A.newPinned len
    unsafeSTToIO $ A.copyI len marr 0 arr off
    let fp = ForeignPtr (byteArrayContents# (unsafeCoerce# mba))
                        (PlainPtr mba)
    pure $ B.fromForeignPtr fp 0 len

-- | Decode text from little endian UTF-16 encoding.
decodeUtf16LEWith :: OnDecodeError -> ByteString -> Text
decodeUtf16LEWith onErr bs = F.unstream (E.streamUtf16LE onErr bs)
{-# INLINE decodeUtf16LEWith #-}

-- | Decode text from little endian UTF-16 encoding.
--
-- If the input contains any invalid little endian UTF-16 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf16LEWith'.
decodeUtf16LE :: ByteString -> Text
decodeUtf16LE = decodeUtf16LEWith strictDecode
{-# INLINE decodeUtf16LE #-}

-- | Decode text from big endian UTF-16 encoding.
decodeUtf16BEWith :: OnDecodeError -> ByteString -> Text
decodeUtf16BEWith onErr bs = F.unstream (E.streamUtf16BE onErr bs)
{-# INLINE decodeUtf16BEWith #-}

-- | Decode text from big endian UTF-16 encoding.
--
-- If the input contains any invalid big endian UTF-16 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf16BEWith'.
decodeUtf16BE :: ByteString -> Text
decodeUtf16BE = decodeUtf16BEWith strictDecode
{-# INLINE decodeUtf16BE #-}

-- | Encode text using little endian UTF-16 encoding.
encodeUtf16LE :: Text -> ByteString
encodeUtf16LE txt = E.unstream (E.restreamUtf16LE (F.stream txt))
{-# INLINE encodeUtf16LE #-}

-- | Encode text using big endian UTF-16 encoding.
encodeUtf16BE :: Text -> ByteString
encodeUtf16BE txt = E.unstream (E.restreamUtf16BE (F.stream txt))
{-# INLINE encodeUtf16BE #-}

-- | Decode text from little endian UTF-32 encoding.
decodeUtf32LEWith :: OnDecodeError -> ByteString -> Text
decodeUtf32LEWith onErr bs = F.unstream (E.streamUtf32LE onErr bs)
{-# INLINE decodeUtf32LEWith #-}

-- | Decode text from little endian UTF-32 encoding.
--
-- If the input contains any invalid little endian UTF-32 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf32LEWith'.
decodeUtf32LE :: ByteString -> Text
decodeUtf32LE = decodeUtf32LEWith strictDecode
{-# INLINE decodeUtf32LE #-}

-- | Decode text from big endian UTF-32 encoding.
decodeUtf32BEWith :: OnDecodeError -> ByteString -> Text
decodeUtf32BEWith onErr bs = F.unstream (E.streamUtf32BE onErr bs)
{-# INLINE decodeUtf32BEWith #-}

-- | Decode text from big endian UTF-32 encoding.
--
-- If the input contains any invalid big endian UTF-32 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf32BEWith'.
decodeUtf32BE :: ByteString -> Text
decodeUtf32BE = decodeUtf32BEWith strictDecode
{-# INLINE decodeUtf32BE #-}

-- | Encode text using little endian UTF-32 encoding.
encodeUtf32LE :: Text -> ByteString
encodeUtf32LE txt = E.unstream (E.restreamUtf32LE (F.stream txt))
{-# INLINE encodeUtf32LE #-}

-- | Encode text using big endian UTF-32 encoding.
encodeUtf32BE :: Text -> ByteString
encodeUtf32BE txt = E.unstream (E.restreamUtf32BE (F.stream txt))
{-# INLINE encodeUtf32BE #-}
