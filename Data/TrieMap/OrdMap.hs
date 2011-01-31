{-# LANGUAGE BangPatterns, UnboxedTuples, TypeFamilies, PatternGuards, MagicHash, CPP, TupleSections, NamedFieldPuns #-}
{-# OPTIONS -funbox-strict-fields #-}
module Data.TrieMap.OrdMap () where

import Data.TrieMap.TrieKey
import Data.TrieMap.Sized
import Data.TrieMap.Modifiers

import Control.Applicative
import Data.Foldable
import Control.Monad hiding (join, fmap)

import Prelude hiding (lookup, foldr, foldl, fmap)

import GHC.Exts

#define DELTA 5
#define RATIO 2

data Path k a =
	Root
	| LeftBin k a !(Path k a) !(SNode k a)
	| RightBin k a !(SNode k a) !(Path k a)

data Node k a =
  Tip
  | Bin k a !(SNode k a) !(SNode k a)
data SNode k a = SNode{sz :: !Int, count :: !Int, node :: Node k a}

#define TIP SNode{node=Tip}
#define BIN(args) SNode{node=Bin args}

instance Sized a => Sized (Node k a) where
  getSize# Tip = 0#
  getSize# (Bin _ a l r) = getSize# a +# getSize# l +# getSize# r

instance Sized (SNode k a) where
  getSize# SNode{sz = I# sz#} = sz#

nCount :: Node k a -> Int
nCount Tip = 0
nCount (Bin _ _ l r) = 1 + count l + count r

sNode :: Sized a => Node k a -> SNode k a
sNode !n = SNode (getSize n) (nCount n) n

tip :: SNode k a
tip = SNode 0 0 Tip

-- | @'TrieMap' ('Ordered' k) a@ is based on "Data.Map".
instance Ord k => TrieKey (Ordered k) where
	Ord k1 =? Ord k2	= k1 == k2
	Ord k1 `cmp` Ord k2	= k1 `compare` k2
  
	newtype TrieMap (Ordered k) a = OrdMap (SNode k a)
        data Hole (Ordered k) a = 
        	Empty k !(Path k a)
        	| Full k !(Path k a) !(SNode k a) !(SNode k a)
	emptyM = OrdMap tip
	singletonM (Ord k) a = OrdMap (singleton k a)
	lookupM (Ord k) (OrdMap m) = lookup k m
	insertWithM f (Ord k) a (OrdMap m) = OrdMap (insertWith f k a m)
	getSimpleM (OrdMap m) = case m of
		TIP	-> Null
		BIN(_ a TIP TIP)
			-> Singleton a
		_	-> NonSimple
	sizeM (OrdMap m) = sz m
	traverseM f (OrdMap m) = OrdMap  <$> traverse f m
	foldrM f (OrdMap m) z = foldr f z m
	foldlM f (OrdMap m) z = foldl f z m
	fmapM f (OrdMap m) = OrdMap (fmap f m)
	mapMaybeM f (OrdMap m) = OrdMap (mapMaybe f m)
	mapEitherM f (OrdMap m) = both OrdMap OrdMap (mapEither f) m
	isSubmapM (<=) (OrdMap m1) (OrdMap m2) = isSubmap (<=) m1 m2
	fromAscListM f xs = OrdMap $ fromAscList f [(k, a) | (Ord k, a) <- xs]
	fromDistAscListM  xs = OrdMap $ fromDistinctAscList  [(k, a) | (Ord k, a) <- xs]
	unionM f (OrdMap m1) (OrdMap m2) = OrdMap $ hedgeUnion f (const LT) (const GT) m1 m2
	isectM f (OrdMap m1) (OrdMap m2) = OrdMap $ isect f m1 m2
	diffM f (OrdMap m1) (OrdMap m2) = OrdMap $ hedgeDiff f (const LT) (const GT) m1 m2
	
	singleHoleM (Ord k) = Empty k Root
	beforeM (Empty _ path) = OrdMap $ before tip path
	beforeM (Full _ path l _) = OrdMap $ before l path
	beforeWithM a (Empty k path) = OrdMap $ before (singleton k a) path
	beforeWithM a (Full k path l _) = OrdMap $ before (insertMax k a l) path
	afterM (Empty _ path) = OrdMap $ after tip path
	afterM (Full _ path _ r) = OrdMap $ after r path
	afterWithM a (Empty k path) = OrdMap $ after (singleton k a) path
	afterWithM a (Full k path _ r) = OrdMap $ after (insertMin k a r) path
	searchM (Ord k) (OrdMap m) = search k Root m
	indexM i (OrdMap m) = indexT Root i m where
		indexT path i BIN(kx x l r) 
		  | i < sl	= indexT (LeftBin kx x path r) i l
		  | i < sx	= (# i - sl, x, Full kx path l r #)
		  | otherwise	= indexT (RightBin kx x l path) (i - sx) r
			where	!sl = getSize l
				!sx = getSize x + sl
		indexT _ _ _ = indexFail ()
	extractHoleM (OrdMap m) = extractHole Root m where
		extractHole path BIN(kx x l r) =
			extractHole (LeftBin kx x path r) l `mplus`
			return (x, Full kx path l r) `mplus`
			extractHole (RightBin kx x l path) r
		extractHole _ _ = mzero
	
	clearM (Empty _ path) = OrdMap $ rebuild tip path
	clearM (Full _ path l r) = OrdMap $ rebuild (merge l r) path
	assignM x (Empty k path) = OrdMap $ rebuild (singleton k x) path
	assignM x (Full k path l r) = OrdMap $ rebuild (join k x l r) path
	
	unifyM (Ord k1) a1 (Ord k2) a2 = case compare k1 k2 of
		EQ	-> Nothing
		LT	-> Just $ OrdMap $ bin k1 a1 tip (singleton k2 a2)
		GT	-> Just $ OrdMap $ bin k1 a1 (singleton k2 a2) tip

rebuild :: Sized a => SNode k a -> Path k a -> SNode k a
rebuild t Root = t
rebuild t (LeftBin kx x path r) = rebuild (balance kx x t r) path
rebuild t (RightBin kx x l path) = rebuild (balance kx x l t) path

lookup :: Ord k => k -> SNode k a -> Maybe a
lookup k BIN(kx x l r) = case compare k kx of
	LT	-> lookup k l
	EQ	-> Just x
	GT	-> lookup k r
lookup _ _ = Nothing

insertWith :: (Ord k, Sized a) => (a -> a -> a) -> k -> a -> SNode k a -> SNode k a
insertWith f k a = ins where
  ins TIP = singleton k a
  ins BIN(kx x l r) = case compare k kx of
    LT	-> join kx x (ins l) r
    EQ	-> bin kx (f a x) l r
    GT	-> join kx x l (ins r)

singleton :: Sized a => k -> a -> SNode k a
singleton k a = bin k a tip tip

traverse :: (Applicative f, Sized b) => (a -> f b) -> SNode k a -> f (SNode k b)
traverse _ TIP = pure tip
traverse f BIN(k a l r) = balance k <$> f a <*> traverse f l <*> traverse f r

instance Foldable (SNode k) where
  foldr _ z TIP	= z
  foldr f z BIN(_ a l r) = foldr f (a `f` foldr f z r) l
  foldl _ z TIP = z
  foldl f z BIN(_ a l r) = foldl f (foldl f z l `f` a) r

fmap :: (Ord k, Sized b) => (a -> b) -> SNode k a -> SNode k b
fmap f BIN(k a l r) = join k (f a) (fmap f l) (fmap f r)
fmap _ _ = tip

mapMaybe :: (Ord k, Sized b) => (a -> Maybe b) -> SNode k a -> SNode k b
mapMaybe f BIN(k a l r) = joinMaybe  k (f a) (mapMaybe f l) (mapMaybe f r)
mapMaybe _ _ = tip

mapEither :: (Ord k, Sized b, Sized c) => (a -> (# Maybe b, Maybe c #)) ->
	SNode k a -> (# SNode k b, SNode k c #)
mapEither f BIN(k a l r) = (# joinMaybe k aL lL rL, joinMaybe k aR lR rR #)
  where !(# aL, aR #) = f a; !(# lL, lR #) = mapEither f l; !(# rL, rR #) = mapEither f r
mapEither _ _ = (# tip, tip #)

splitLookup :: (Ord k, Sized a) => k -> SNode k a -> (# SNode k a, Maybe a, SNode k a #)
splitLookup k t = case search k Root t of
  (# v, Empty _ path #)	-> (# before tip path, v, after tip path #)
  (# v, Full _ path l r #) -> (# before l path, v, after r path #)

isSubmap :: (Ord k, Sized a, Sized b) => LEq a b -> LEq (SNode k a) (SNode k b)
isSubmap _ TIP _ = True
isSubmap _ _ TIP = False
isSubmap (<=) BIN(kx x l r) t = case splitLookup kx t of
  (# _, Nothing, _ #)	-> False
  (# tl, Just y, tr #)	-> x <= y && isSubmap (<=) l tl && isSubmap (<=) r tr

fromAscList :: (Eq k, Sized a) => (a -> a -> a) -> [(k, a)] -> SNode k a
fromAscList f xs = fromDistinctAscList (combineEq xs) where
	combineEq (x:xs) = combineEq' x xs
	combineEq [] = []
	
	combineEq' z [] = [z]
	combineEq' (kz, zz) (x@(kx, xx):xs)
		| kz == kx	= combineEq' (kx, f xx zz) xs
		| otherwise	= (kz,zz):combineEq' x xs

fromDistinctAscList :: Sized a => [(k, a)] -> SNode k a
fromDistinctAscList xs = build const (length xs) xs
  where
    -- 1) use continutations so that we use heap space instead of stack space.
    -- 2) special case for n==5 to build bushier trees. 
    build c 0 xs'  = c tip xs'
    build c 5 xs'  = case xs' of
                      ((k1,x1):(k2,x2):(k3,x3):(k4,x4):(k5,x5):xx) 
                            -> c (bin k4 x4 (bin k2 x2 (singleton k1 x1) (singleton k3 x3)) (singleton k5 x5)) xx
                      _ -> error "fromDistinctAscList build"
    build c n xs'  = seq nr $ build (buildR nr c) nl xs'
                   where
                     nl = n `div` 2
                     nr = n - nl - 1

    buildR n c l ((k,x):ys) = build (buildB l k x c) n ys
    buildR _ _ _ []         = error "fromDistinctAscList buildR []"
    buildB l k x c r zs     = c (bin k x l r) zs

hedgeUnion :: (Ord k, Sized a)
                  => (a -> a -> Maybe a)
                  -> (k -> Ordering) -> (k -> Ordering)
                  -> SNode k a -> SNode k a -> SNode k a
hedgeUnion _ _     _     t1 TIP
  = t1
hedgeUnion _ cmplo cmphi TIP BIN(kx x l r)
  = join kx x (filterGt  cmplo l) (filterLt  cmphi r)
hedgeUnion f cmplo cmphi BIN(kx x l r) t2
  = joinMaybe  kx newx (hedgeUnion  f cmplo cmpkx l lt) 
                (hedgeUnion  f cmpkx cmphi r gt)
  where
    cmpkx k     = compare kx k
    lt          = trim cmplo cmpkx t2
    (found,gt)  = trimLookupLo kx cmphi t2
    newx        = case found of
                    Nothing -> Just x
                    Just (_,y) -> f x y

filterGt :: (Ord k, Sized a) => (k -> Ordering) -> SNode k a -> SNode k a
filterGt _   TIP = tip
filterGt cmp BIN(kx x l r)
  = case cmp kx of
      LT -> join kx x (filterGt  cmp l) r
      GT -> filterGt  cmp r
      EQ -> r
      
filterLt :: (Ord k, Sized a) => (k -> Ordering) -> SNode k a -> SNode k a
filterLt _   TIP = tip
filterLt cmp BIN(kx x l r)
  = case cmp kx of
      LT -> filterLt cmp l
      GT -> join kx x l (filterLt  cmp r)
      EQ -> l

trim :: (k -> Ordering) -> (k -> Ordering) -> SNode k a -> SNode k a
trim _     _     TIP = tip
trim cmplo cmphi t@BIN(kx _ l r)
  = case cmplo kx of
      LT -> case cmphi kx of
              GT -> t
              _  -> trim cmplo cmphi l
      _  -> trim cmplo cmphi r
              
trimLookupLo :: Ord k => k -> (k -> Ordering) -> SNode k a -> (Maybe (k,a), SNode k a)
trimLookupLo _  _     TIP = (Nothing,tip)
trimLookupLo lo cmphi t@BIN(kx x l r)
  = case compare lo kx of
      LT -> case cmphi kx of
              GT -> ((lo,) <$> lookup lo t, t)
              _  -> trimLookupLo lo cmphi l
      GT -> trimLookupLo lo cmphi r
      EQ -> (Just (kx,x),trim (compare lo) cmphi r)

isect :: (Ord k, Sized a, Sized b, Sized c) => (a -> b -> Maybe c) -> SNode k a -> SNode k b -> SNode k c
isect f t1@BIN(_ _ _ _) BIN(k2 x2 l2 r2) = case splitLookup  k2 t1 of
  (# tl, found, tr #)	-> joinMaybe k2 (found >>= \ x1' -> f x1' x2) (isect f tl l2) (isect f tr r2)
isect _ _ _ = tip

hedgeDiff :: (Ord k, Sized a)
                 => (a -> b -> Maybe a)
                 -> (k -> Ordering) -> (k -> Ordering)
                 -> SNode k a -> SNode k b -> SNode k a
hedgeDiff _ _     _     TIP _
  = tip
hedgeDiff _ cmplo cmphi BIN(kx x l r) TIP
  = join kx x (filterGt  cmplo l) (filterLt  cmphi r)
hedgeDiff  f cmplo cmphi t BIN(kx x l r) 
  = case found of
      Nothing -> merge  tl tr
      Just (ky,y) -> 
          case f y x of
            Nothing -> merge tl tr
            Just z  -> join ky z tl tr
  where
    cmpkx k     = compare kx k   
    lt          = trim cmplo cmpkx t
    (found,gt)  = trimLookupLo kx cmphi t
    tl          = hedgeDiff f cmplo cmpkx lt l
    tr          = hedgeDiff f cmpkx cmphi gt r

joinMaybe :: (Ord k, Sized a) => k -> Maybe a -> SNode k a -> SNode k a -> SNode k a
joinMaybe kx = maybe merge (join kx)

join :: Sized a => k -> a -> SNode k a -> SNode k a -> SNode k a
join kx x TIP r  = insertMin  kx x r
join kx x l TIP  = insertMax  kx x l
join kx x l@(SNode _ sL (Bin ky y ly ry)) r@(SNode _ sR (Bin kz z lz rz))
  | DELTA * sL <= sR = balance kz z (join kx x l lz) rz
  | DELTA * sR <= sL = balance ky y ly (join kx x ry r)
  | otherwise        = bin kx x l r

-- insertMin and insertMax don't perform potentially expensive comparisons.
insertMax,insertMin :: Sized a => k -> a -> SNode k a -> SNode k a
insertMax kx x SNode{node}
  = case node of
      Tip -> singleton kx x
      Bin ky y l r
          -> balance ky y l (insertMax kx x r)
             
insertMin kx x SNode{node}
  = case node of
      Tip -> singleton kx x
      Bin ky y l r
          -> balance ky y (insertMin kx x l) r
             
{--------------------------------------------------------------------
  [merge l r]: merges two trees.
--------------------------------------------------------------------}
merge :: Sized a => SNode k a -> SNode k a -> SNode k a
merge TIP r   = r
merge l TIP   = l
merge l@(SNode _ sL (Bin kx x lx rx)) r@(SNode _ sR (Bin ky y ly ry))
  | DELTA * sL <= sR	= balance ky y (merge l ly) ry
  | DELTA * sR <= sL	= balance kx x lx (merge rx r)
  | otherwise		= glue l r

{--------------------------------------------------------------------
  [glue l r]: glues two trees together.
  Assumes that [l] and [r] are already balanced with respect to each other.
--------------------------------------------------------------------}
glue :: Sized a => SNode k a -> SNode k a -> SNode k a
glue TIP r = r
glue l TIP = l
glue l r
  | count l > count r	= let !(# f, l' #) = deleteFindMax balance l in f l' r
  | otherwise		= let !(# f, r' #) = deleteFindMin balance r in f l r'

deleteFindMin :: Sized a => (k -> a -> x) -> SNode k a -> (# x, SNode k a #)
deleteFindMin f t 
  = case t of
      BIN(k x TIP r)	-> (# f k x, r #)
      BIN(k x l r)	-> onSnd (\ l' -> balance k x l' r) (deleteFindMin f) l
      _			-> (# error "Map.deleteFindMin: can not return the minimal element of an empty fmap", tip #)

deleteFindMax :: Sized a => (k -> a -> x) -> SNode k a -> (# x, SNode k a #)
deleteFindMax f t
  = case t of
      BIN(k x l TIP)	-> (# f k x, l #)
      BIN(k x l r)	-> onSnd (balance k x l) (deleteFindMax f) r
      TIP		-> (# error "Map.deleteFindMax: can not return the maximal element of an empty fmap", tip #)

balance :: Sized a => k -> a -> SNode k a -> SNode k a -> SNode k a
balance k x l r
  | sR >= (DELTA * sL)	= rotateL  k x l r
  | sL >= (DELTA * sR)	= rotateR  k x l r
  | otherwise		= bin k x l r
  where
    !sL = count l
    !sR = count r

-- rotate
rotateL :: Sized a => k -> a -> SNode k a -> SNode k a -> SNode k a
rotateL k x l r@BIN(_ _ ly ry)
  | sL < (RATIO * sR)	= singleL k x l r
  | otherwise		= doubleL k x l r
  where	!sL = count ly
  	!sR = count ry
rotateL _ _ _ TIP = error "rotateL Tip"

rotateR :: Sized a => k -> a -> SNode k a -> SNode k a -> SNode k a
rotateR k x l@BIN(_ _ ly ry) r
  | sR < (RATIO * sL)	= singleR k x l r
  | otherwise		= doubleR k x l r
  where	!sL = count ly
  	!sR = count ry
rotateR _ _ _ _ = error "rotateR Tip"

-- basic rotations
singleL, singleR :: Sized a => k -> a -> SNode k a -> SNode k a -> SNode k a
singleL k1 x1 t1 BIN(k2 x2 t2 t3)  = bin k2 x2 (bin k1 x1 t1 t2) t3
singleL k1 x1 t1 TIP = bin k1 x1 t1 tip
singleR  k1 x1 BIN(k2 x2 t1 t2) t3  = bin k2 x2 t1 (bin k1 x1 t2 t3)
singleR  k1 x1 TIP t2 = bin k1 x1 tip t2

doubleL, doubleR :: Sized a => k -> a -> SNode k a -> SNode k a -> SNode k a
doubleL  k1 x1 t1 BIN(k2 x2 BIN(k3 x3 t2 t3) t4) = bin k3 x3 (bin k1 x1 t1 t2) (bin k2 x2 t3 t4)
doubleL  k1 x1 t1 t2 = singleL k1 x1 t1 t2
doubleR  k1 x1 BIN(k2 x2 t1 BIN(k3 x3 t2 t3)) t4 = bin k3 x3 (bin k2 x2 t1 t2) (bin k1 x1 t3 t4)
doubleR  k1 x1 t1 t2 = singleR  k1 x1 t1 t2

bin :: Sized a => k -> a -> SNode k a -> SNode k a -> SNode k a
bin k x l r
  = sNode (Bin k x l r)

before :: Sized a => SNode k a -> Path k a -> SNode k a
before t (LeftBin _ _ path _) = before t path
before t (RightBin k a l path) = before (join k a l t) path
before t _ = t

after :: Sized a => SNode k a -> Path k a -> SNode k a
after t (LeftBin k a path r) = after (join k a t r) path
after t (RightBin _ _ _ path) = after t path
after t _ = t

search :: Ord k => k -> Path k a -> SNode k a -> (# Maybe a, Hole (Ordered k) a #)
search k path TIP = (# Nothing, Empty k path #)
search k path BIN(kx x l r) = case compare k kx of
	LT	-> search k (LeftBin kx x path r) l
	EQ	-> (# Just x, Full k path l r #)
	GT	-> search k (RightBin kx x l path) r