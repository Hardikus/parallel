{-# OPTIONS -fno-implicit-prelude #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Typeable
-- Copyright   :  (c) The University of Glasgow, CWI 2001--2004
-- License     :  BSD-style (see the file libraries/base/LICENSE)
-- 
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- The Typeable class reifies types to some extent by associating type
-- representations to types. These type representations can be compared,
-- and one can in turn define a type-safe cast operation. To this end,
-- an unsafe cast is guarded by a test for type (representation)
-- equivalence. The module Data.Dynamic uses Typeable for an
-- implementation of dynamics. The module Data.Generics uses Typeable
-- and type-safe cast (but not dynamics) to support the \"Scrap your
-- boilerplate\" style of generic programming.
--
-----------------------------------------------------------------------------

module Data.Typeable
  (

	-- * The Typeable class
	Typeable( typeOf ),	-- :: a -> TypeRep

	-- * Type-safe cast
	cast,			-- :: (Typeable a, Typeable b) => a -> Maybe b
	gcast,			-- a generalisation of cast

	-- * Type representations
	TypeRep,	-- abstract, instance of: Eq, Show, Typeable
	TyCon,		-- abstract, instance of: Eq, Show, Typeable

	-- * Construction of type representations
	mkTyCon,	-- :: String  -> TyCon
	mkAppTy,	-- :: TyCon   -> [TypeRep] -> TypeRep
	mkFunTy,	-- :: TypeRep -> TypeRep   -> TypeRep
	applyTy,	-- :: TypeRep -> TypeRep   -> Maybe TypeRep
	popStarTy,	-- :: TypeRep -> TypeRep   -> TypeRep

	-- * Observation of type representations
	typerepTyCon,	-- :: TypeRep -> TyCon
	typerepArgs,	-- :: TypeRep -> [TypeRep]
	tyconString,	-- :: TyCon   -> String

	-- * The other Typeable classes
	Typeable1( typeOf1 ),	-- :: t a -> TypeRep
	Typeable2( typeOf2 ),	-- :: t a b -> TypeRep
	Typeable3( typeOf3 ),	-- :: t a b c -> TypeRep
	Typeable4( typeOf4 ),	-- :: t a b c d -> TypeRep
	Typeable5( typeOf5 ),	-- :: t a b c d e -> TypeRep
	Typeable6( typeOf6 ),	-- :: t a b c d e f -> TypeRep
	Typeable7( typeOf7 ),	-- :: t a b c d e f g -> TypeRep
	gcast1,			-- :: ... => c (t a) -> Maybe (c (t' a))
	gcast2,			-- :: ... => c (t a b) -> Maybe (c (t' a b))

	-- * Default instances
	typeOfDefault,	-- :: (Typeable1 t, Typeable a) => t a -> TypeRep
	typeOf1Default,	-- :: (Typeable2 t, Typeable a) => t a b -> TypeRep
	typeOf2Default,	-- :: (Typeable2 t, Typeable a) => t a b c -> TypeRep
	typeOf3Default,	-- :: (Typeable2 t, Typeable a) => t a b c d -> TypeRep
	typeOf4Default,	-- :: (Typeable2 t, Typeable a) => t a b c d e -> TypeRep
	typeOf5Default,	-- :: (Typeable2 t, Typeable a) => t a b c d e f -> TypeRep
	typeOf6Default	-- :: (Typeable2 t, Typeable a) => t a b c d e f g -> TypeRep

  ) where


import qualified Data.HashTable as HT
import Data.Maybe
import Data.Either
import Data.Int
import Data.Word
import Data.List( foldl )

#ifdef __GLASGOW_HASKELL__
import GHC.Base
import GHC.Show
import GHC.Err
import GHC.Num
import GHC.Float
import GHC.Real( rem, Ratio )
import GHC.IOBase
import GHC.Ptr          -- So we can give Typeable instance for Ptr
import GHC.Stable       -- So we can give Typeable instance for StablePtr
#endif

#ifdef __HUGS__
import Hugs.Prelude
import Hugs.IO
import Hugs.IORef
import Hugs.IOExts
#endif

#ifdef __GLASGOW_HASKELL__
unsafeCoerce :: a -> b
unsafeCoerce = unsafeCoerce#
#endif

#ifdef __NHC__
import NonStdUnsafeCoerce (unsafeCoerce)
import NHC.IOExtras (IORef,newIORef,readIORef,writeIORef,unsafePerformIO)
#else
#include "Typeable.h"
#endif


#ifndef __HUGS__

-------------------------------------------------------------
--
--		Type representations
--
-------------------------------------------------------------


-- | A concrete representation of a (monomorphic) type.  'TypeRep'
-- supports reasonably efficient equality.
data TypeRep = TypeRep !Key TyCon [TypeRep] 

-- Compare keys for equality
instance Eq TypeRep where
  (TypeRep k1 _ _) == (TypeRep k2 _ _) = k1 == k2

-- | An abstract representation of a type constructor.  'TyCon' objects can
-- be built using 'mkTyCon'.
data TyCon = TyCon !Key String

instance Eq TyCon where
  (TyCon t1 _) == (TyCon t2 _) = t1 == t2

#endif

	-- 
	-- let fTy = mkTyCon "Foo" in show (mkAppTy (mkTyCon ",,")
	--                                 [fTy,fTy,fTy])
	-- 
	-- returns "(Foo,Foo,Foo)"
	--
	-- The TypeRep Show instance promises to print tuple types
	-- correctly. Tuple type constructors are specified by a 
	-- sequence of commas, e.g., (mkTyCon ",,,,") returns
	-- the 5-tuple tycon.


----------------- Construction --------------------

-- | Applies a type constructor to a sequence of types
mkAppTy  :: TyCon -> [TypeRep] -> TypeRep
mkAppTy tc@(TyCon tc_k _) args 
  = TypeRep (appKeys tc_k arg_ks) tc args
  where
    arg_ks = [k | TypeRep k _ _ <- args]


-- | A special case of 'mkAppTy', which applies the function 
-- type constructor to a pair of types.
mkFunTy  :: TypeRep -> TypeRep -> TypeRep
mkFunTy f a = mkAppTy funTc [f,a]


-- | Applies a type to a function type.  Returns: @'Just' u@ if the
-- first argument represents a function of type @t -> u@ and the
-- second argument represents a function of type @t@.  Otherwise,
-- returns 'Nothing'.
applyTy :: TypeRep -> TypeRep -> Maybe TypeRep
applyTy (TypeRep _ tc [t1,t2]) t3
  | tc == funTc && t1 == t3	= Just t2
applyTy _ _     		= Nothing


-- | Adds a TypeRep argument to a TypeRep.
popStarTy :: TypeRep -> TypeRep -> TypeRep
popStarTy (TypeRep tr_k tc trs) arg_tr
  = let (TypeRep arg_k _ _) = arg_tr
     in  TypeRep (appKey tr_k arg_k) tc (trs++[arg_tr])


-- If we enforce the restriction that there is only one
-- @TyCon@ for a type & it is shared among all its uses,
-- we can map them onto Ints very simply. The benefit is,
-- of course, that @TyCon@s can then be compared efficiently.

-- Provided the implementor of other @Typeable@ instances
-- takes care of making all the @TyCon@s CAFs (toplevel constants),
-- this will work. 

-- If this constraint does turn out to be a sore thumb, changing
-- the Eq instance for TyCons is trivial.

-- | Builds a 'TyCon' object representing a type constructor.  An
-- implementation of "Data.Typeable" should ensure that the following holds:
--
-- >  mkTyCon "a" == mkTyCon "a"
--

mkTyCon :: String	-- ^ the name of the type constructor (should be unique
			-- in the program, so it might be wise to use the
			-- fully qualified name).
	-> TyCon	-- ^ A unique 'TyCon' object
mkTyCon str = TyCon (mkTyConKey str) str



----------------- Observation ---------------------


-- | Observe the type constructor of a type representation
typerepTyCon :: TypeRep -> TyCon
typerepTyCon (TypeRep _ tc _) = tc


-- | Observe the argument types of a type representation
typerepArgs :: TypeRep -> [TypeRep]
typerepArgs (TypeRep _ _ args) = args


-- | Observe string encoding of a type representation
tyconString :: TyCon   -> String
tyconString  (TyCon _ str) = str


----------------- Showing TypeReps --------------------

instance Show TypeRep where
  showsPrec p (TypeRep _ tycon tys) =
    case tys of
      [] -> showsPrec p tycon
      [x]   | tycon == listTc -> showChar '[' . shows x . showChar ']'
      [a,r] | tycon == funTc  -> showParen (p > 8) $
			         showsPrec 9 a .
                                 showString " -> " .
                                 showsPrec 8 r
      xs | isTupleTyCon tycon -> showTuple tycon xs
	 | otherwise	     ->
	    showParen (p > 9) $
   	    showsPrec p tycon . 
	    showChar ' '      . 
	    showArgs tys

instance Show TyCon where
  showsPrec _ (TyCon _ s) = showString s

isTupleTyCon :: TyCon -> Bool
isTupleTyCon (TyCon _ (',':_)) = True
isTupleTyCon _		       = False


-- Some (Show.TypeRep) helpers:

showArgs :: Show a => [a] -> ShowS
showArgs [] = id
showArgs [a] = showsPrec 10 a
showArgs (a:as) = showsPrec 10 a . showString " " . showArgs as 

showTuple :: TyCon -> [TypeRep] -> ShowS
showTuple (TyCon _ str) args = showChar '(' . go str args
 where
  go [] [a] = showsPrec 10 a . showChar ')'
  go _  []  = showChar ')' -- a failure condition, really.
  go (',':xs) (a:as) = showsPrec 10 a . showChar ',' . go xs as
  go _ _   = showChar ')'


-------------------------------------------------------------
--
--	The Typeable class and friends
--
-------------------------------------------------------------


-- | The class 'Typeable' allows a concrete representation of a type to
-- be calculated.
class Typeable a where
  typeOf :: a -> TypeRep
  -- ^ Takes a value of type @a@ and returns a concrete representation
  -- of that type.  The /value/ of the argument should be ignored by
  -- any instance of 'Typeable', so that it is safe to pass 'undefined' as
  -- the argument.

-- | Variant for unary type constructors
class Typeable1 t where
  typeOf1 :: t a -> TypeRep

-- | For defining a 'Typeable' instance from any 'Typeable1' instance.
typeOfDefault :: (Typeable1 t, Typeable a) => t a -> TypeRep
typeOfDefault x = typeOf1 x `popStarTy` typeOf (argType x)
 where
   argType :: t a -> a
   argType =  undefined

#ifdef __GLASGOW_HASKELL__
-- | One Typeable instance for all Typeable1 instances
instance (Typeable1 s, Typeable a)
       => Typeable (s a) where
  typeOf = typeOfDefault
#endif


-- | Variant for binary type constructors
class Typeable2 t where
  typeOf2 :: t a b -> TypeRep

-- | For defining a 'Typeable1' instance from any 'Typeable2' instance.
typeOf1Default :: (Typeable2 t, Typeable a) => t a b -> TypeRep
typeOf1Default x = typeOf2 x `popStarTy` typeOf (argType x)
 where
   argType :: t a b -> a
   argType =  undefined


#ifdef __GLASGOW_HASKELL__
-- | One Typeable1 instance for all Typeable2 instances
instance (Typeable2 s, Typeable a)
       => Typeable1 (s a) where
  typeOf1 = typeOf1Default
#endif


-- | Variant for 3-ary type constructors
class Typeable3 t where
  typeOf3 :: t a b c -> TypeRep

-- | For defining a 'Typeable2' instance from any 'Typeable3' instance.
typeOf2Default :: (Typeable3 t, Typeable a) => t a b c -> TypeRep
typeOf2Default x = typeOf3 x `popStarTy` typeOf (argType x)
 where
   argType :: t a b c -> a
   argType =  undefined


#ifdef __GLASGOW_HASKELL__
-- | One Typeable2 instance for all Typeable3 instances
instance (Typeable3 s, Typeable a)
       => Typeable2 (s a) where
  typeOf2 = typeOf2Default
#endif


-- | Variant for 4-ary type constructors
class Typeable4 t where
  typeOf4 :: t a b c d -> TypeRep

-- | For defining a 'Typeable3' instance from any 'Typeable4' instance.
typeOf3Default :: (Typeable4 t, Typeable a) => t a b c d -> TypeRep
typeOf3Default x = typeOf4 x `popStarTy` typeOf (argType x)
 where
   argType :: t a b c d -> a
   argType =  undefined


#ifdef __GLASGOW_HASKELL__
-- | One Typeable3 instance for all Typeable4 instances
instance (Typeable4 s, Typeable a)
       => Typeable3 (s a) where
  typeOf3 = typeOf3Default
#endif


-- | Variant for 5-ary type constructors
class Typeable5 t where
  typeOf5 :: t a b c d e -> TypeRep

-- | For defining a 'Typeable4' instance from any 'Typeable5' instance.
typeOf4Default :: (Typeable5 t, Typeable a) => t a b c d e -> TypeRep
typeOf4Default x = typeOf5 x `popStarTy` typeOf (argType x)
 where
   argType :: t a b c d e -> a
   argType =  undefined


#ifdef __GLASGOW_HASKELL__
-- | One Typeable4 instance for all Typeable5 instances
instance (Typeable5 s, Typeable a)
       => Typeable4 (s a) where
  typeOf4 = typeOf4Default
#endif


-- | Variant for 6-ary type constructors
class Typeable6 t where
  typeOf6 :: t a b c d e f -> TypeRep

-- | For defining a 'Typeable5' instance from any 'Typeable6' instance.
typeOf5Default :: (Typeable6 t, Typeable a) => t a b c d e f -> TypeRep
typeOf5Default x = typeOf6 x `popStarTy` typeOf (argType x)
 where
   argType :: t a b c d e f -> a
   argType =  undefined


#ifdef __GLASGOW_HASKELL__
-- | One Typeable5 instance for all Typeable6 instances
instance (Typeable6 s, Typeable a)
       => Typeable5 (s a) where
  typeOf5 = typeOf5Default
#endif


-- | Variant for 7-ary type constructors
class Typeable7 t where
  typeOf7 :: t a b c d e f g -> TypeRep

-- | For defining a 'Typeable6' instance from any 'Typeable7' instance.
typeOf6Default :: (Typeable7 t, Typeable a) => t a b c d e f g -> TypeRep
typeOf6Default x = typeOf7 x `popStarTy` typeOf (argType x)
 where
   argType :: t a b c d e f g -> a
   argType =  undefined


#ifdef __GLASGOW_HASKELL__
-- | One Typeable6 instance for all Typeable7 instances
instance (Typeable7 s, Typeable a)
       => Typeable6 (s a) where
  typeOf6 = typeOf6Default
#endif



-------------------------------------------------------------
--
--		Type-safe cast
--
-------------------------------------------------------------

-- | The type-safe cast operation
cast :: (Typeable a, Typeable b) => a -> Maybe b
cast x = r
       where
	 r = if typeOf x == typeOf (fromJust r)
               then Just $ unsafeCoerce x
	       else Nothing


-- | A flexible variation parameterised in a type constructor
gcast :: (Typeable a, Typeable b) => c a -> Maybe (c b)
gcast x = r
 where
  r = if typeOf (getArg x) == typeOf (getArg (fromJust r))
        then Just $ unsafeCoerce x
        else Nothing
  getArg :: c x -> x 
  getArg = undefined



-- | Cast for * -> *
gcast1 :: (Typeable1 t, Typeable1 t') => c (t a) -> Maybe (c (t' a)) 
gcast1 x = r
 where
  r = if typeOf1 (getArg x) == typeOf1 (getArg (fromJust r))
       then Just $ unsafeCoerce x
       else Nothing
  getArg :: c x -> x 
  getArg = undefined


-- | Cast for * -> * -> *
gcast2 :: (Typeable2 t, Typeable2 t') => c (t a b) -> Maybe (c (t' a b)) 
gcast2 x = r
 where
  r = if typeOf2 (getArg x) == typeOf2 (getArg (fromJust r))
       then Just $ unsafeCoerce x
       else Nothing
  getArg :: c x -> x 
  getArg = undefined



-------------------------------------------------------------
--
--	Instances of the Typeable classes for Prelude types
--
-------------------------------------------------------------

#ifndef __NHC__
INSTANCE_TYPEABLE1([],listTc,"[]")
INSTANCE_TYPEABLE1(Maybe,maybeTc,"Maybe")
INSTANCE_TYPEABLE1(Ratio,ratioTc,"Ratio")
INSTANCE_TYPEABLE2(Either,eitherTc,"Either")
INSTANCE_TYPEABLE2((->),funTc,"->")
INSTANCE_TYPEABLE0((),unitTc,"()")
INSTANCE_TYPEABLE2((,),pairTc,"(,)")
INSTANCE_TYPEABLE3((,,),tup3Tc,",,")

tup4Tc :: TyCon
tup4Tc = mkTyCon ",,,"

instance Typeable4 (,,,) where
  typeOf4 tu = mkAppTy tup4Tc []


tup5Tc :: TyCon
tup5Tc = mkTyCon ",,,,"

instance Typeable5 (,,,,) where
  typeOf5 tu = mkAppTy tup5Tc []


tup6Tc :: TyCon
tup6Tc = mkTyCon ",,,,,"

instance Typeable6 (,,,,,) where
  typeOf6 tu = mkAppTy tup6Tc []


tup7Tc :: TyCon
tup7Tc = mkTyCon ",,,,,"

instance Typeable7 (,,,,,,) where
  typeOf7 tu = mkAppTy tup7Tc []

INSTANCE_TYPEABLE1(IO,ioTc,"System.IO.IO")
INSTANCE_TYPEABLE1(Ptr,ptrTc,"Foreign.Ptr.Ptr")
INSTANCE_TYPEABLE1(StablePtr,stableptrTc,"Foreign.StablePtr.StablePtr")
INSTANCE_TYPEABLE1(IORef,iorefTc,"Data.IORef.IORef")
#endif /* ! __NHC__ */

-------------------------------------------------------
--
-- Generate Typeable instances for standard datatypes
--
-------------------------------------------------------

#ifndef __NHC__
INSTANCE_TYPEABLE0(Bool,boolTc,"Bool")
INSTANCE_TYPEABLE0(Char,charTc,"Char")
INSTANCE_TYPEABLE0(Float,floatTc,"Float")
INSTANCE_TYPEABLE0(Double,doubleTc,"Double")
INSTANCE_TYPEABLE0(Int,intTc,"Int")
INSTANCE_TYPEABLE0(Integer,integerTc,"Integer")
INSTANCE_TYPEABLE0(Ordering,orderingTc,"Ordering")
INSTANCE_TYPEABLE0(Handle,handleTc,"Handle")

INSTANCE_TYPEABLE0(Int8,int8Tc,"Int8")
INSTANCE_TYPEABLE0(Int16,int16Tc,"Int16")
INSTANCE_TYPEABLE0(Int32,int32Tc,"Int32")
INSTANCE_TYPEABLE0(Int64,int64Tc,"Int64")

INSTANCE_TYPEABLE0(Word8,word8Tc,"Word8" )
INSTANCE_TYPEABLE0(Word16,word16Tc,"Word16")
INSTANCE_TYPEABLE0(Word32,word32Tc,"Word32")
INSTANCE_TYPEABLE0(Word64,word64Tc,"Word64")

INSTANCE_TYPEABLE0(TyCon,tyconTc,"TyCon")
INSTANCE_TYPEABLE0(TypeRep,typeRepTc,"TypeRep")
#endif /* !__NHC__ */

#ifdef __GLASGOW_HASKELL__
INSTANCE_TYPEABLE0(Word,wordTc,"Word" )
#endif

---------------------------------------------
--
--		Internals 
--
---------------------------------------------

#ifndef __HUGS__
newtype Key = Key Int deriving( Eq )
#endif

data KeyPr = KeyPr !Key !Key deriving( Eq )

hashKP :: KeyPr -> Int32
hashKP (KeyPr (Key k1) (Key k2)) = (HT.hashInt k1 + HT.hashInt k2) `rem` HT.prime

data Cache = Cache { next_key :: !(IORef Key),
		     tc_tbl   :: !(HT.HashTable String Key),
		     ap_tbl   :: !(HT.HashTable KeyPr Key) }

{-# NOINLINE cache #-}
cache :: Cache
cache = unsafePerformIO $ do
		empty_tc_tbl <- HT.new (==) HT.hashString
		empty_ap_tbl <- HT.new (==) hashKP
		key_loc      <- newIORef (Key 1) 
		return (Cache { next_key = key_loc,
				tc_tbl = empty_tc_tbl, 
				ap_tbl = empty_ap_tbl })

newKey :: IORef Key -> IO Key
#ifdef __GLASGOW_HASKELL__
newKey kloc = do i <- genSym; return (Key i)
#else
newKey kloc = do { k@(Key i) <- readIORef kloc ;
		   writeIORef kloc (Key (i+1)) ;
		   return k }
#endif

#ifdef __GLASGOW_HASKELL__
-- In GHC we use the RTS's genSym function to get a new unique,
-- because in GHCi we might have two copies of the Data.Typeable
-- library running (one in the compiler and one in the running
-- program), and we need to make sure they don't share any keys.  
--
-- This is really a hack.  A better solution would be to centralise the
-- whole mutable state used by this module, i.e. both hashtables.  But
-- the current solution solves the immediate problem, which is that
-- dynamics generated in one world with one type were erroneously
-- being recognised by the other world as having a different type.
foreign import ccall unsafe "genSymZh"
  genSym :: IO Int
#endif

mkTyConKey :: String -> Key
mkTyConKey str 
  = unsafePerformIO $ do
	let Cache {next_key = kloc, tc_tbl = tbl} = cache
	mb_k <- HT.lookup tbl str
	case mb_k of
	  Just k  -> return k
	  Nothing -> do { k <- newKey kloc ;
			  HT.insert tbl str k ;
			  return k }

appKey :: Key -> Key -> Key
appKey k1 k2
  = unsafePerformIO $ do
	let Cache {next_key = kloc, ap_tbl = tbl} = cache
	mb_k <- HT.lookup tbl kpr
	case mb_k of
	  Just k  -> return k
	  Nothing -> do { k <- newKey kloc ;
			  HT.insert tbl kpr k ;
			  return k }
  where
    kpr = KeyPr k1 k2

appKeys :: Key -> [Key] -> Key
appKeys k ks = foldl appKey k ks
