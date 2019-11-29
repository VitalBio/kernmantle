{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}

-- | A 'Rope' connects together various effect 'Strand's that get interlaced
-- together.
--
-- A 'Strand' is an effet with a parameter and an output. No constraint are
-- placed on the 'Strand', but once combined in a 'Rope', that 'Rope' will be
-- an 'Arrow' and a 'Profunctor'. 'Strand's in a 'Rope' are named via labels to
-- limit ambiguity.
--
-- An action that targets some 'Strand' can be lifted to a 'Rope' that contains
-- that 'Strand' with the 'strand' function.

module Control.Kernmantle.Rope
  ( Product(..)
  , Tannen(..)
  , Kleisli(..)
  , Rope(..)
  , TightRope, LooseRope
  , BinEff, Strand, UStrand, RopeRec
  , StrandName, StrandEff
  , Weaver(..)
  , InRope(..), Entwines, EntwinesU
  , Label, fromLabel
  , FromUnary
  , type (~>)
  , (&)

  , strandU, strandU_
  , tighten, loosen
  , entwine, entwineU
  , retwine
  , untwine, untwineU
  , mergeStrands
  , asCore, asCoreU
  )
where

import Control.Category
import Control.Arrow

import Control.Monad.Reader
import Data.Bifunctor
import Data.Bifunctor.Tannen
import Data.Bifunctor.Product
import Data.Profunctor
import Data.Profunctor.Cayley
import Data.Function ((&))
import Data.Functor.Identity
import Data.Typeable
import Data.Vinyl hiding ((<+>))
import Data.Vinyl.ARec
import Data.Vinyl.TypeLevel
import GHC.Exts
import GHC.TypeLits
import GHC.OverloadedLabels

import Prelude hiding (id, (.))


-- | The kind for all binary effects. First param is usually an input
-- (contravariant) of the effect and second one an output (covariant).
type BinEff = * -> * -> *

-- | The kind for unary effects
type UEff = * -> *

-- | The kind for a named binary effect. Must remain a tuple because that's what
-- vinyl expects.
type Strand = (Symbol, BinEff)

-- | The kind for a named unary effect
type UStrand = (Symbol, UEff)

type family StrandName t where
  StrandName '(name, eff) = name

type family StrandEff t where
  StrandEff '(name, eff) = eff

-- | The kind for records that will contain 'Weaver's. First type param will
-- most often be @Weaver someCore@
type RopeRec = (Strand -> *) -> [Strand] -> *

-- | A natural transformation on type constructors of two arguments.
type f ~> g = forall x y. f x y -> g x y

-- | Runs one "mantle" strand (* -> * -> * effect) in a "core" strand. Is
-- parameterized over a Strand even if it ignores its name internally
-- because that's what is expect by the 'RopeRec'
newtype Weaver (core::BinEff) (strand::Strand) = Weaver
  { weaveStrand :: StrandEff strand ~> core }

-- | 'Rope' is a free arrow built out of _several_ binary effects
-- (ie. effects with kind * -> * -> *). These effects are called 'Strand's, they
-- compose the @mantle@, and they can be interlaced "on top" of an existing
-- @core@ effect.
newtype Rope (record::RopeRec) (mantle::[Strand]) (core::BinEff) a b =
  Rope
    { runRope :: record (Weaver core) mantle -> core a b }
  
  deriving (Category, Arrow, ArrowChoice, ArrowLoop, ArrowZero, ArrowPlus
           ,Bifunctor)
    via Reader (record (Weaver core) mantle) `Tannen` core

  deriving (Profunctor, Strong, Choice)
    via Reader (record (Weaver core) mantle) `Cayley` core

-- | A 'Rope' over any core that satisfies some constraints.
--
-- NOTE: Given @core@ is maintained universally quantified, a 'Rope' created
-- this way corresponds to the final encoding of the free arrow construction.
type UniRope cst record mantle a b =
  forall core. (cst core) => Rope record mantle core a b

-- | A 'Rope' that is "tight", meaning you cannot 'entwine' new 'Strand's to
-- it. The 'strand' function is @O(1)@ on 'TightRope's whatever the number of
-- 'Strand's.
type TightRope = Rope ARec

-- | A 'Rope' that is "loose", meaning you can 'entwine' new 'Strand's to
-- it. The 'strand' function is @O(n)@ on 'LooseRope's, @n@ being the number of
-- 'Strand's.
type LooseRope = Rope Rec

class InRope l eff rope where
  -- | Lifts a binary effect in the 'Rope'. Performance should be better with a
  -- 'TightRope' than with a 'LooseRope', unless you have very few 'Strand's.
  strand :: Label l -> eff a b -> rope a b

