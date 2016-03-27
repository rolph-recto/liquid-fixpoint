-- | This module uses Craig interpolation to compute qualifiers
-- | that can be used to solve constraint sets

{-# LANGUAGE PatternGuards #-}

module Language.Fixpoint.Interpolate ( genQualifiers, imain2 ) where

import System.Console.CmdArgs
import qualified Data.HashMap.Strict as M
import qualified Data.HashSet as S
import Data.List (intercalate, nub)
import Text.Read (readMaybe)
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader

-- import Language.Fixpoint.Smt.Types
import Language.Fixpoint.Types hiding (renameSymbol)
import Language.Fixpoint.Types.Config
import Language.Fixpoint.Solver.Solve
import Language.Fixpoint.Solver.Solution
import qualified Language.Fixpoint.Types.Visitor as V

-- import Debug.Trace

data AOTree b a = And b a [AOTree b a]
                | Or b [AOTree b a]

instance (Show a, Show b) => Show (AOTree b a) where
  show (And b a children) =
    let showChildren = intercalate "," (map show children) in
    "And " ++ (show b) ++ " " ++ (show a) ++ " [" ++ showChildren ++ "]"
  show (Or b children) =
    let showChildren = intercalate "," (map show children) in
    "Or " ++ (show b) ++ " [" ++ showChildren ++ "]"

instance (Eq a, Eq b) => Eq (AOTree b a) where
  (And x1 y1 c1) == (And x2 y2 c2)  = x1 == x2 && y1 == y2 && c1 == c2
  (Or x1 c1) == (Or x2 c2)          = x1 == x2 && c1 == c2
  (And _ _ _) == (Or _ _)           = False
  (Or _ _) == (And _ _ _)           = False

-- this could be a functor except the mapping function "f"
-- needs extra context (the extra b param)
mapAOTree :: (b -> a -> c) -> AOTree b a -> AOTree b c
mapAOTree f (And i n children) = And i (f i n) $ map (mapAOTree f) children
mapAOTree f (Or i children) = Or i $ map (mapAOTree f) children

-- the corresponding HC head of a node (non-root nodes correspond to HC bodies)
type HeadInfo = (KVar, Symbol)

-- an interpolation query
-- an And/Or tree corresponds to a disjunctive interpolant
-- an And tree corresponds to a tree interpolant
type InterpQuery = AOTree (Maybe HeadInfo) Expr

-- a tree interpolant
-- this should have the same structure as its corresponding tree interp query
type TreeInterp = AOTree (Maybe HeadInfo) Expr
{-
showTreeInterp :: TreeInterp -> String
showTreeInterp (And b a children) =
  let showChildren = intercalate "," (map showTreeInterp children) in
  "And " ++ (show b) ++ " " ++ (show $ smt2 a) ++ " [" ++ showChildren ++ "]"
showTreeInterp (Or b children) =
  let showChildren = intercalate "," (map showTreeInterp children) in
  "Or " ++ (show b) ++ " [" ++ showChildren ++ "]"
-}

-- a set of candidate solutions
type CandSolutions = M.HashMap KVar [Expr]

-- body, children, head
-- this is computed from SubC
type ClauseChild = (KVar, Subst, Symbol)
type ClauseInfo a = (Expr, [ClauseChild], a)
type Rule = ClauseInfo KVar
type Query = ClauseInfo Expr

-- new substitutions generated from unrolling
-- the Symbol at the value of a mapping corresponds
-- to the original variable that the tmp var substituted
type UnrollSubs = M.HashMap Symbol Symbol

-- mapping from kvars to rec/nonrec-clauses with head as the kvar
type KClauses = M.HashMap KVar ([Rule], [Rule])
-- sorts of symbols; this is used for 
type SymSorts = M.HashMap Symbol Sort
type UnrollInfo = (KClauses, SymSorts)

-- for generating renamed symbols
type RenameMap = M.HashMap Symbol Int

-- created symbols, rename map, unroll subs
type UnrollState = (SymSorts, RenameMap, UnrollSubs)
type UnrollDepth = M.HashMap KVar Int
type UnrollM a = ReaderT UnrollInfo (State UnrollState) a

-- HELPER FUNCTIONS

bindSym :: BindId -> BindEnv -> Symbol
bindSym id env = fst $ lookupBindEnv id env

substToList :: Subst -> [(Symbol, Expr)]
substToList (Su map) = M.toList map

-- like intSymbol, but without the separator
numSymbol :: (Show a) => Symbol -> a -> Symbol
numSymbol x i = x `mappendSym` (symbol $ show i)

--------------------------------
-- | PRELIMINARIES FOR UNROLLING
--------------------------------

toRuleOrQuery :: (Show b) => (Expr -> b) -> BindEnv -> SubC a -> ClauseInfo b
toRuleOrQuery f be c =
  let bids      = elemsIBindEnv $ senv c in
  let bexprs    = map (bindExprs ce) bids in
  let bsyms     = map (flip bindSym be) bids in
  -- trace ("LHS" ++ (show lhs')) $
  let esyms     = ([lhs'],vvName):(zip bexprs bsyms) in
  let body      = concatMap (\(es,_) -> filter (not . isKVar) es) esyms in
  let kvars     = concatMap getKVarSym esyms in
  let res       = (PAnd body, kvars, f rhs') in
  -- trace ("CONSTRAINT:" ++ (show res)) res
  res
  where Reft (symlhs, elhs)   = sr_reft (slhs c)
        Reft (symrhs, erhs)   = sr_reft (srhs c)
        lhs                   = subst1 elhs (symlhs, EVar vvName)
        rhs                   = subst1 erhs (symrhs, EVar vvName)
        (lhs', rhs')          = (cleanSubs lhs vvName, cleanSubs rhs vvName)
        ce                    = (sid c, be, senv c)
        isKVar (PKVar _ _)    = True
        isKVar _              = False
        getKVarSym (es,s)     = map (packHead s) $ filter isKVar es
        packHead s pk         =
          let ks    = getKVar pk in
          let subs' = filterConSym (snd ks) s in
          (fst ks, subs', s)
        getKVar (PKVar k s)   = (k, s)
        getKVar e             = error $ "expr " ++ (show e) ++ " is not a kvar"
        -- filter out substitutions for [x:=s]; this is used by liquid
        -- fixpoint to insert the actual variable of a constraint instead
        -- of a generic "v". we erase these subs because they interfere
        -- with unrolling
        cleanSubs e s         = V.trans (subVisitor s) () () e
        cleanSubs' s _ e
          | PKVar k subs <- e = (PKVar k (filterConSym subs s))
          | otherwise         = e
        subVisitor s          = sv { V.txExpr = (cleanSubs' s) }
        sv                    = V.defaultVisitor
        filterConSym subs s   = filterSubst (\_ e -> not $ isExprSym e s) subs
        isExprSym (EVar s') s = s' == s
        isExprSym _ _         = False

toRule :: BindEnv -> SubC a -> Rule
toRule be c
  | PKVar _ _ <- crhs c = toRuleOrQuery getKVar be c
  | otherwise = error "constraint is not a rule"
  where getKVar (PKVar k _) = k
        getKVar _           = error "rhs is not a kvar"

toQuery :: BindEnv -> SubC a -> Query
toQuery be c
  | PKVar _ _ <- crhs c = error "constraint is not a query"
  | otherwise = toRuleOrQuery id be c

isClauseRec :: [Rule] -> Rule -> Bool
isClauseRec rs r@(_,_,k) = k `elem` childks
  where childks = getChildK r []
        rulesWithHead k = filter (\(_,_,k') -> k' == k) rs
        getChildK (_,cs,_) seen =
          let cks     = map (\(k,_,_) -> k) cs in
          let cks'    = filter (not . flip elem seen) cks in
          let crules  = concatMap rulesWithHead cks' in
          foldr getChildK (cks ++ seen) crules
               
genKClauses :: [Rule] -> KClauses
genKClauses rules = foldr addRule M.empty rules
  where insertRec r (rec,nrec)  = (r:rec,nrec)
        insertNRec r (rec,nrec) = (rec,r:nrec)
        addRule r@(_,_,h) kmap
          | isClauseRec rules r = addRule' insertRec r h kmap
          | otherwise           = addRule' insertNRec r h kmap
        addRule' f r h kmap     =
          let val = maybe (f r ([],[])) (f r) (M.lookup h kmap) in
          M.insert h val kmap

-- create a map of binding and kvar sorts
extractSymSorts :: FInfo a -> SymSorts 
extractSymSorts finfo = 
  let binds = bindEnvToList (bs finfo) in
  let wfs = M.elems (ws finfo) in
  let bsorts = map getBindSort binds in
  let ksorts = map getKSort wfs in
  M.fromList (bsorts ++ ksorts)
  where getBindSort (_,s,RR sort _)         = (s,sort)
        getKSort (WfC _ (_, sort, KV s) _)  = (s,sort)

-- convert FInfo to data structures used for unrolling
genUnrollInfo :: FInfo a -> (SymSorts, KClauses, [Query])
genUnrollInfo finfo =
  let (rules, queries) = foldr addCon ([],[]) $ map snd $ M.toList $ cm finfo in
  let kcs = genKClauses rules in
  let sorts = extractSymSorts finfo in
  let res = (sorts, kcs, queries) in
  -- trace ("INFO:" ++ (show res)) res
  res
  where be = bs finfo
        addCon c (rules,queries)
          | PKVar _ _ <- crhs c = ((toRule be c):rules, queries)
          | otherwise           = (rules, (toQuery be c):queries)

--------------
-- | UNROLLING
--------------

exprSyms :: Expr -> [Symbol]
exprSyms e  = nub $ V.fold symVisitor () [] e
  where symVisitor :: V.Visitor [Symbol] ()
        symVisitor                  = dv { V.accExpr = getSymbol }
        dv                          = V.defaultVisitor :: V.Visitor [Symbol] ()
        getSymbol _ (EVar s)        = [s]
        getSymbol _ (PKVar _ subs)  =
          let (ks, sexprs) = unzip $ substToList subs in
          ks ++ concatMap exprSyms sexprs
        getSymbol _ _               = []

{-
freeInExpr :: Symbol -> Expr -> Bool
freeInExpr s e = not $ s `elem` (exprSyms e)

-- rename a symbol while making sure it doesn't appear on a list of symbols
-- the list of symbols is usually the list of bound syms in an expr
renameSym :: Int -> Symbol -> Expr -> (Int, Symbol)
renameSym n s e =
  let s' = numSymbol s n in
  let ss = exprSyms e in
  if s' `elem` ss then renameSym (n+1) s ss else (n, s')
-}

-- rename instances of symbol in substitutions
renameSubst :: Symbol -> Symbol -> Subst -> Subst
renameSubst s s' subs =
  let slist  = substToList subs in
  let slist' = map renameSub slist in
  Su $ M.fromList slist'
  where renameSub (sk,se) =
          let sk' = if sk == s then s' else sk in
          let se' = renameExpr s s' se in
          (sk', se')

-- rename all instances of symbol in body
renameExpr :: Symbol -> Symbol -> Expr -> Expr
renameExpr s s' e = V.trans renameVisitor () () e
  where rename _ e@(EVar s'')
          | s == s''  = EVar s'
          | otherwise = e
        rename _ (PKVar k subs) =
          let subs'   = renameSubst s s' subs in
          PKVar k subs'
        rename _ e    = e
        renameVisitor = dv { V.txExpr = rename }
        dv            = V.defaultVisitor :: V.Visitor () ()

renameClauseChild :: Symbol -> Symbol -> ClauseChild -> ClauseChild
renameClauseChild s s' (ck,csub,csym) = (ck, newsub, newsym)
  where newsub = renameSubst s s' csub
        newsym = if csym == s then s' else csym

-- replace all instances of s in kcs with s'
renameClauses :: Symbol -> Symbol -> UnrollInfo -> UnrollInfo
renameClauses s s' (kcs,ss) = (M.fromList $ map renameK $ M.toList kcs, ss)
  where renameK (k,(rec,nrec)) = (k, (map renameRule rec, map renameRule nrec))
        renameRule (b, cs, h) =
          let b'  = renameExpr s s' b in
          let cs' = map (renameClauseChild s s') cs in
          (b', cs', h)

lget :: UnrollM UnrollState
lget = lift get

lput :: UnrollState -> UnrollM ()
lput = lift . put

getKClauses :: UnrollM KClauses
getKClauses = fst <$> ask

setKClauses :: KClauses -> UnrollInfo -> UnrollInfo
setKClauses kcs (_, ss) = (kcs, ss)

getSymSorts :: UnrollM SymSorts
getSymSorts = snd <$> ask

-- get sort for a symbol (could be in uinfo or created symbols)
getSymSort :: Symbol -> UnrollM (Maybe Sort)
getSymSort s = do
  ss <- getSymSorts
  case M.lookup s ss of
    Just sort -> return (Just sort)
    Nothing -> do
      cs <- getCreatedSymbols
      return $ M.lookup s cs

getRenameMap :: UnrollM RenameMap
getRenameMap = do
  (_, rm, _) <- get
  return rm

updateRenameMap :: RenameMap -> UnrollM ()
updateRenameMap rm = do
  (cs, _, us) <- lget
  lput (cs, rm, us)

getCreatedSymbols :: UnrollM SymSorts
getCreatedSymbols = do
  (cs, _, _) <- lget
  return cs

updateCreatedSymbols :: SymSorts -> UnrollM ()
updateCreatedSymbols cs = do
  (_, rm, us) <- lget
  lput (cs, rm, us)

getUnrollSubs :: UnrollM UnrollSubs
getUnrollSubs = do
  (_, _, us) <- lget
  return us

updateUnrollSubs :: UnrollSubs -> UnrollM ()
updateUnrollSubs us = do
  (cs, rm, _) <- lget
  lput (cs, rm, us)

getSubCount :: Symbol -> UnrollM Int
getSubCount s = do
  rm <- getRenameMap
  -- FIXME: CHECK IF s has number suffix
  return $ maybe 1 id $ M.lookup s rm

updateSubCount :: Symbol -> Int -> UnrollM ()
updateSubCount s n = do
  rm <- getRenameMap
  let rm' = M.insert s n rm
  updateRenameMap rm'

-- inherit the orig symbol that the variable was substituted for
newSub :: Symbol -> Symbol -> UnrollM ()
newSub s s' = do
  usubs <- getUnrollSubs
  let orig = maybe s id (M.lookup s usubs)
  let usubs' = M.insert s' orig usubs
  updateUnrollSubs usubs'

renameSymbol :: Symbol -> UnrollM Symbol
renameSymbol s = do
  -- let spref = unSuffixSymbol s
  n <- getSubCount s
  updateSubCount s (n+1)
  -- FIXME: change this to intSymbol
  let s' = numSymbol s n
  cs <- getCreatedSymbols
  msort <- getSymSort s
  -- if sort cannot be found, assume it's an int
  let sort = maybe intSort id msort
  updateCreatedSymbols (M.insert s' sort cs)
  return s'

subSymbol = symbol "SUB"

freshSubSymbol :: UnrollM Symbol
freshSubSymbol = renameSymbol subSymbol

-- apply pending substitutions 
applySubst :: Subst -> UnrollM (KClauses, [Expr])
applySubst subs = do
  kcs <- getKClauses
  foldM applySub1 (kcs,[]) $ substToList subs
  where applySub1 (kcs',tmpexprs) (ssym,sexpr) = do
          tmp <- freshSubSymbol
          ss <- getSymSorts
          let tmpexpr    = PAtom Eq (EVar tmp) sexpr
          let (kcs'', _) = renameClauses ssym tmp (kcs',ss)
          newSub ssym tmp
          return (kcs'', tmpexpr:tmpexprs)

-- generate disjunctive interpolation query
unroll :: UnrollDepth -> HeadInfo -> UnrollM InterpQuery
unroll dmap (k,sym) = do
  kcs <- getKClauses
  case M.lookup k kcs of
    Nothing -> return $ Or Nothing []
    Just (crec, cnrec) -> do
      let depth = maybe 0 id (M.lookup k dmap)
      let rec = depth > 0
      let cs = if not rec then cnrec else crec ++ cnrec
      let dmap' = M.insert k (depth-1) dmap

      -- generate children
      children <- forM cs $ \(b, c, _) -> do
        -- rename body to prevent capture
        sym' <- renameSymbol sym
        let b' = renameExpr sym sym' b 
        let c' = map (renameClauseChild sym sym') c

        -- apply argument i.e. [nu/x]
        let b'' = renameExpr vvName sym b'
        
        local (renameClauses sym sym') $ do
          -- generate child subtree
          ginfo <- forM c' $ \(ck,csub,csym) -> do
            (kcs'', tmps) <- applySubst csub
            local (setKClauses kcs'') $ do
              gc <- unroll dmap' (ck,csym)
              return (gc, tmps)
          
          let (gchildren, gtmps) = unzip ginfo

          -- add substitution predicates to body
          let b''' = PAnd $ b'':(concat gtmps)
          return $ And Nothing b''' gchildren

      return $ Or (Just (k,sym)) children

-- generate a disjunctive interpolation query for a query clause
unrollQuery :: Int -> Query -> UnrollM InterpQuery
unrollQuery n (b, c, h) = do
  kcs <- getKClauses
  let initDepths = map (\k -> (k,n)) $ M.keys kcs
  let dmap = foldr (uncurry M.insert) M.empty $ initDepths

  -- rename instances of VV in query, since it's treated specially
  -- in unrolling
  v <- renameSymbol vvName
  newSub vvName v
  let b' = renameExpr vvName v b 
  let c' = map (renameClauseChild vvName v) c
  let h' = renameExpr vvName v h

  -- generate child subtrees
  cinfo <- forM c' $ \(ck,csub,csym) -> do
    (kcs', tmps) <- applySubst csub
    local (setKClauses kcs') $ do
      child <- unroll dmap (ck,csym)
      return (child, tmps)

  let (children, ctmps) = unzip cinfo
  return $ And Nothing (PAnd ([PNot h', b'] ++ (concat ctmps))) children

-- compute the initial rename map for a set of clauses
-- we have to do this smartly; if there is a variable v101, then
-- we have to map v |-> 102
initRenameMap :: UnrollInfo -> RenameMap
initRenameMap _ = M.empty -- FIXME: IMPLEMENT THIS

-- interface function that unwraps Unroll monad
genInterpQuery :: Int -> UnrollInfo -> Query -> (InterpQuery, SymSorts, UnrollSubs)
genInterpQuery n uinfo query = 
  let rm = initRenameMap uinfo in
  let ustate = (M.empty, rm, M.empty) in
  let smonad = unrollQuery n query in
  let (diquery, (cs,_,us)) = runState (runReaderT smonad uinfo) ustate in
  (diquery, cs, us)

----------------------------------------------------
-- | DISJUNCTIVE INTERPOLATION TO TREE INTERPOLATION
----------------------------------------------------

-- remove OR nodes from AOTree by converting disjunctive interp query
-- to a set of tree interp queries
expandTree :: InterpQuery -> [InterpQuery]
expandTree (And info root children) =
  map (And info root) (sequence $ map expandTree children)
expandTree (Or info children) =
  children >>= expandOr info
  where expandOr info (And _ root children) =
          expandTree (And info root children)
        expandOr _ t = expandTree t

-- generate a tree interp query
-- there shouldn't be an OR node processed in the tree
genQueryFormula :: InterpQuery -> Expr
genQueryFormula (Or _ children) =
  POr (map genQueryFormula children)
genQueryFormula (And _ root children) =
  PAnd $ root:(map genQueryFormula' children)
  where genQueryFormula' c@(And _ _ _) = Interp $ genQueryFormula c
        genQueryFormula' c@(Or _ _) = genQueryFormula c

----------------------------------------
-- | TREE INTERPOLANTS TO KVAR SOLUTIONS
----------------------------------------

popInterp :: State [Expr] Expr
popInterp = do
  (x:xs) <- get
  put xs
  return x

-- construct a tree interpolant from a list of interpolants
-- returned by Z3
genTreeInterp :: InterpQuery -> State [Expr] TreeInterp
genTreeInterp query
  | And info _ [] <- query = do
    interp <- popInterp
    return (And info interp [])

  | And info _ children <- query = do
    ichildren <- forM children genTreeInterp
    interp <- popInterp
    return (And info interp ichildren)

  -- this is for tree interpolants, so we don't
  -- do anything for OR nodes
  | Or info children <- query = do
    ichildren <- forM children genTreeInterp
    return (Or info ichildren)

  | otherwise = return query

-- map a tree interpolant to candidate solutions
-- we do this by substituting the following at an interpolant:
-- * the symbol at the head |--> v (or nu)
-- * sub symbols (e.g. tmp) generated from unrolling |--> original symbol
extractSol :: Subst -> TreeInterp -> CandSolutions
extractSol usubs t =
  let subtree = mapAOTree (\i e -> subUnroll i $ subNu i e) t in 
  collectSol subtree M.empty
  where subUnroll _ = (subst :: Subst -> Expr -> Expr) usubs
        subNu (Just (_, sym)) e =
          flip (subst1 :: Expr -> (Symbol,Expr) -> Expr) (sym,EVar vvName) e
        subNu Nothing e = e
        collectSol (And Nothing _ children) m = 
          foldr collectSol m children
        collectSol (And (Just (k,_)) v children) m =
          let m' = M.insertWith (++) k [v] m in 
          foldr collectSol m' children
        -- this is supposed to be called on tree interps only,
        -- so we set a dummy value for OR nodes
        collectSol (Or _ _) m = m

-- convert number symbols back to integer constants
numberifyCand :: Expr -> Expr
numberifyCand e = V.trans numberifyVisitor () () e
  where numberify _ e'@(EVar s) =
          let mnum = readMaybe (symbolString s) :: Maybe Integer in
          maybe e' (ECon . I) mnum
        numberify _ e' = e'
        numberifyVisitor = nv { V.txExpr = numberify }
        nv = V.defaultVisitor :: V.Visitor () ()

genCandSolutions :: Fixpoint a => FInfo a -> UnrollSubs -> InterpQuery -> IO CandSolutions
genCandSolutions finfo u dquery = do
  -- convert disjunctive interp query to a set of tree interp queries
  let tqueries = expandTree dquery
  tinterps <- forM tqueries $ \tquery -> do
    let sinfo = convertFormat finfo
    interps <- interpolation (def :: Config) sinfo $ genQueryFormula tquery
    let tinterp = evalState (genTreeInterp tquery) $ interps ++ [PFalse]
    return tinterp

  let usubs   = Su $ M.fromList $ map (\(x,orig) -> (x,EVar orig)) $ M.toList u
  let cands   = map (extractSol usubs) tinterps 
  let cands'  = M.toList $ foldr (M.unionWith (++)) M.empty cands
  let cands'' = M.fromList $ map (\(k,exprs) -> (k,map numberifyCand exprs)) cands'
  return cands''

-- generate qualifiers from candidate solutions
-- ss should contain the sorts for
-- * kvars
-- * created variables during unrolling
-- * variables in finfo
extractQualifiers :: SymSorts -> CandSolutions -> [Qualifier]
extractQualifiers ss cs = nub $ concatMap kquals (M.toList cs)
  where kquals (k,es) = map (exprToQual k) (nub $ concatMap atomicExprs es)
        -- get atomic expressions from conjunctions and disjunctions
        -- we want qualifiers to be simple (atomic) predicates
        atomicExprs (PAnd ps) = concatMap atomicExprs ps
        atomicExprs (POr ps) = concatMap atomicExprs ps
        atomicExprs e = [e]
        ksym (KV k) = k
        symSort k s =
          let ksort = maybe intSort id (M.lookup (ksym k) ss) in
          let ssort = maybe intSort id (M.lookup s ss) in
          let sort = if s == vvName then ksort else ssort in
          (s,sort)
        exprToQual k e =
          let syms    = exprSyms e in
          let params  = map (symSort k) syms in
          let loc     = dummyPos "no location" in
          let name    = dummySymbol in
          Q name params e loc

genQualifiers :: Fixpoint a => FInfo a -> Int -> IO [Qualifier]
genQualifiers finfo n = do
  let (ss, kcs, queries) = genUnrollInfo finfo
  putStrLn "KClauses:"
  putStrLn $ show kcs
  quals <- forM queries $ \query -> do
    -- unroll
    let (diquery, cs, usubs) = genInterpQuery n (kcs, ss) query
    putStrLn "Interp query:"
    putStrLn $ show diquery
    putStrLn $ show cs
    putStrLn $ show usubs

    -- add created vars back to finfo
    let vars = toListSEnv (lits finfo)
    let allvars = M.union (M.fromList vars) cs
    let finfo' = finfo { lits = fromListSEnv (M.toList allvars) }

    -- run tree interpolation to compute possible kvar solutions
    candSol <- genCandSolutions finfo' usubs diquery

    -- extract qualifiers 
    return $ extractQualifiers allvars candSol

  return $ nub $ concat quals

{-
imain = do
  let vars = [(symbol "k",intSort),(vvName,intSort),(symbol "s",intSort),(symbol "s2",intSort),(symbol "tmp",intSort),(symbol "tmp2",intSort)]
  -- FInfo, used for generating SMT context (var declarations, etc.)
  let finfo = FI {
                cm = M.empty
              , ws = M.empty
              , bs = emptyBindEnv
              , lits = fromListSEnv vars
              , kuts = KS S.empty
              , quals = []
              , bindInfo = M.empty
              , fileName = ""
              , Language.Fixpoint.Types.allowHO = False
              } :: FInfo ()
  let k = EVar (symbol "k")
  let v = EVar vvName
  let s = EVar (symbol "s")
  let s2 = EVar (symbol "s2")
  let tmp = EVar (symbol "tmp")
  let tmp2 = EVar (symbol "tmp2")
  -- subs from unrolling
  let u = M.fromList [(symbol "tmp",symbol "k"), (symbol "tmp2",symbol "k")]
  -- disjunctive interpolation query
  let root = PNot (PAtom Ge v k)
  let int i = ECon (I i)
  let b3a = And Nothing (PAnd [PAtom Le tmp2 (int 0), PAtom Eq s2 (int 0)]) []
  let b3 = Or (Just (KV (symbol "ksum"),symbol "s2")) [b3a]
  let b2a = And Nothing (PAnd [PAtom Le tmp (int 0), PAtom Eq s (int 0)]) []
  let b2b = And Nothing (PAnd [PAtom Gt tmp (int 0), PAtom Eq s (EBin Plus s2 tmp), PAtom Eq tmp2 (EBin Minus k (int 2))]) [b3]
  let b2 = Or (Just (KV (symbol "ksum"),symbol "s")) [b2a, b2b]
  let b1a = And Nothing (PAnd [PAtom Le k (int 0), PAtom Eq v (int 0)]) []
  let b1b = And Nothing (PAnd [PAtom Gt k (int 0), PAtom Eq v (EBin Plus s k), PAtom Eq tmp (EBin Minus k (int 1))]) [b2]
  let b1 = Or (Just (KV (symbol "ksum"),vvName)) [b1a, b1b]
  let sum = And Nothing root [b1]

  -- get candidate solutions!
  candSol <- genCandSolutions finfo u sum

  forM_ (M.toList $ candSol) $ \(kvar,cands) -> do
    putStrLn $ "Candidates for " ++ (show kvar) ++ ":"
    forM_ (nub cands) (putStrLn . show . smt2)
-}

-- test unrolling
-- k <= 0 ^ v = 0 -> k(v)
-- k > 0 ^ k(s)[k/k-1] ^ v = s + k -> k(v)
imain2 n = do
  let ksym = symbol "k"
  let ssym = symbol "s"
  let vsym = symbol "v"
  let vars = [(ksym,intSort),(vvName,intSort),(ssym,intSort),
              (vsym,intSort)]
  -- FInfo, used for generating SMT context (var declarations, etc.)

  let int i = ECon (I i)
  let ksum = KV (symbol "sum")
  let k = EVar ksym
  let s = EVar ssym
  let v = EVar vvName
  -- let v' = EVar vsym
  let r1 = (PAnd [PAtom Le k (int 0),PAtom Eq v (int 0)], [], ksum)
  let childr2 = [(ksum, Su $ M.fromList [(ksym,EBin Minus k (int 1))], ssym)]
  let r2 = (PAnd [PAtom Gt k (int 0),PAtom Eq v (EBin Plus s k)], childr2, ksum)
  let rules = [r1,r2]
  let kcs = genKClauses rules
  let query = (PTrue, [(ksum, Su $ M.empty, vvName)], PAtom Ge v k)
  let uinfo = (kcs, M.empty)
  let (diquery, cs, usubs) = genInterpQuery n uinfo query
  let finfo = FI {
                cm = M.empty
              , ws = M.empty
              , bs = emptyBindEnv
              , lits = fromListSEnv (vars ++ (M.toList cs))
              , kuts = KS S.empty
              , quals = []
              , bindInfo = M.empty
              , fileName = ""
              , Language.Fixpoint.Types.allowHO = False
              } :: FInfo ()

  putStrLn "KClauses:"
  putStrLn $ "R1 rec?" ++ (show $ isClauseRec rules r1)
  putStrLn $ "R2 rec?" ++ (show $ isClauseRec rules r2)
  putStrLn $ show kcs 

  putStrLn "Created symbols:"
  putStrLn $ show cs
  putStrLn "Substitutions:"
  putStrLn $ show usubs
  -- putStrLn $ show diquery
  forM_ (expandTree diquery) (putStrLn . show)

  -- get candidate solutions!
  candSol <- genCandSolutions finfo usubs diquery

  forM_ (M.toList $ candSol) $ \(kvar,cands) -> do
    putStrLn $ "Candidates for " ++ (show kvar) ++ ":"
    forM_ (nub cands) (putStrLn . show)
