{-|
  Copyright   :  (C) 2013-2016, University of Twente, 2017, QBayLogic
  License     :  BSD2 (see the file LICENSE)
  Maintainer  :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE CPP               #-}
{-# LANGUAGE ViewPatterns      #-}
{-# LANGUAGE MagicHash         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE UnboxedTuples     #-}

module CLaSH.GHC.Evaluator where

import           Control.Monad.Trans.Except (runExcept)
import qualified Data.Bifunctor      as Bifunctor
import           Data.Bits
import qualified Data.Either         as Either
import qualified Data.HashMap.Strict as HashMap
import           Data.Maybe          (catMaybes)
import qualified Data.List           as List
import           Data.Proxy          (Proxy)
import           Data.Reflection     (reifyNat)
import           Data.Text           (Text)
-- import           Data.Word
import           GHC.Int
import           GHC.Prim
import           GHC.Real            (Ratio (..))
import           GHC.TypeLits        (KnownNat)
import           GHC.Word
import           Unbound.Generics.LocallyNameless
  (bind, embed, rebind, runFreshM)

import           CLaSH.Core.DataCon  (DataCon (..), dataConInstArgTys)
import           CLaSH.Core.Literal  (Literal (..))
import           CLaSH.Core.Name     (Name (..), string2SystemName)
import           CLaSH.Core.Pretty   (showDoc)
import           CLaSH.Core.Term     (Pat (..), Term (..))
import           CLaSH.Core.Type
  (Type (..), ConstTy (..), LitTy (..), TypeView (..), mkFunTy, mkTyConApp,
   splitFunForallTy, tyView, undefinedTy)
import           CLaSH.Core.TyCon    (TyCon, TyConOccName, tyConDataCons)
import           CLaSH.Core.TysPrim
import           CLaSH.Core.Util     (collectArgs,mkApps,mkRTree,mkVec,termType,
                                      tyNatSize)
import           CLaSH.Core.Var      (Var (..))
import           CLaSH.Util          (clogBase, flogBase, curLoc)

import CLaSH.Promoted.Nat.Unsafe (unsafeSNat)
import qualified CLaSH.Sized.Internal.BitVector as BitVector
import qualified CLaSH.Sized.Internal.Signed    as Signed
import qualified CLaSH.Sized.Internal.Unsigned  as Unsigned
import CLaSH.Sized.Internal.BitVector(BitVector(..), Bit)
import CLaSH.Sized.Internal.Signed   (Signed   (..))
import CLaSH.Sized.Internal.Unsigned (Unsigned (..))

reduceConstant :: HashMap.HashMap TyConOccName TyCon -> Bool -> Term -> Term
reduceConstant tcm isSubj e@(collectArgs -> (Prim nm ty, args)) = case nm of
  "GHC.Prim.eqChar#" | Just (i,j) <- charLiterals tcm isSubj args
    -> boolToIntLiteral (i == j)

  "GHC.Prim.neChar#" | Just (i,j) <- charLiterals tcm isSubj args
    -> boolToIntLiteral (i /= j)

  "GHC.Prim.+#" | Just (i,j) <- intLiterals tcm isSubj args
    -> integerToIntLiteral (i+j)

  "GHC.Prim.-#" | Just (i,j) <- intLiterals tcm isSubj args
    -> integerToIntLiteral (i-j)

  "GHC.Prim.*#" | Just (i,j) <- intLiterals tcm isSubj args
    -> integerToIntLiteral (i*j)

  "GHC.Prim.quotInt#" | Just (i,j) <- intLiterals tcm isSubj args
    -> integerToIntLiteral (i `quot` j)

  "GHC.Prim.remInt#" | Just (i,j) <- intLiterals tcm isSubj args
    -> integerToIntLiteral (i `rem` j)

  "GHC.Prim.quotRemInt#" | Just (i,j) <- intLiterals tcm isSubj args
    -> let (_,tyView -> TyConApp tupTcNm tyArgs) = splitFunForallTy ty
           (Just tupTc) = HashMap.lookup (nameOcc tupTcNm) tcm
           [tupDc] = tyConDataCons tupTc
           (q,r)   = quotRem i j
           ret     = mkApps (Data tupDc) (map Right tyArgs ++
                    [Left (integerToIntLiteral q), Left (integerToIntLiteral r)])
       in  ret

  "GHC.Prim.negateInt#"
    | [Literal (IntLiteral i)] <- reduceTerms tcm isSubj args
    -> integerToIntLiteral (negate i)

  "GHC.Prim.>#" | Just (i,j) <- intLiterals tcm isSubj args
    -> boolToIntLiteral (i > j)

  "GHC.Prim.>=#" | Just (i,j) <- intLiterals tcm isSubj args
    -> boolToIntLiteral (i >= j)

  "GHC.Prim.==#" | Just (i,j) <- intLiterals tcm isSubj args
    -> boolToIntLiteral (i == j)

  "GHC.Prim./=#" | Just (i,j) <- intLiterals tcm isSubj args
    -> boolToIntLiteral (i /= j)

  "GHC.Prim.<#" | Just (i,j) <- intLiterals tcm isSubj args
    -> boolToIntLiteral (i < j)

  "GHC.Prim.<=#" | Just (i,j) <- intLiterals tcm isSubj args
    -> boolToIntLiteral (i <= j)

  "GHC.Prim.eqWord#" | Just (i,j) <- wordLiterals tcm isSubj args
    -> boolToIntLiteral (i == j)

  "GHC.Prim.neWord#" | Just (i,j) <- wordLiterals tcm isSubj args
    -> boolToIntLiteral (i /= j)

  "GHC.Prim.tagToEnum#"
    | [Right (ConstTy (TyCon tcN)), Left (Literal (IntLiteral i))] <-
      map (Bifunctor.bimap (reduceConstant tcm isSubj) id) args
    -> let dc = do { tc <- HashMap.lookup (nameOcc tcN) tcm
                   ; let dcs = tyConDataCons tc
                   ; List.find ((== (i+1)) . toInteger . dcTag) dcs
                   }
       in maybe e Data dc

  "GHC.Prim.int2Word#"
    | [Literal (IntLiteral i)] <- reduceTerms tcm isSubj args
    -> Literal . WordLiteral . toInteger $ (fromInteger :: Integer -> Word) i -- for overflow behaviour

  "GHC.Prim.plusWord2#" | Just (i,j) <- wordLiterals tcm isSubj args
    -> let (_,tyView -> TyConApp tupTcNm tyArgs) = splitFunForallTy ty
           (Just tupTc) = HashMap.lookup (nameOcc tupTcNm) tcm
           [tupDc] = tyConDataCons tupTc
           !(W# a)  = fromInteger i
           !(W# b)  = fromInteger j
           !(# h, l #) = plusWord2# a b
       in  mkApps (Data tupDc) (map Right tyArgs ++
                   [ Left (Literal . WordLiteral . toInteger $ W# h)
                   , Left (Literal . WordLiteral . toInteger $ W# l)])

  "GHC.Prim.timesWord2#" | Just (i,j) <- wordLiterals tcm isSubj args
    -> let (_,tyView -> TyConApp tupTcNm tyArgs) = splitFunForallTy ty
           (Just tupTc) = HashMap.lookup (nameOcc tupTcNm) tcm
           [tupDc] = tyConDataCons tupTc
           !(W# a)  = fromInteger i
           !(W# b)  = fromInteger j
           !(# h, l #) = timesWord2# a b
       in  mkApps (Data tupDc) (map Right tyArgs ++
                   [ Left (Literal . WordLiteral . toInteger $ W# h)
                   , Left (Literal . WordLiteral . toInteger $ W# l)])

  "GHC.Prim.subWordC#" | Just (i,j) <- wordLiterals tcm isSubj args
    -> let (_,tyView -> TyConApp tupTcNm tyArgs) = splitFunForallTy ty
           (Just tupTc) = HashMap.lookup (nameOcc tupTcNm) tcm
           [tupDc] = tyConDataCons tupTc
           !(W# a)  = fromInteger i
           !(W# b)  = fromInteger j
           !(# d, c #) = subWordC# a b
       in  mkApps (Data tupDc) (map Right tyArgs ++
                   [ Left (Literal . WordLiteral . toInteger $ W# d)
                   , Left (Literal . IntLiteral . toInteger $ I# c)])

  "GHC.Prim.uncheckedShiftL#"
    | [ Literal (WordLiteral w)
      , Literal (IntLiteral  i)
      ] <- reduceTerms tcm isSubj args
    -> Literal (WordLiteral (w `shiftL` fromInteger i))

  "GHC.Classes.geInt" | Just (i,j) <- intCLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >= j)

  "GHC.Integer.Logarithms.integerLogBase#"
    | Just (a,b) <- integerLiterals tcm isSubj args
    , Just c <- flogBase a b
    -> (Literal . IntLiteral . toInteger) c

  "GHC.Integer.Type.smallInteger"
    | [Literal (IntLiteral i)] <- reduceTerms tcm isSubj args
    -> Literal (IntegerLiteral i)

  "GHC.Integer.Type.integerToInt"
    | [Literal (IntegerLiteral i)] <- reduceTerms tcm isSubj args
    -> integerToIntLiteral i

  "GHC.Integer.Type.plusInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> integerToIntegerLiteral (i+j)

  "GHC.Integer.Type.minusInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> integerToIntegerLiteral (i-j)

  "GHC.Integer.Type.timesInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> integerToIntegerLiteral (i*j)

  "GHC.Integer.Type.negateInteger#"
    | [Literal (IntegerLiteral i)] <- reduceTerms tcm isSubj args
    -> integerToIntegerLiteral (negate i)

  "GHC.Integer.Type.divInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> integerToIntegerLiteral (i `div` j)

  "GHC.Integer.Type.modInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> integerToIntegerLiteral (i `mod` j)

  "GHC.Integer.Type.quotInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> integerToIntegerLiteral (i `quot` j)

  "GHC.Integer.Type.remInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> integerToIntegerLiteral (i `rem` j)

  "GHC.Integer.Type.divModInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> let (_,tyView -> TyConApp ubTupTcNm [liftedKi,_,intTy,_]) = splitFunForallTy ty
           (Just ubTupTc) = HashMap.lookup (nameOcc ubTupTcNm) tcm
           [ubTupDc] = tyConDataCons ubTupTc
           (d,m) = divMod i j
       in  mkApps (Data ubTupDc) [ Right liftedKi, Right liftedKi
                                 , Right intTy,    Right intTy
                                 , Left (Literal (IntegerLiteral d))
                                 , Left (Literal (IntegerLiteral m))
                                 ]

  "GHC.Integer.Type.gtInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i > j)

  "GHC.Integer.Type.geInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >= j)

  "GHC.Integer.Type.eqInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i == j)

  "GHC.Integer.Type.neqInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i /= j)

  "GHC.Integer.Type.ltInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i < j)

  "GHC.Integer.Type.leInteger" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i <= j)

  "GHC.Integer.Type.gtInteger#" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToIntLiteral (i > j)

  "GHC.Integer.Type.geInteger#" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToIntLiteral (i >= j)

  "GHC.Integer.Type.eqInteger#" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToIntLiteral (i == j)

  "GHC.Integer.Type.neqInteger#" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToIntLiteral (i /= j)

  "GHC.Integer.Type.ltInteger#" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToIntLiteral (i < j)

  "GHC.Integer.Type.leInteger#" | Just (i,j) <- integerLiterals tcm isSubj args
    -> boolToIntLiteral (i <= j)

  "GHC.Integer.Type.shiftRInteger"
    | [Literal (IntegerLiteral i), Literal (IntLiteral j)] <- reduceTerms tcm isSubj args
    -> integerToIntegerLiteral (i `shiftR` fromInteger j)

  "GHC.Integer.Type.shiftLInteger"
    | [Literal (IntegerLiteral i), Literal (IntLiteral j)] <- reduceTerms tcm isSubj args
    -> integerToIntegerLiteral (i `shiftL` fromInteger j)

  "GHC.Integer.Type.wordToInteger"
    | [Literal (WordLiteral w)] <- reduceTerms tcm isSubj args
    -> Literal (IntegerLiteral w)

  "GHC.Natural.NatS#"
    | [Literal (WordLiteral w)] <- reduceTerms tcm isSubj args
    -> Literal (NaturalLiteral w)

  "GHC.TypeLits.natVal"
#if MIN_VERSION_ghc(8,2,0)
    | [Literal (NaturalLiteral n), _] <- reduceTerms tcm isSubj args
    -> integerToIntegerLiteral n
#else
    | [Literal (IntegerLiteral i), _] <- reduceTerms tcm isSubj args
    -> integerToIntegerLiteral i
#endif

#if MIN_VERSION_ghc(8,2,0)
  "GHC.TypeNats.natVal"
    | [Literal (NaturalLiteral n), _] <- reduceTerms tcm isSubj args
    -> Literal (NaturalLiteral n)
#endif

  "GHC.Types.I#"
    | isSubj
    , [Literal (IntLiteral i)] <- reduceTerms tcm isSubj args
    ->  let (_,tyView -> TyConApp intTcNm []) = splitFunForallTy ty
            (Just intTc) = HashMap.lookup (nameOcc intTcNm) tcm
            [intDc] = tyConDataCons intTc
        in  mkApps (Data intDc) [Left (Literal (IntLiteral i))]

  "GHC.Float.$w$sfromRat''" -- XXX: Very fragile
    | [Literal (IntLiteral _minEx)
      ,Literal (IntLiteral matDigs)
      ,Literal (IntegerLiteral n)
      ,Literal (IntegerLiteral d)] <- reduceTerms tcm isSubj args
    -> case fromInteger matDigs of
          matDigs'
            | matDigs' == floatDigits (undefined :: Float)
            -> Literal (FloatLiteral (toRational (fromRational (n :% d) :: Float)))
            | matDigs' == floatDigits (undefined :: Double)
            -> Literal (DoubleLiteral (toRational (fromRational (n :% d) :: Double)))
          _ -> error $ $(curLoc) ++ "GHC.Float.$w$sfromRat'': Not a Float or Double: " ++ showDoc e

  "GHC.Float.$w$sfromRat''1" -- XXX: Very fragile
    | [Literal (IntLiteral _minEx)
      ,Literal (IntLiteral matDigs)
      ,Literal (IntegerLiteral n)
      ,Literal (IntegerLiteral d)] <- reduceTerms tcm isSubj args
    -> case fromInteger matDigs of
          matDigs'
            | matDigs' == floatDigits (undefined :: Float)
            -> Literal (FloatLiteral (toRational (fromRational (n :% d) :: Float)))
            | matDigs' == floatDigits (undefined :: Double)
            -> Literal (DoubleLiteral (toRational (fromRational (n :% d) :: Double)))
          _ -> error $ $(curLoc) ++ "GHC.Float.$w$sfromRat'': Not a Float or Double: " ++ showDoc e

  "GHC.Integer.Type.doubleFromInteger"
    | [Literal (IntegerLiteral i)] <- reduceTerms tcm isSubj args
    -> Literal (DoubleLiteral (toRational (fromInteger i :: Double)))

  "GHC.Prim.double2Float#"
    | [Literal (DoubleLiteral d)] <- reduceTerms tcm isSubj args
    -> Literal (FloatLiteral (toRational (fromRational d :: Float)))

  "GHC.Prim.divideFloat#"
    | [Literal (FloatLiteral f1)
      ,Literal (FloatLiteral f2)] <- reduceTerms tcm isSubj args
    -> Literal (FloatLiteral (toRational (fromRational f1 / fromRational f2 :: Float)))

  "GHC.Base.eqString"
    | [(_,[Left (Literal (StringLiteral s1))])
      ,(_,[Left (Literal (StringLiteral s2))])
      ] <- map collectArgs (Either.lefts args)
    -> boolToBoolLiteral tcm ty (s1 == s2)

  "CLaSH.Promoted.Nat.powSNat"
    | [Right a, Right b] <- (map (runExcept . tyNatSize tcm) . Either.rights) args
    -> let c = case a of
                 2 -> 1 `shiftL` (fromInteger b)
                 _ -> a ^ b
           (_,tyView -> TyConApp snatTcNm _) = splitFunForallTy ty
           (Just snatTc) = HashMap.lookup (nameOcc snatTcNm) tcm
           [snatDc] = tyConDataCons snatTc
       in  mkApps (Data snatDc) [ Right (LitTy (NumTy c))
#if MIN_VERSION_ghc(8,2,0)
                                , Left (Literal (NaturalLiteral c))]
#else
                                , Left (Literal (IntegerLiteral c))]
#endif

  "CLaSH.Promoted.Nat.flogBaseSNat"
    | [_,_,Right a, Right b] <- (map (runExcept . tyNatSize tcm) . Either.rights) args
    , Just c <- flogBase a b
    , let c' = toInteger c
    -> let (_,tyView -> TyConApp snatTcNm _) = splitFunForallTy ty
           (Just snatTc) = HashMap.lookup (nameOcc snatTcNm) tcm
           [snatDc] = tyConDataCons snatTc
       in  mkApps (Data snatDc) [ Right (LitTy (NumTy c'))
#if MIN_VERSION_ghc(8,2,0)
                                , Left (Literal (NaturalLiteral c'))]
#else
                                , Left (Literal (IntegerLiteral c'))]
#endif

  "CLaSH.Promoted.Nat.clogBaseSNat"
    | [_,_,Right a, Right b] <- (map (runExcept . tyNatSize tcm) . Either.rights) args
    , Just c <- clogBase a b
    , let c' = toInteger c
    -> let (_,tyView -> TyConApp snatTcNm _) = splitFunForallTy ty
           (Just snatTc) = HashMap.lookup (nameOcc snatTcNm) tcm
           [snatDc] = tyConDataCons snatTc
       in  mkApps (Data snatDc) [ Right (LitTy (NumTy c'))
#if MIN_VERSION_ghc(8,2,0)
                                , Left (Literal (NaturalLiteral c'))]
#else
                                , Left (Literal (IntegerLiteral c'))]
#endif

  "CLaSH.Promoted.Nat.logBaseSNat"
    | [_,Right a, Right b] <- (map (runExcept . tyNatSize tcm) . Either.rights) args
    , Just c <- flogBase a b
    , let c' = toInteger c
    -> let (_,tyView -> TyConApp snatTcNm _) = splitFunForallTy ty
           (Just snatTc) = HashMap.lookup (nameOcc snatTcNm) tcm
           [snatDc] = tyConDataCons snatTc
       in  mkApps (Data snatDc) [ Right (LitTy (NumTy c'))
#if MIN_VERSION_ghc(8,2,0)
                                , Left (Literal (NaturalLiteral c'))]
#else
                                , Left (Literal (IntegerLiteral c'))]
#endif

------------
-- BitVector
------------
-- Initialisation
  "CLaSH.Sized.Internal.BitVector.size#"
    | Just (_, kn) <- extractKnownNat tcm args
    -> let ty' = runFreshM (termType tcm e)
           (TyConApp intTcNm _) = tyView ty'
           (Just intTc) = HashMap.lookup (nameOcc intTcNm) tcm
           [intCon] = tyConDataCons intTc
       in  mkApps (Data intCon) [Left (Literal (IntLiteral kn))]
  "CLaSH.Sized.Internal.BitVector.maxIndex#"
    | Just (_, kn) <- extractKnownNat tcm args
    -> let ty' = runFreshM (termType tcm e)
           (TyConApp intTcNm _) = tyView ty'
           (Just intTc) = HashMap.lookup (nameOcc intTcNm) tcm
           [intCon] = tyConDataCons intTc
       in  mkApps (Data intCon) [Left (Literal (IntLiteral (kn-1)))]

-- Construction
  "CLaSH.Sized.Internal.BitVector.high"
    -> let resTyInfo = extractTySizeInfo tcm e
    in mkBitVectorLit' resTyInfo 1
  "CLaSH.Sized.Internal.BitVector.low"
    -> let resTyInfo = extractTySizeInfo tcm e
    in mkBitVectorLit' resTyInfo 0

-- Concatenation
  "CLaSH.Sized.Internal.BitVector.++#" -- :: KnownNat m => BitVector n -> BitVector m -> BitVector (n + m)
    | Just (_,m) <- extractKnownNat tcm args
    , [i,j] <- bitVectorLiterals' tcm isSubj args
    -> let val = i `shiftL` fromInteger m .|. j
           resTyInfo = extractTySizeInfo tcm e
    in mkBitVectorLit' resTyInfo val

-- Reduction
  "CLaSH.Sized.Internal.BitVector.reduceAnd#" -- :: KnownNat n => BitVector n -> BitVector 1
    | [i] <- bitVectorLiterals' tcm isSubj args
    , Just (_, kn) <- extractKnownNat tcm args
    -> let resTyInfo = extractTySizeInfo tcm e
           val = reifyNat kn (op (fromInteger i))
    in mkBitVectorLit' resTyInfo val
    where
      op :: KnownNat n => BitVector n -> Proxy n -> Integer
      op u _ = toInteger (BitVector.reduceAnd# u)
  "CLaSH.Sized.Internal.BitVector.reduceOr#" -- :: KnownNat n => BitVector n -> BitVector 1
    | [i] <- bitVectorLiterals' tcm isSubj args
    , Just (_, kn) <- extractKnownNat tcm args
    -> let resTyInfo = extractTySizeInfo tcm e
           val = reifyNat kn (op (fromInteger i))
    in mkBitVectorLit' resTyInfo val
    where
      op :: KnownNat n => BitVector n -> Proxy n -> Integer
      op u _ = toInteger (BitVector.reduceOr# u)
  "CLaSH.Sized.Internal.BitVector.reduceXor#" -- :: KnownNat n => BitVector n -> BitVector 1
    | [i] <- bitVectorLiterals' tcm isSubj args
    , Just (_, kn) <- extractKnownNat tcm args
    -> let resTyInfo = extractTySizeInfo tcm e
           val = reifyNat kn (op (fromInteger i))
    in mkBitVectorLit' resTyInfo val
    where
      op :: KnownNat n => BitVector n -> Proxy n -> Integer
      op u _ = toInteger (BitVector.reduceXor# u)


-- Indexing
  "CLaSH.Sized.Internal.BitVector.index#" -- :: KnownNat n => BitVector n -> Int -> Bit
    | Just (_,kn,i,j) <- bitVectorLitIntLit tcm isSubj args
      -> let resTyInfo = extractTySizeInfo tcm e
             val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkBitVectorLit' resTyInfo val
      where
        op :: KnownNat n => BitVector n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (BitVector.index# u i)
  "CLaSH.Sized.Internal.BitVector.replaceBit#" -- :: :: KnownNat n => BitVector n -> Int -> Bit -> BitVector n
    | (Right nTy : _ ) <- args
    , Right n <- runExcept (tyNatSize tcm nTy)
    , [ _
      , (collectArgs -> (Prim bvNm _ , [Right _, Left _, Left (Literal (IntegerLiteral bv)) ]))
      , (collectArgs -> (Prim _ _, [Left (Literal (IntLiteral i))] ))
      , (collectArgs -> (Prim bNm  _, [Right _, Left _, Left (Literal (IntegerLiteral b)) ]))
      ] <- reduceTerms tcm isSubj args
    , bvNm == "CLaSH.Sized.Internal.BitVector.fromInteger#"
    , bNm  == "CLaSH.Sized.Internal.BitVector.fromInteger#"
      -> let resTyInfo = extractTySizeInfo tcm e
             val = reifyNat n (op (fromInteger bv) (fromInteger i) (fromInteger b))
      in mkBitVectorLit' resTyInfo val
      where
        op :: KnownNat n => BitVector n -> Int -> Bit -> Proxy n -> Integer
        op bv i b _ = toInteger (BitVector.replaceBit# bv i b)
  "CLaSH.Sized.Internal.BitVector.setSlice#"
  -- :: BitVector (m + 1 + i) -> SNat m -> SNat n -> BitVector (m + 1 - n)
  -- -> BitVector (m + 1 + i)
    | (Right mTy : Right _ : Right nTy : _) <- args
    , Right m <- runExcept (tyNatSize tcm mTy)
    , Right n <- runExcept (tyNatSize tcm nTy)
    , [i,j] <- bitVectorLiterals' tcm isSubj args
    -> let val = BitVector.unsafeToInteger
               $ BitVector.setSlice# (BV i) (unsafeSNat m) (unsafeSNat n) (BV j)
           resTyInfo = extractTySizeInfo tcm e
       in  mkBitVectorLit' resTyInfo val
  "CLaSH.Sized.Internal.BitVector.slice#"
  -- :: BitVector (m + 1 + i) -> SNat m -> SNat n -> BitVector (m + 1 - n)
    | (Right mTy : Right _ : Right nTy : _) <- args
    , Right m <- runExcept (tyNatSize tcm mTy)
    , Right n <- runExcept (tyNatSize tcm nTy)
    , [i] <- bitVectorLiterals' tcm isSubj args
    -> let val = BitVector.unsafeToInteger
               $ BitVector.slice# (BV i) (unsafeSNat m) (unsafeSNat n)
           resTyInfo = extractTySizeInfo tcm e
       in  mkBitVectorLit' resTyInfo val
  "CLaSH.Sized.Internal.BitVector.split#" -- :: forall n m. KnownNat n => BitVector (m + n) -> (BitVector m, BitVector n)
    | (Right nTy : Right mTy : _) <- args
    , Right n <-  runExcept (tyNatSize tcm nTy)
    , Right m <-  runExcept (tyNatSize tcm mTy)
    , [i] <- bitVectorLiterals' tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp tupTcNm tyArgs) = tyView resTy
           (Just tupTc) = HashMap.lookup (nameOcc tupTcNm) tcm
           [tupDc] = tyConDataCons tupTc
           bvTy : _ = tyArgs
           valM = i `shiftR` fromInteger n
           valN = i .&. mask
           mask = bit (fromInteger n) - 1
    in mkApps (Data tupDc) (map Right tyArgs ++
                [ Left (mkBitVectorLit bvTy mTy m valM)
                , Left (mkBitVectorLit bvTy nTy n valN)])

  "CLaSH.Sized.Internal.BitVector.msb#" -- :: forall n. KnownNat n => BitVector n -> Bit
    | [i] <- bitVectorLiterals' tcm isSubj args
    , Just (_, kn) <- extractKnownNat tcm args
    -> let resTyInfo = extractTySizeInfo tcm e
           val = reifyNat kn (op (fromInteger i))
    in mkBitVectorLit' resTyInfo val
    where
      op :: KnownNat n => BitVector n -> Proxy n -> Integer
      op u _ = toInteger (BitVector.msb# u)
  "CLaSH.Sized.Internal.BitVector.lsb#" -- BitVector n -> Bit
    | [i] <- bitVectorLiterals' tcm isSubj args
    , Just (_, kn) <- extractKnownNat tcm args
    -> let resTyInfo = extractTySizeInfo tcm e
           val = reifyNat kn (op (fromInteger i))
    in mkBitVectorLit' resTyInfo val
    where
      op :: KnownNat n => BitVector n -> Proxy n -> Integer
      op u _ = toInteger (BitVector.lsb# u)


-- Eq
  "CLaSH.Sized.Internal.BitVector.eq#" | Just (i,j) <- bitVectorLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i == j)
  "CLaSH.Sized.Internal.BitVector.neq#" | Just (i,j) <- bitVectorLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i /= j)

-- Ord
  "CLaSH.Sized.Internal.BitVector.lt#" | Just (i,j) <- bitVectorLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i <  j)
  "CLaSH.Sized.Internal.BitVector.ge#" | Just (i,j) <- bitVectorLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >= j)
  "CLaSH.Sized.Internal.BitVector.gt#" | Just (i,j) <- bitVectorLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >  j)
  "CLaSH.Sized.Internal.BitVector.le#" | Just (i,j) <- bitVectorLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i <= j)

-- Bounded
  "CLaSH.Sized.Internal.BitVector.minBound#"
    | Just (nTy,len) <- extractKnownNat tcm args
    -> mkBitVectorLit ty nTy len 0
  "CLaSH.Sized.Internal.BitVector.maxBound#"
    | Just (litTy,mb) <- extractKnownNat tcm args
    -> let maxB = (2 ^ mb) - 1
       in  mkBitVectorLit ty litTy mb maxB

-- Num
  "CLaSH.Sized.Internal.BitVector.+#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftBitVector2 (BitVector.+#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.BitVector.-#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftBitVector2 (BitVector.-#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.BitVector.*#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftBitVector2 (BitVector.*#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.BitVector.negate#"
    | Just (nTy, kn) <- extractKnownNat tcm args
    , [i] <- bitVectorLiterals' tcm isSubj args
    -> let val = reifyNat kn (op (fromInteger i))
    in mkBitVectorLit ty nTy kn val
    where
      op :: KnownNat n => BitVector n -> Proxy n -> Integer
      op u _ = toInteger (BitVector.negate# u)

-- ExtendingNum
  "CLaSH.Sized.Internal.BitVector.plus#" -- :: BitVector m -> BitVector n -> BitVector (Max m n + 1)
    | Just (i,j) <- bitVectorLiterals tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
       in  mkBitVectorLit resTy resSizeTy resSizeInt (i+j)

  "CLaSH.Sized.Internal.BitVector.minus#"
    | [i,j] <- bitVectorLiterals' tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
           val = reifyNat resSizeInt (runSizedF (BitVector.-#) i j)
      in  mkBitVectorLit resTy resSizeTy resSizeInt val

  "CLaSH.Sized.Internal.BitVector.times#"
    | Just (i,j) <- bitVectorLiterals tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
       in  mkBitVectorLit resTy resSizeTy resSizeInt (i*j)

-- Integral
  "CLaSH.Sized.Internal.BitVector.quot#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftBitVector2 (BitVector.quot#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.BitVector.rem#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftBitVector2 (BitVector.rem#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.BitVector.toInteger#"
    | [collectArgs -> (Prim nm' _,[Right _, Left _, Left (Literal (IntegerLiteral i))])] <-
      (map (reduceConstant tcm isSubj) . Either.lefts) args
    , nm' == "CLaSH.Sized.Internal.BitVector.fromInteger#"
    -> integerToIntegerLiteral i

-- Bits
  "CLaSH.Sized.Internal.BitVector.and#"
    | Just (i,j) <- bitVectorLiterals tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkBitVectorLit ty nTy kn (i .&. j)
  "CLaSH.Sized.Internal.BitVector.or#"
    | Just (i,j) <- bitVectorLiterals tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkBitVectorLit ty nTy kn (i .|. j)
  "CLaSH.Sized.Internal.BitVector.xor#"
    | Just (i,j) <- bitVectorLiterals tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkBitVectorLit ty nTy kn (i `xor` j)

  "CLaSH.Sized.Internal.BitVector.complement#"
    | [i] <- bitVectorLiterals' tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> let val = reifyNat kn (op (fromInteger i))
    in mkBitVectorLit ty nTy kn val
    where
      op :: KnownNat n => BitVector n -> Proxy n -> Integer
      op u _ = toInteger (BitVector.complement# u)

  "CLaSH.Sized.Internal.BitVector.shiftL#"
    | Just (nTy,kn,i,j) <- bitVectorLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkBitVectorLit ty nTy kn val
      where
        op :: KnownNat n => BitVector n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (BitVector.shiftL# u i)
  "CLaSH.Sized.Internal.BitVector.shiftR#"
    | Just (nTy,kn,i,j) <- bitVectorLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkBitVectorLit ty nTy kn val
      where
        op :: KnownNat n => BitVector n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (BitVector.shiftR# u i)
  "CLaSH.Sized.Internal.BitVector.rotateL#"
    | Just (nTy,kn,i,j) <- bitVectorLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkBitVectorLit ty nTy kn val
      where
        op :: KnownNat n => BitVector n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (BitVector.rotateL# u i)
  "CLaSH.Sized.Internal.BitVector.rotateR#"
    | Just (nTy,kn,i,j) <- bitVectorLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkBitVectorLit ty nTy kn val
      where
        op :: KnownNat n => BitVector n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (BitVector.rotateR# u i)

-- Resize
  "CLaSH.Sized.Internal.BitVector.resize#" -- forall n m . KnownNat m => BitVector n -> BitVector m
    | (Right _ : Right mTy : _) <- args
    , Right km <- runExcept (tyNatSize tcm mTy)
    , [i] <- bitVectorLiterals' tcm isSubj args
    -> let bitsKeep = (bit (fromInteger km)) - 1
           val = i .&. bitsKeep
    in mkBitVectorLit ty mTy km val

--------
-- Index
--------
-- BitPack
  "CLaSH.Sized.Internal.Index.pack#"
    | (Right nTy : _) <- args
    , Right _ <- runExcept (tyNatSize tcm nTy)
    , [i] <- indexLiterals' tcm isSubj args
    -> let resTyInfo = extractTySizeInfo tcm e
       in  mkBitVectorLit' resTyInfo i
  "CLaSH.Sized.Internal.Index.unpack#"
    | Just (nTy,kn) <- extractKnownNat tcm args
    , [i] <- bitVectorLiterals' tcm isSubj args
    -> mkIndexLit ty nTy kn i

-- Eq
  "CLaSH.Sized.Internal.Index.eq#" | Just (i,j) <- indexLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i == j)
  "CLaSH.Sized.Internal.Index.neq#" | Just (i,j) <- indexLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i /= j)

-- Ord
  "CLaSH.Sized.Internal.Index.lt#"
    | Just (i,j) <- indexLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i < j)
  "CLaSH.Sized.Internal.Index.ge#"
    | Just (i,j) <- indexLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >= j)
  "CLaSH.Sized.Internal.Index.gt#"
    | Just (i,j) <- indexLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i > j)
  "CLaSH.Sized.Internal.Index.le#"
    | Just (i,j) <- indexLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i <= j)

-- Bounded
  "CLaSH.Sized.Internal.Index.maxBound#"
    | Just (nTy,mb) <- extractKnownNat tcm args
    -> mkIndexLit ty nTy mb (mb - 1)

-- Num
  "CLaSH.Sized.Internal.Index.+#"
    | Just (nTy,kn) <- extractKnownNat tcm args
    , [i,j] <- indexLiterals' tcm isSubj args
    -> mkIndexLit ty nTy kn (i + j)
  "CLaSH.Sized.Internal.Index.-#"
    | Just (nTy,kn) <- extractKnownNat tcm args
    , [i,j] <- indexLiterals' tcm isSubj args
    -> mkIndexLit ty nTy kn (i - j)
  "CLaSH.Sized.Internal.Index.*#"
    | Just (nTy,kn) <- extractKnownNat tcm args
    , [i,j] <- indexLiterals' tcm isSubj args
    -> mkIndexLit ty nTy kn (i * j)

-- ExtendingNum
  "CLaSH.Sized.Internal.Index.plus#"
    | (Right mTy : Right nTy : _) <- args
    , Right _ <- runExcept (tyNatSize tcm mTy)
    , Right _ <- runExcept (tyNatSize tcm nTy)
    , Just (i,j) <- indexLiterals tcm isSubj args
    -> let resTyInfo = extractTySizeInfo tcm e
       in  mkIndexLit' resTyInfo (i + j)
  "CLaSH.Sized.Internal.Index.minus#"
    | (Right mTy : Right nTy : _) <- args
    , Right _ <- runExcept (tyNatSize tcm mTy)
    , Right _ <- runExcept (tyNatSize tcm nTy)
    , Just (i,j) <- indexLiterals tcm isSubj args
    -> let resTyInfo = extractTySizeInfo tcm e
       in  mkIndexLit' resTyInfo (i - j)
  "CLaSH.Sized.Internal.Index.times#"
    | (Right mTy : Right nTy : _) <- args
    , Right _ <- runExcept (tyNatSize tcm mTy)
    , Right _ <- runExcept (tyNatSize tcm nTy)
    , Just (i,j) <- indexLiterals tcm isSubj args
    -> let resTyInfo = extractTySizeInfo tcm e
       in  mkIndexLit' resTyInfo (i * j)

-- Integral
  "CLaSH.Sized.Internal.Index.quot#"
    | Just (nTy,kn) <- extractKnownNat tcm args
    , Just (i,j) <- indexLiterals tcm isSubj args
    -> mkIndexLit ty nTy kn (i `quot` j)
  "CLaSH.Sized.Internal.Index.rem#"
    | Just (nTy,kn) <- extractKnownNat tcm args
    , Just (i,j) <- indexLiterals tcm isSubj args
    -> mkIndexLit ty nTy kn (i `rem` j)
  "CLaSH.Sized.Internal.Index.toInteger#"
    | [collectArgs -> (Prim nm' _,[Right _, Left _, Left (Literal (IntegerLiteral i))])] <-
      (map (reduceConstant tcm isSubj) . Either.lefts) args
    , nm' == "CLaSH.Sized.Internal.Index.fromInteger#"
    -> integerToIntegerLiteral i

-- Resize
  "CLaSH.Sized.Internal.Index.resize#"
    | Just (mTy,m) <- extractKnownNat tcm args
    , [i] <- indexLiterals' tcm isSubj args
    -> mkIndexLit ty mTy m i

---------
-- Signed
---------
  "CLaSH.Sized.Internal.Signed.size#"
    | Just (_, kn) <- extractKnownNat tcm args
    -> let ty' = runFreshM (termType tcm e)
           (TyConApp intTcNm _) = tyView ty'
           (Just intTc) = HashMap.lookup (nameOcc intTcNm) tcm
           [intCon] = tyConDataCons intTc
       in  mkApps (Data intCon) [Left (Literal (IntLiteral kn))]

-- BitPack
  "CLaSH.Sized.Internal.Signed.pack#"
    | Just (nTy, kn) <- extractKnownNat tcm args
    , [i] <- signedLiterals' tcm isSubj args
    -> mkBitVectorLit ty nTy kn i
  "CLaSH.Sized.Internal.Signed.unpack#"
    | Just (nTy, kn) <- extractKnownNat tcm args
    , [i] <- bitVectorLiterals' tcm isSubj args
    -> mkSignedLit ty nTy kn i

-- Eq
  "CLaSH.Sized.Internal.Signed.eq#" | Just (i,j) <- signedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i == j)
  "CLaSH.Sized.Internal.Signed.neq#" | Just (i,j) <- signedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i /= j)

-- Ord
  "CLaSH.Sized.Internal.Unsigned.lt#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i <  j)
  "CLaSH.Sized.Internal.Unsigned.ge#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >= j)
  "CLaSH.Sized.Internal.Unsigned.gt#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >  j)
  "CLaSH.Sized.Internal.Unsigned.le#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i <= j)

-- Bounded
  "CLaSH.Sized.Internal.Signed.minBound#"
    | Just (litTy,mb) <- extractKnownNat tcm args
    -> let minB = negate (2 ^ (mb - 1))
       in  mkSignedLit ty litTy mb minB
  "CLaSH.Sized.Internal.Signed.maxBound#"
    | Just (litTy,mb) <- extractKnownNat tcm args
    -> let maxB = (2 ^ (mb - 1)) - 1
       in mkSignedLit ty litTy mb maxB

-- Num
  "CLaSH.Sized.Internal.Signed.+#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftSigned2 (Signed.+#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Signed.-#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftSigned2 (Signed.-#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Signed.*#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftSigned2 (Signed.*#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Signed.negate#"
    | Just (nTy, kn) <- extractKnownNat tcm args
    , [i] <- signedLiterals' tcm isSubj args
    -> let val = reifyNat kn (op (fromInteger i))
    in mkSignedLit ty nTy kn val
    where
      op :: KnownNat n => Signed n -> Proxy n -> Integer
      op s _ = toInteger (Signed.negate# s)
  "CLaSH.Sized.Internal.Signed.abs#"
    | Just (nTy, kn) <- extractKnownNat tcm args
    , [i] <- signedLiterals' tcm isSubj args
    -> let val = reifyNat kn (op (fromInteger i))
    in mkSignedLit ty nTy kn val
    where
      op :: KnownNat n => Signed n -> Proxy n -> Integer
      op s _ = toInteger (Signed.abs# s)

-- ExtendingNum
  "CLaSH.Sized.Internal.Signed.plus#"
    | Just (i,j) <- signedLiterals tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
       in  mkSignedLit resTy resSizeTy resSizeInt (i+j)

  "CLaSH.Sized.Internal.Signed.minus#"
    | Just (i,j) <- signedLiterals tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
       in  mkSignedLit resTy resSizeTy resSizeInt (i-j)

  "CLaSH.Sized.Internal.Signed.times#"
    | Just (i,j) <- signedLiterals tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
       in  mkSignedLit resTy resSizeTy resSizeInt (i*j)

-- Integral
  "CLaSH.Sized.Internal.Signed.quot#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftSigned2 (Signed.quot#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Signed.rem#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftSigned2 (Signed.rem#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Signed.div#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftSigned2 (Signed.div#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Signed.mod#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftSigned2 (Signed.mod#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Signed.toInteger#"
    | [collectArgs -> (Prim nm' _,[Right _, Left _, Left (Literal (IntegerLiteral i))])] <-
      (map (reduceConstant tcm isSubj) . Either.lefts) args
    , nm' == "CLaSH.Sized.Internal.Signed.fromInteger#"
    -> integerToIntegerLiteral i

-- Bits
  "CLaSH.Sized.Internal.Signed.and#"
    | [i,j] <- signedLiterals' tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkSignedLit ty nTy kn (i .&. j)
  "CLaSH.Sized.Internal.Signed.or#"
    | [i,j] <- signedLiterals' tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkSignedLit ty nTy kn (i .|. j)
  "CLaSH.Sized.Internal.Signed.xor#"
    | [i,j] <- signedLiterals' tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkSignedLit ty nTy kn (i `xor` j)

  "CLaSH.Sized.Internal.Signed.complement#"
    | [i] <- signedLiterals' tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> let val = reifyNat kn (op (fromInteger i))
    in mkSignedLit ty nTy kn val
    where
      op :: KnownNat n => Signed n -> Proxy n -> Integer
      op u _ = toInteger (Signed.complement# u)

  "CLaSH.Sized.Internal.Signed.shiftL#"
    | Just (nTy,kn,i,j) <- signedLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkSignedLit ty nTy kn val
      where
        op :: KnownNat n => Signed n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (Signed.shiftL# u i)
  "CLaSH.Sized.Internal.Signed.shiftR#"
    | Just (nTy,kn,i,j) <- signedLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkSignedLit ty nTy kn val
      where
        op :: KnownNat n => Signed n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (Signed.shiftR# u i)
  "CLaSH.Sized.Internal.Signed.rotateL#"
    | Just (nTy,kn,i,j) <- signedLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkSignedLit ty nTy kn val
      where
        op :: KnownNat n => Signed n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (Signed.rotateL# u i)
  "CLaSH.Sized.Internal.Signed.rotateR#"
    | Just (nTy,kn,i,j) <- signedLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkSignedLit ty nTy kn val
      where
        op :: KnownNat n => Signed n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (Signed.rotateR# u i)

-- Resize
  "CLaSH.Sized.Internal.Signed.resize#" -- forall m n. (KnownNat n, KnownNat m) => Signed n -> Signed m
    | (Right mTy : Right nTy : _) <- args
    , Right mInt <- runExcept (tyNatSize tcm mTy)
    , Right nInt <- runExcept (tyNatSize tcm nTy)
    , [i] <- signedLiterals' tcm isSubj args
    -> let val | nInt <= mInt = extended
               | otherwise    = truncated
           extended  = i
           mask      = 1 `shiftL` fromInteger (mInt - 1)
           i'        = i `mod` mask
           truncated = if testBit i (fromInteger nInt - 1)
                          then (i' - mask)
                          else i'
       in mkSignedLit ty mTy mInt val
  "CLaSH.Sized.Internal.Signed.truncateB#" -- KnownNat m => Signed (m + n) -> Signed m
    | Just (mTy, km) <- extractKnownNat tcm args
    , [i] <- signedLiterals' tcm isSubj args
    -> let bitsKeep = (bit (fromInteger km)) - 1
           val = i .&. bitsKeep
    in mkSignedLit ty mTy km val

-- SaturatingNum
-- No need to manually evaluate CLaSH.Sized.Internal.Signed.minBoundSym#
-- It is just implemented in terms of other primitives.


-----------
-- Unsigned
-----------
  "CLaSH.Sized.Internal.Unsigned.size#"
    | Just (_, kn) <- extractKnownNat tcm args
    -> let ty' = runFreshM (termType tcm e)
           (TyConApp intTcNm _) = tyView ty'
           (Just intTc) = HashMap.lookup (nameOcc intTcNm) tcm
           [intCon] = tyConDataCons intTc
       in  mkApps (Data intCon) [Left (Literal (IntLiteral kn))]

-- BitPack
  "CLaSH.Sized.Internal.Unsigned.pack#"
    | Just (nTy, kn) <- extractKnownNat tcm args
    , [i] <- unsignedLiterals' tcm isSubj args
    -> mkBitVectorLit ty nTy kn i
  "CLaSH.Sized.Internal.Unsigned.unpack#"
    | Just (nTy, kn) <- extractKnownNat tcm args
    , [i] <- bitVectorLiterals' tcm isSubj args
    -> mkUnsignedLit ty nTy kn i

-- Eq
  "CLaSH.Sized.Internal.Unsigned.eq#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i == j)
  "CLaSH.Sized.Internal.Unsigned.neq#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i /= j)

-- Ord
  "CLaSH.Sized.Internal.Unsigned.lt#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i <  j)
  "CLaSH.Sized.Internal.Unsigned.ge#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >= j)
  "CLaSH.Sized.Internal.Unsigned.gt#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i >  j)
  "CLaSH.Sized.Internal.Unsigned.le#" | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> boolToBoolLiteral tcm ty (i <= j)

-- Bounded
  "CLaSH.Sized.Internal.Unsigned.minBound#"
    | Just (nTy,len) <- extractKnownNat tcm args
    -> mkUnsignedLit ty nTy len 0
  "CLaSH.Sized.Internal.Unsigned.maxBound#"
    | Just (litTy,mb) <- extractKnownNat tcm args
    -> let maxB = (2 ^ mb) - 1
       in  mkUnsignedLit ty litTy mb maxB

-- Num
  "CLaSH.Sized.Internal.Unsigned.+#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftUnsigned2 (Unsigned.+#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Unsigned.-#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftUnsigned2 (Unsigned.-#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Unsigned.*#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftUnsigned2 (Unsigned.*#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Unsigned.negate#"
    | Just (nTy, kn) <- extractKnownNat tcm args
    , [i] <- unsignedLiterals' tcm isSubj args
    -> let val = reifyNat kn (op (fromInteger i))
    in mkUnsignedLit ty nTy kn val
    where
      op :: KnownNat n => Unsigned n -> Proxy n -> Integer
      op u _ = toInteger (Unsigned.negate# u)

-- ExtendingNum
  "CLaSH.Sized.Internal.Unsigned.plus#" -- :: Unsigned m -> Unsigned n -> Unsigned (Max m n + 1)
    | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
       in  mkUnsignedLit resTy resSizeTy resSizeInt (i+j)

  "CLaSH.Sized.Internal.Unsigned.minus#"
    | [i,j] <- unsignedLiterals' tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
           val = reifyNat resSizeInt (runSizedF (Unsigned.-#) i j)
      in  mkUnsignedLit resTy resSizeTy resSizeInt val

  "CLaSH.Sized.Internal.Unsigned.times#"
    | Just (i,j) <- unsignedLiterals tcm isSubj args
    -> let resTy = runFreshM (termType tcm e)
           (TyConApp _ [resSizeTy]) = tyView resTy
           Right resSizeInt = runExcept (tyNatSize tcm resSizeTy)
       in  mkUnsignedLit resTy resSizeTy resSizeInt (i*j)

-- Integral
  "CLaSH.Sized.Internal.Unsigned.quot#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftUnsigned2 (Unsigned.quot#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Unsigned.rem#"
    | Just (_, kn) <- extractKnownNat tcm args
    , Just val <- reifyNat kn (liftUnsigned2 (Unsigned.rem#) ty tcm isSubj args)
    -> val
  "CLaSH.Sized.Internal.Unsigned.toInteger#"
    | [collectArgs -> (Prim nm' _,[Right _, Left _, Left (Literal (IntegerLiteral i))])] <-
      (map (reduceConstant tcm isSubj) . Either.lefts) args
    , nm' == "CLaSH.Sized.Internal.Unsigned.fromInteger#"
    -> integerToIntegerLiteral i

-- Bits
  "CLaSH.Sized.Internal.Unsigned.and#"
    | Just (i,j) <- unsignedLiterals tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkUnsignedLit ty nTy kn (i .&. j)
  "CLaSH.Sized.Internal.Unsigned.or#"
    | Just (i,j) <- unsignedLiterals tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkUnsignedLit ty nTy kn (i .|. j)
  "CLaSH.Sized.Internal.Unsigned.xor#"
    | Just (i,j) <- unsignedLiterals tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> mkUnsignedLit ty nTy kn (i `xor` j)

  "CLaSH.Sized.Internal.Unsigned.complement#"
    | [i] <- unsignedLiterals' tcm isSubj args
    , Just (nTy, kn) <- extractKnownNat tcm args
    -> let val = reifyNat kn (op (fromInteger i))
    in mkUnsignedLit ty nTy kn val
    where
      op :: KnownNat n => Unsigned n -> Proxy n -> Integer
      op u _ = toInteger (Unsigned.complement# u)

  "CLaSH.Sized.Internal.Unsigned.shiftL#" -- :: forall n. KnownNat n => Unsigned n -> Int -> Unsigned n
    | Just (nTy,kn,i,j) <- unsignedLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkUnsignedLit ty nTy kn val
      where
        op :: KnownNat n => Unsigned n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (Unsigned.shiftL# u i)
  "CLaSH.Sized.Internal.Unsigned.shiftR#" -- :: forall n. KnownNat n => Unsigned n -> Int -> Unsigned n
    | Just (nTy,kn,i,j) <- unsignedLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkUnsignedLit ty nTy kn val
      where
        op :: KnownNat n => Unsigned n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (Unsigned.shiftR# u i)
  "CLaSH.Sized.Internal.Unsigned.rotateL#" -- :: forall n. KnownNat n => Unsigned n -> Int -> Unsigned n
    | Just (nTy,kn,i,j) <- unsignedLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkUnsignedLit ty nTy kn val
      where
        op :: KnownNat n => Unsigned n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (Unsigned.rotateL# u i)
  "CLaSH.Sized.Internal.Unsigned.rotateR#" -- :: forall n. KnownNat n => Unsigned n -> Int -> Unsigned n
    | Just (nTy,kn,i,j) <- unsignedLitIntLit tcm isSubj args
      -> let val = reifyNat kn (op (fromInteger i) (fromInteger j))
      in mkUnsignedLit ty nTy kn val
      where
        op :: KnownNat n => Unsigned n -> Int -> Proxy n -> Integer
        op u i _ = toInteger (Unsigned.rotateR# u i)

-- Resize
  "CLaSH.Sized.Internal.Unsigned.resize#" -- forall n m . KnownNat m => Unsigned n -> Unsigned m
    | (Right _ : Right mTy : _) <- args
    , Right km <- runExcept (tyNatSize tcm mTy)
    , [i] <- unsignedLiterals' tcm isSubj args
    -> let bitsKeep = (bit (fromInteger km)) - 1
           val = i .&. bitsKeep
    in mkUnsignedLit ty mTy km val


  "CLaSH.Sized.RTree.treplicate"
    | isSubj
    , (TyConApp treeTcNm [lenTy,argTy]) <- tyView (runFreshM (termType tcm e))
    , Right len <- runExcept (tyNatSize tcm lenTy)
    -> let (Just treeTc) = HashMap.lookup (nameOcc treeTcNm) tcm
           [lrCon,brCon] = tyConDataCons treeTc
       in  mkRTree lrCon brCon argTy len (replicate (2^len) (last $ Either.lefts args))

---------
-- Vector
---------
  "CLaSH.Sized.Vector.length"
    | isSubj
    , [nTy, _] <- Either.rights args
    , Right n <-runExcept (tyNatSize tcm nTy)
    -> let ty' = runFreshM (termType tcm e)
           (TyConApp intTcNm _) = tyView ty'
           (Just intTc) = HashMap.lookup (nameOcc intTcNm) tcm
           [intCon] = tyConDataCons intTc
       in  mkApps (Data intCon) [Left (Literal (IntLiteral (toInteger n)))]

  "CLaSH.Sized.Vector.maxIndex"
    | isSubj
    , [nTy, _] <- Either.rights args
    , Right n <- runExcept (tyNatSize tcm nTy)
    -> let ty' = runFreshM (termType tcm e)
           (TyConApp intTcNm _) = tyView ty'
           (Just intTc) = HashMap.lookup (nameOcc intTcNm) tcm
           [intCon] = tyConDataCons intTc
       in  mkApps (Data intCon) [Left (Literal (IntLiteral (toInteger (n - 1))))]

-- Indexing
  "CLaSH.Sized.Vector.index_int"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.head"
    | isSubj
    , [(Data _,vArgs)] <- map collectArgs (reduceTerms tcm isSubj args)
    -> reduceConstant tcm isSubj (Either.lefts vArgs !! 1)
  "CLaSH.Sized.Vector.last"
    | isSubj
    , [(Data _,vArgs)] <- map collectArgs (reduceTerms tcm isSubj args)
    , (Right _ : Right aTy : Right nTy : _) <- vArgs
    , Right n <- runExcept (tyNatSize tcm nTy)
    -> if n == 0
          then reduceConstant tcm isSubj (Either.lefts vArgs !! 1)
          else reduceConstant tcm isSubj
                (mkApps (Prim nm ty) [Right (LitTy (NumTy (n-1)))
                                     ,Right aTy
                                     ,Left (Either.lefts vArgs !! 2)
                                     ])
-- - Sub-vectors
  "CLaSH.Sized.Vector.tail"
    | isSubj
    , [(Data _,vArgs)] <- map collectArgs (reduceTerms tcm isSubj args)
    -> reduceConstant tcm isSubj (Either.lefts vArgs !! 2)
  "CLaSH.Sized.Vector.init"
    | isSubj
    , [(Data consCon,vArgs)] <- map collectArgs (reduceTerms tcm isSubj args)
    , (Right _ : Right aTy : Right nTy : _) <- vArgs
    , Right n <- runExcept (tyNatSize tcm nTy)
    -> if n == 0
          then reduceConstant tcm isSubj (Either.lefts vArgs !! 2)
          else mkVecCons consCon aTy n
                  (Either.lefts vArgs !! 1)
                  (mkApps (Prim nm ty) [Right (LitTy (NumTy (n-1)))
                                       ,Right aTy
                                       ,Left (Either.lefts vArgs !! 2)])
  "CLaSH.Sized.Vector.select"
    | isSubj
    -> e
-- - Splitting
  "CLaSH.Sized.Vector.splitAt"
    | isSubj
    , (Data snatDc,(Right mTy:_)) <- collectArgs (reduceConstant tcm isSubj
                                                    (head (Either.lefts args)))
    , Right m <- runExcept (tyNatSize tcm mTy)
    -> let (_:Right nTy:Right aTy:_) = args
           -- Get the tuple data-constructor
           (_,tyView -> TyConApp tupTcNm tyArgs) = splitFunForallTy ty
           (Just tupTc)       = HashMap.lookup (nameOcc tupTcNm) tcm
           [tupDc]            = tyConDataCons tupTc
           -- Get the vector data-constructors
           TyConApp vecTcNm _ = tyView (head tyArgs)
           Just vecTc         = HashMap.lookup (nameOcc vecTcNm) tcm
           [nilCon,consCon]   = tyConDataCons vecTc
           -- Recursive call to @splitAt@
           splitAtRec v =
            mkApps (Prim nm ty)
                   [Right (LitTy (NumTy (m-1)))
                   ,args !! 1
                   ,args !! 2
                   ,Left (mkApps (Data snatDc)
                                 [ Right (LitTy (NumTy (m-1)))
                                 , Left  (Literal (NaturalLiteral (m-1)))])
                   ,Left v
                   ]
           -- Projection either the first or second field of the recursive
           -- call to @splitAt@
           splitAtSelR v = Case (splitAtRec v) (last tyArgs)
           m1VecTy = mkTyConApp vecTcNm [LitTy (NumTy (m-1)),aTy]
           nVecTy  = mkTyConApp vecTcNm [nTy,aTy]
           lNm     = string2SystemName "l"
           rNm     = string2SystemName "r"
           lId     = Id lNm (embed m1VecTy)
           rId     = Id rNm (embed nVecTy)
           tupPat  = (DataPat (embed tupDc) (rebind [] [lId,rId]))
           lAlt    = bind tupPat (Var m1VecTy lNm)
           rAlt    = bind tupPat (Var nVecTy rNm)

       in case m of
         -- (Nil,v)
         0 -> mkApps (Data tupDc) $ (map Right tyArgs) ++
                [ Left (mkVecNil nilCon aTy )
                , Left (last (Either.lefts args))
                ]
         -- (x:xs) <- v
         m' | (Data _,vArgs) <- collectArgs (reduceConstant tcm isSubj
                                               (last (Either.lefts args)))
            -- (x:fst (splitAt (m-1) xs),snd (splitAt (m-1) xs))
            -> mkApps (Data tupDc) $ (map Right tyArgs) ++
                 [ Left (mkVecCons consCon aTy m' (Either.lefts vArgs !! 1)
                           (splitAtSelR (Either.lefts vArgs !! 2) [lAlt]))
                 , Left (splitAtSelR (Either.lefts vArgs !! 2) [rAlt])
                 ]
         -- v doesn't reduce to a data-constructor
         _  -> e

  "CLaSH.Sized.Vector.unconcat"
    | isSubj
    -> e
-- Construction
-- - initialisation
  "CLaSH.Sized.Vector.replicate"
    | isSubj
    , (TyConApp vecTcNm [lenTy,argTy]) <- tyView (runFreshM (termType tcm e))
    , Right len <- runExcept (tyNatSize tcm lenTy)
    -> let (Just vecTc) = HashMap.lookup (nameOcc vecTcNm) tcm
           [nilCon,consCon] = tyConDataCons vecTc
       in  mkVec nilCon consCon argTy len (replicate (fromInteger len) (last $ Either.lefts args))
-- - Concatenation
  "CLaSH.Sized.Vector.++"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.concat"
    | isSubj
    -> e
-- Modifying vectors
  "CLaSH.Sized.Vector.replace_int"
    | isSubj
    -> e
-- - specialised permutations
  "CLaSH.Sized.Vector.reverse"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.transpose"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.rotateLeftS"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.rotateRightS"
    | isSubj
    -> e
-- Element-wise operations
-- - mapping
  "CLaSH.Sized.Vector.map"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.imap"
    | isSubj
    -> e
-- - Zipping
  "CLaSH.Sized.Vector.zipWith"
    | isSubj
    -> e
-- Folding
  "CLaSH.Sized.Vector.foldr"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.fold"
    | isSubj
    -> e
-- - Specialised folds
  "CLaSH.Sized.Vector.dfold"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.dtfold"
    | isSubj
    -> e
-- Misc
  "CLaSH.Sized.Vector.lazyV"
    | isSubj
    -> e
-- Traversable
  "CLaSH.Sized.Vector.traverse#"
    | isSubj
    -> e
-- BitPack
  "CLaSH.Sized.Vector.concatBitVector"
    | isSubj
    -> e
  "CLaSH.Sized.Vector.unconcatBitVector"
    | isSubj
    -> e
  _ -> e

reduceConstant _ _ e = e

reduceTerms :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> [Term]
reduceTerms tcm isSubj = map (reduceConstant tcm isSubj) . Either.lefts

integerLiterals :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Integer,Integer)
integerLiterals tcm isSubj args = case reduceTerms tcm isSubj args of
  [Literal (IntegerLiteral i), Literal (IntegerLiteral j)] -> Just (i,j)
  _ -> Nothing

intLiterals :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Integer,Integer)
intLiterals tcm isSubj args = case reduceTerms tcm isSubj args of
  [Literal (IntLiteral i), Literal (IntLiteral j)] -> Just (i,j)
  _ -> Nothing

intCLiterals :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Integer,Integer)
intCLiterals tcm isSubj args = case reduceTerms tcm isSubj args of
  ([collectArgs -> (Data _,[Left (Literal (IntLiteral i))])
   ,collectArgs -> (Data _,[Left (Literal (IntLiteral j))])])
    -> Just (i,j)
  _ -> Nothing

wordLiterals :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Integer,Integer)
wordLiterals tcm isSubj args = case (map (reduceConstant tcm isSubj) . Either.lefts) args of
  [Literal (WordLiteral i), Literal (WordLiteral j)] -> Just (i,j)
  _ -> Nothing

charLiterals :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Char,Char)
charLiterals tcm isSubj args = case (map (reduceConstant tcm isSubj) . Either.lefts) args of
  [Literal (CharLiteral i), Literal (CharLiteral j)] -> Just (i,j)
  _ -> Nothing

sizedLiterals :: Text -> HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Integer,Integer)
sizedLiterals szCon tcm isSubj args
  = case reduceTerms tcm isSubj args of
      ([ collectArgs -> (Prim nm  _,[Right _, Left _, Left (Literal (IntegerLiteral i))])
       , collectArgs -> (Prim nm' _,[Right _, Left _, Left (Literal (IntegerLiteral j))])])
        | nm  == szCon
        , nm' == szCon -> Just (i,j)
      _ -> Nothing

sizedLiterals' :: Text -> HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> [Integer]
sizedLiterals' szCon tcm isSubj args
  = catMaybes $ map (sizedLiteral szCon) $ reduceTerms tcm isSubj args

sizedLiteral :: Text -> Term -> Maybe Integer
sizedLiteral szCon term = case collectArgs term of
  (Prim nm  _,[Right _, Left _, Left (Literal (IntegerLiteral i))]) | nm == szCon -> Just i
  _ -> Nothing


bitVectorLiterals, indexLiterals, signedLiterals, unsignedLiterals
  :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Integer,Integer)
bitVectorLiterals = sizedLiterals "CLaSH.Sized.Internal.BitVector.fromInteger#"
indexLiterals     = sizedLiterals "CLaSH.Sized.Internal.Index.fromInteger#"
signedLiterals    = sizedLiterals "CLaSH.Sized.Internal.Signed.fromInteger#"
unsignedLiterals  = sizedLiterals "CLaSH.Sized.Internal.Unsigned.fromInteger#"

bitVectorLiterals', indexLiterals', signedLiterals', unsignedLiterals'
  :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> [Integer]
bitVectorLiterals' = sizedLiterals' "CLaSH.Sized.Internal.BitVector.fromInteger#"
indexLiterals'     = sizedLiterals' "CLaSH.Sized.Internal.Index.fromInteger#"
signedLiterals'    = sizedLiterals' "CLaSH.Sized.Internal.Signed.fromInteger#"
unsignedLiterals'  = sizedLiterals' "CLaSH.Sized.Internal.Unsigned.fromInteger#"



-- Tries to match literal arguments to a function like
--   (Unsigned.shiftL#  :: forall n. KnownNat n => Unsigned n -> Int -> Unsigned n)
sizedLitIntLit :: Text -> HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Type,Integer,Integer,Integer)
sizedLitIntLit szCon tcm isSubj args
  = case args of
      (Right nTy : _) | Right kn <- runExcept (tyNatSize tcm nTy)
                      , [ _
                        , (collectArgs -> (Prim nm _, [Right _, Left _, Left (Literal (IntegerLiteral i)) ]))
                        , (collectArgs -> (Prim _ _, [Left (Literal (IntLiteral j))] ))
                        ] <- reduceTerms tcm isSubj args
                      , nm == szCon
                      -> Just (nTy,kn,i,j)
      _ -> Nothing

bitVectorLitIntLit, signedLitIntLit, unsignedLitIntLit :: HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> Maybe (Type,Integer,Integer,Integer)
bitVectorLitIntLit = sizedLitIntLit "CLaSH.Sized.Internal.BitVector.fromInteger#"
signedLitIntLit    = sizedLitIntLit "CLaSH.Sized.Internal.Signed.fromInteger#"
unsignedLitIntLit  = sizedLitIntLit "CLaSH.Sized.Internal.Unsigned.fromInteger#"

-- From an argument list to function of type
--   forall n. KnownNat n => ...
-- extract (nTy,nInt)
-- where nTy is the Type of n
-- and   nInt is its value as an Integer
extractKnownNat :: HashMap.HashMap TyConOccName TyCon -> [Either a Type] -> Maybe (Type, Integer)
extractKnownNat tcm args = case args of
  (Right nTy : _) | Right nInt <- runExcept (tyNatSize tcm nTy)
    -> Just (nTy, nInt)
  _ -> Nothing

-- Construct a constant term of a sized type
mkSizedLit
  :: (Type -> Term)    -- type constructor?
  -> Type    -- result type
  -> Type    -- forall n.
  -> Integer -- KnownNat n
  -> Integer -- value
  -> Term
mkSizedLit conPrim ty nTy kn val
  = mkApps (conPrim sTy) [Right nTy,Left (Literal (NaturalLiteral kn)),Left (Literal (IntegerLiteral ( val)))]
  where
    (_,sTy) = splitFunForallTy ty

mkBitVectorLit, mkIndexLit, mkSignedLit, mkUnsignedLit
  :: Type    -- result type
  -> Type    -- forall n.
  -> Integer -- KnownNat n
  -> Integer -- value
  -> Term
mkBitVectorLit = mkSizedLit bvConPrim
mkIndexLit rTy nTy kn val
  | val >= 0
  , val < kn
  = mkSizedLit indexConPrim rTy nTy kn val
  | otherwise
  = mkApps (Prim "GHC.Err.undefined" undefinedTy) [Right rTy]
mkSignedLit    = mkSizedLit signedConPrim
mkUnsignedLit  = mkSizedLit unsignedConPrim

-- Construct a constant term of a sized type
mkSizedLit'
  :: (Type -> Term)    -- type constructor?
  -> (Type     -- result type
     ,Type     -- forall n.
     ,Integer) -- KnownNat n
  -> Integer -- value
  -> Term
mkSizedLit' conPrim (ty,nTy,kn) val
  = mkApps (conPrim sTy) [Right nTy,Left (Literal (NaturalLiteral kn)),Left (Literal (IntegerLiteral ( val)))]
  where
    (_,sTy) = splitFunForallTy ty

mkBitVectorLit', mkIndexLit', mkSignedLit', mkUnsignedLit'
  :: (Type     -- result type
     ,Type     -- forall n.
     ,Integer) -- KnownNat n
  -> Integer -- value
  -> Term
mkBitVectorLit' = mkSizedLit' bvConPrim
mkIndexLit' res@(rTy,_,kn) val
  | val >= 0
  , val < kn
  = mkSizedLit' indexConPrim res val
  | otherwise
  = mkApps (Prim "GHC.Err.undefined" undefinedTy) [Right rTy]
mkSignedLit'    = mkSizedLit' signedConPrim
mkUnsignedLit'  = mkSizedLit' unsignedConPrim

-- | Create a vector of supplied elements
mkVecCons
  :: DataCon -- ^ The Cons (:>) constructor
  -> Type    -- ^ Element type
  -> Integer -- ^ Length of the vector
  -> Term    -- ^ head of the vector
  -> Term    -- ^ tail of the vector
  -> Term
mkVecCons consCon resTy n h t =
  mkApps (Data consCon) [Right (LitTy (NumTy n))
                        ,Right resTy
                        ,Right (LitTy (NumTy (n-1)))
                        ,Left (Prim "_CO_" consCoTy)
                        ,Left h
                        ,Left t]

  where
    args = dataConInstArgTys consCon [LitTy (NumTy n),resTy,LitTy (NumTy (n-1))]
    Just (consCoTy : _) = args

-- | Create an empty vector
mkVecNil
  :: DataCon
  -- ^ The Nil constructor
  -> Type
  -- ^ The element type
  -> Term
mkVecNil nilCon resTy =
  mkApps (Data nilCon) [Right (LitTy (NumTy 0))
                       ,Right resTy
                       ,Left  (Prim "_CO_" nilCoTy)
                       ]
  where
    args = dataConInstArgTys nilCon [LitTy (NumTy 0),resTy]
    Just (nilCoTy : _ ) = args

boolToIntLiteral :: Bool -> Term
boolToIntLiteral b = if b then Literal (IntLiteral 1) else Literal (IntLiteral 0)

boolToBoolLiteral :: HashMap.HashMap TyConOccName TyCon -> Type -> Bool -> Term
boolToBoolLiteral tcm ty b =
 let (_,tyView -> TyConApp boolTcNm []) = splitFunForallTy ty
     (Just boolTc) = HashMap.lookup (nameOcc boolTcNm) tcm
     [falseDc,trueDc] = tyConDataCons boolTc
     retDc = if b then trueDc else falseDc
 in  Data retDc

integerToIntLiteral :: Integer -> Term
integerToIntLiteral = Literal . IntLiteral . toInteger . (fromInteger :: Integer -> Int) -- for overflow behaviour

integerToWordLiteral :: Integer -> Term
integerToWordLiteral = Literal . WordLiteral . toInteger . (fromInteger :: Integer -> Word) -- for overflow behaviour

integerToIntegerLiteral :: Integer -> Term
integerToIntegerLiteral = Literal . IntegerLiteral

bvConPrim :: Type -> Term
bvConPrim (tyView -> TyConApp bvTcNm _)
  = Prim "CLaSH.Sized.Internal.BitVector.fromInteger#" (ForAllTy (bind nTV funTy))
  where
#if MIN_VERSION_ghc(8,2,0)
    funTy        = foldr1 mkFunTy [naturalPrimTy,integerPrimTy,mkTyConApp bvTcNm [nVar]]
#else
    funTy        = foldr1 mkFunTy [integerPrimTy,integerPrimTy,mkTyConApp bvTcNm [nVar]]
#endif
    nName      = string2SystemName "n"
    nVar       = VarTy typeNatKind nName
    nTV        = TyVar nName (embed typeNatKind)
bvConPrim _ = error $ $(curLoc) ++ "called with incorrect type"

indexConPrim :: Type -> Term
indexConPrim (tyView -> TyConApp indexTcNm _)
  = Prim "CLaSH.Sized.Internal.Index.fromInteger#" (ForAllTy (bind nTV funTy))
  where
#if MIN_VERSION_ghc(8,2,0)
    funTy        = foldr1 mkFunTy [naturalPrimTy,integerPrimTy,mkTyConApp indexTcNm [nVar]]
#else
    funTy        = foldr1 mkFunTy [integerPrimTy,integerPrimTy,mkTyConApp indexTcNm [nVar]]
#endif
    nName      = string2SystemName "n"
    nVar       = VarTy typeNatKind nName
    nTV        = TyVar nName (embed typeNatKind)
indexConPrim _ = error $ $(curLoc) ++ "called with incorrect type"

signedConPrim :: Type -> Term
signedConPrim (tyView -> TyConApp signedTcNm _)
  = Prim "CLaSH.Sized.Internal.Signed.fromInteger#" (ForAllTy (bind nTV funTy))
  where
#if MIN_VERSION_ghc(8,2,0)
    funTy        = foldr1 mkFunTy [naturalPrimTy,integerPrimTy,mkTyConApp signedTcNm [nVar]]
#else
    funTy        = foldr1 mkFunTy [integerPrimTy,integerPrimTy,mkTyConApp signedTcNm [nVar]]
#endif
    nName      = string2SystemName "n"
    nVar       = VarTy typeNatKind nName
    nTV        = TyVar nName (embed typeNatKind)
signedConPrim _ = error $ $(curLoc) ++ "called with incorrect type"

unsignedConPrim :: Type -> Term
unsignedConPrim (tyView -> TyConApp unsignedTcNm _)
  = Prim "CLaSH.Sized.Internal.Unsigned.fromInteger#" (ForAllTy (bind nTV funTy))
  where
#if MIN_VERSION_ghc(8,2,0)
    funTy        = foldr1 mkFunTy [naturalPrimTy,integerPrimTy,mkTyConApp unsignedTcNm [nVar]]
#else
    funTy        = foldr1 mkFunTy [integerPrimTy,integerPrimTy,mkTyConApp unsignedTcNm [nVar]]
#endif
    nName        = string2SystemName "n"
    nVar         = VarTy typeNatKind nName
    nTV          = TyVar nName (embed typeNatKind)
unsignedConPrim _ = error $ $(curLoc) ++ "called with incorrect type"


-- |  Lift a binary function over 'Unsigned' values to be used as literal Evaluator
--
--
liftUnsigned2 :: KnownNat n
              => (Unsigned n -> Unsigned n -> Unsigned n)
              -> Type
              -> HashMap.HashMap TyConOccName TyCon
              -> Bool
              -> [Either Term Type]
              -> (Proxy n -> Maybe Term)
liftUnsigned2 = liftSized2 unsignedLiterals' mkUnsignedLit

liftSigned2 :: KnownNat n
              => (Signed n -> Signed n -> Signed n)
              -> Type
              -> HashMap.HashMap TyConOccName TyCon
              -> Bool
              -> [Either Term Type]
              -> (Proxy n -> Maybe Term)
liftSigned2 = liftSized2 signedLiterals' mkSignedLit

liftBitVector2 :: KnownNat n
              => (BitVector n -> BitVector n -> BitVector n)
              -> Type
              -> HashMap.HashMap TyConOccName TyCon
              -> Bool
              -> [Either Term Type]
              -> (Proxy n -> Maybe Term)
liftBitVector2 = liftSized2 bitVectorLiterals' mkBitVectorLit

liftSized2 :: (KnownNat n, Integral (sized n))
           => -- | literal argument extraction function
              (HashMap.HashMap TyConOccName TyCon -> Bool -> [Either Term Type] -> [Integer])
           -> -- | literal contruction function
              (Type -> Type -> Integer -> Integer -> Term)
           -> (sized n -> sized n -> sized n)
           -> Type
           -> HashMap.HashMap TyConOccName TyCon
           -> Bool
           -> [Either Term Type]
           -> (Proxy n -> Maybe Term)
liftSized2 extractLitArgs mkLit f ty tcm isSubj args p
  | Just (nTy, kn) <- extractKnownNat tcm args
  , [i,j] <- extractLitArgs tcm isSubj args
  = let val = runSizedF f i j p
    in Just $ mkLit ty nTy kn val
  | otherwise = Nothing

-- | Helper to run a function over sized types on integers
--
-- This only works on function of type (sized n -> sized n -> sized n)
-- The resulting function must be executed with reifyNat
runSizedF
  :: (KnownNat n, Integral (sized n))
  => (sized n -> sized n -> sized n)   -- ^ function to run
  -> Integer                           -- ^ first  argument
  -> Integer                           -- ^ second argument
  -> (Proxy n -> Integer)
runSizedF f i j _ = toInteger $ f (fromInteger i) (fromInteger j)

extractTySizeInfo :: HashMap.HashMap TyConOccName TyCon -> Term -> (Type, Type, Integer)
extractTySizeInfo tcm e = (resTy,resSizeTy,resSize)
  where
    resTy = runFreshM (termType tcm e)
    (TyConApp _ [resSizeTy]) = tyView resTy
    Right resSize = runExcept (tyNatSize tcm resSizeTy)