instance ( HasField record l mantle mantle eff eff
         , RecElemFCtx record (Weaver core) )
  => InRope l eff (Rope record mantle core) where
  strand l eff = Rope $ \r -> weaveStrand (rgetf l r) eff
  {-# INLINE strand #-}

-- | Turns a unary effect into a binary one
type FromUnary = Kleisli

-- | Lifts a unary effect in the 'Rope'
strandU :: (InRope l (Kleisli ueff) rope)
        => Label l -> (a -> ueff b) -> rope a b
strandU l = strand l . Kleisli
{-# INLINE strandU #-}

-- | Lifts a unary effect expecting no input in the 'Rope'
strandU_ :: (InRope l (FromUnary ueff) rope)
         => Label l -> ueff b -> rope () b
strandU_ l = strandU l . const
{-# INLINE strandU_ #-}

-- | Tells whether a collection of @strands@ is in a 'Rope'
type family rope `Entwines` (strands::[Strand]) :: Constraint where
  rope `Entwines` '[] = ()
  rope `Entwines` ('(name, eff) ': strands ) = ( InRope name eff rope
                                               , rope `Entwines` strands )

-- | Tells whether a collection of unary strands is in a 'Rope'
type family rope `EntwinesU` (ustrands::[UStrand]) :: Constraint where
  rope `EntwinesU` '[] = ()
  rope `EntwinesU` ('(name, eff) ': strands ) = ( InRope name (FromUnary eff) rope
                                                , rope `EntwinesU` strands )

-- | Turn a 'LooseRope' into a 'TightRope'
tighten :: (RecApplicative m, RPureConstrained (IndexableField m) m)
        => LooseRope m core a b -> TightRope m core a b
tighten (Rope f) = Rope $ f . fromARec
{-# INLINE tighten #-}

-- | Turn a 'TightRope' into a 'LooseRope'
loosen :: (NatToInt (RLength m))
       => TightRope m core a b -> LooseRope m core a b
loosen (Rope f) = Rope $ f . toARec
{-# INLINE loosen #-}

-- | Adds a new effect strand in the 'Rope'. Users of that function should
-- normally not place constraints on the core or instanciate it. Rather,
-- requirement of the execution function should be expressed in terms of other
-- effects of the @mantle@.
entwine :: Label name  -- ^ Give a name to the strand
        -> (binEff ~> LooseRope mantle core) -- ^ The execution function
        -> LooseRope ('(name,binEff) ': mantle) core a b -- ^ The 'Rope' with an extra effect strand
        -> LooseRope mantle core a b -- ^ The rope with the extra effect strand
                                     -- woven in the core
entwine _ run (Rope f) = Rope $ \r ->
  f (Weaver (\eff -> runRope (run eff) r) :& r)
{-# INLINE entwine #-}

-- | 'entwine' a unary effect in the 'Rope'
entwineU :: Label name  -- ^ Give a name to the strand
         -> (forall x y. (x -> ueff y) -> LooseRope mantle core x y) -- ^ The execution function
         -> LooseRope ('(name,FromUnary ueff) ': mantle) core a b -- ^ The 'Rope' with an extra effect strand
         -> LooseRope mantle core a b -- ^ The rope with the extra effect strand
                                      -- woven in the core
entwineU l run = entwine l $ run . runKleisli
{-# INLINE entwineU #-}

-- | Runs an effect directly in the core. You should use that function only as
-- part of a call to 'entwine'.
asCore :: core x y -> Rope r mantle core x y
asCore = Rope . const

-- | Runs a unary effect directly in the core. You should use that function only
-- as part of a call to 'entwine'.
asCoreU :: (x -> core y) -> Rope r mantle (FromUnary core) x y
asCoreU = asCore . Kleisli

-- | Reorders the strands to match some external context. @strands'@ can contain
-- more elements than @strands@. Note it works on both 'TightRope's and
-- 'LooseRope's
retwine :: (RecSubset r strands strands' (RImage strands strands'), RecSubsetFCtx r (Weaver core))
        => Rope r strands core a b
        -> Rope r strands' core a b
retwine (Rope f) = Rope $ f . rcast
{-# INLINE retwine #-}

-- | Merge two strands that have the same effect type. Keeps the first name.
mergeStrands :: Label n1
             -> Label n2
             -> LooseRope ( '(n1,binEff) ': '(n2,binEff) ': mantle ) core a b
             -> LooseRope ( '(n1,binEff) ': mantle ) core a b
mergeStrands _ _ (Rope f) = Rope $ \(r@(Weaver w) :& rest) ->
  f (r :& Weaver w :& rest)
{-# INLINE mergeStrands #-}

-- | Runs a 'Rope' with no strands inside its core strand
untwine :: LooseRope '[] core a b -> core a b
untwine (Rope f) = f RNil
{-# INLINE untwine #-}

untwineU :: LooseRope '[] (FromUnary ueff) a b -> a -> ueff b
untwineU = runKleisli . untwine
{-# INLINE untwineU #-}
