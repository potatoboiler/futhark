{-# LANGUAGE TupleSections #-}
-- | Traverse a body to find memory blocks that can be allocated together.
module Futhark.Pass.RegisterAllocation.Traversal
  ( regAllocFunDef
  , RegAllocResult
  ) where

import System.IO.Unsafe (unsafePerformIO) -- Just for debugging!

import Control.Monad.RWS
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.List as L
import Data.Maybe (isJust, fromMaybe)

import Futhark.Analysis.Alias (analyseFun)
import Futhark.Tools
import Futhark.Representation.AST
--import Futhark.Representation.AST.Traversals
import qualified Futhark.Representation.ExplicitMemory as ExpMem
import Futhark.Pass.ExplicitAllocations()

import qualified Futhark.Pass.MemoryBlockMerging.LastUse as LastUse
import qualified Futhark.Pass.MemoryBlockMerging.Interference as Interference
-- import qualified Futhark.Pass.MemoryBlockMerging.DataStructs as DS

import Futhark.Util (unixEnvironment)
usesDebugging :: Bool
usesDebugging = isJust $ lookup "FUTHARK_DEBUG" unixEnvironment

type RegAllocResult =
  M.Map VName VName -- ^ Mapping from old memory block to new memory block.

type Sizes = M.Map VName SubExp

data Context = Context { ctxInterferences :: Interference.IntrfTab
                       , ctxSizes :: Sizes
                       }
  deriving (Show)

data Current = Current { curUses :: M.Map VName Names
                         -- Mostly used as in a writer monad, but not fully.
                       , curResult :: RegAllocResult
                       }
  deriving (Show)

type TraversalMonad a = RWS Context () Current a

insertUse :: VName -> VName -> TraversalMonad ()
insertUse mem x =
  modify $ \cur -> cur { curUses = M.alter (insertOrNew x) mem $ curUses cur }

insertOrNew :: Ord a => a -> Maybe (S.Set a) -> Maybe (S.Set a)
insertOrNew x m = Just $ case m of
  Just s -> S.insert x s
  Nothing -> S.singleton x

saveRecord :: VName -> VName -> TraversalMonad ()
saveRecord x mem =
    modify $ \cur -> cur { curResult = M.union (M.singleton x mem) $ curResult cur }

withLocalUses :: TraversalMonad a -> TraversalMonad a
withLocalUses m = do
  -- Keep the curResult.
  uses <- gets curUses
  res <- m
  modify $ \cur -> cur { curUses = uses }
  return res

memBlockSizes :: FunDef ExpMem.ExplicitMemory -> Sizes
memBlockSizes fundef = M.union fromParams fromBody
  where fromParams = M.fromList $ concatMap onParam $ funDefParams fundef
        onParam (Param mem (ExpMem.MemMem size _space)) = [(mem, size)]
        onParam _ = []

        fromBody = M.fromList $ concatMap onStm $ bodyStms $ funDefBody fundef
        onStm (Let (Pattern _ [PatElem mem _ _]) ()
               (Op (ExpMem.Alloc size _))) = [(mem, size)]
        onStm stm = foldExp folder [] $ bindingExp stm
        folder = identityFolder
          { foldOnStm = \sizes stm -> return (sizes ++ onStm stm)

          -- Sizes found from the functions below are scope-local, but that does
          -- not matter; we want all sizes so that we can lookup anything.
          , foldOnFParam = \sizes fparam -> return (sizes ++ onParam fparam)
          , foldOnLParam = \sizes lparam -> return (sizes ++ onParam lparam)
          }

regAllocFunDef :: FunDef ExpMem.ExplicitMemory -> RegAllocResult
regAllocFunDef fundef = do
  let fundef_aliases = analyseFun fundef
      lutab = LastUse.lastUseFun fundef_aliases
      interferences = Interference.intrf $ snd $ Interference.intrfAnFun lutab fundef_aliases
      sizes = memBlockSizes fundef
      context = Context lutab sizes
      current_empty = Current M.empty M.empty

      m = regAllocBody $ funDefBody fundef
      result = curResult $ fst $ execRWS m context current_empty

  let debug = interferences `seq` unsafePerformIO $ when usesDebugging $ do
        -- Print interferences.
        replicateM_ 5 $ putStrLn ""
        putStrLn $ replicate 10 '*' ++ " Interferences in "  ++ pretty (funDefName fundef) ++ " " ++ replicate 10 '*'
        putStrLn $ replicate 70 '-'
        forM_ (M.assocs interferences) $ \(stmt_name, interf_names) -> do
          putStrLn $ "Interferences for " ++ pretty stmt_name ++ ":"
          putStrLn $ L.intercalate "   " $ map pretty $ S.toList interf_names
          putStrLn $ replicate 70 '-'

        -- Print results.
        putStrLn $ replicate 70 '-'
        putStrLn "Allocation results!"
        print result
        putStrLn $ replicate 70 '-'

  debug `seq` result

regAllocBody :: Body ExpMem.ExplicitMemory
             -> TraversalMonad ()
regAllocBody (Body () bnds _res) =
  mapM_ regAllocStm bnds

regAllocStm :: Stm ExpMem.ExplicitMemory -> TraversalMonad ()
regAllocStm (Let (Pattern _ patelems) () e) = do
  withLocalUses $ walkExpM walker e

  let creates_new_array = createsNewArrOK e
  when creates_new_array $ mapM_ handleNewArray patelems

  case e of
    DoLoop _mergectxparams mergevalparams _loopform _body -> do
      -- In this case we need to record mappings to a memory block for all
      -- existential loop variables whose initial value maps to that memory
      -- block.
      res_so_far <- curResult <$> get
      let findMem (_, Var y) = M.lookup y res_so_far
          findMem _ = Nothing
          mem_replaces = map findMem mergevalparams

          updateFromReplace (Just mem) x = do
            insertUse mem x
            saveRecord x mem
          updateFromReplace Nothing _ = return ()

      forM_ (zip mem_replaces mergevalparams) $ \(mem_may, (Param x _, _)) ->
        updateFromReplace mem_may x

      forM_ (zip mem_replaces patelems) $ \(mem_may, PatElem x _ _) ->
        updateFromReplace mem_may x

      let debug = unsafePerformIO $ when usesDebugging $ print mergevalparams
      debug `seq` return ()
    _ -> return ()

  let debug = unsafePerformIO $ when usesDebugging $ do
        putStrLn $ replicate 70 '-'
        putStrLn "Statement."
        print patelems
        putStrLn $ replicate 70 '-'

  debug `seq` return ()

  where walker = identityWalker { walkOnBody = regAllocBody }

handleNewArray :: PatElem ExpMem.ExplicitMemory -> TraversalMonad ()
handleNewArray (PatElem x _bindage (ExpMem.ArrayMem _ _ _ xmem _)) = do
  uses <- curUses <$> get
  x_interferences <- (fromMaybe S.empty . M.lookup x . ctxInterferences) <$> ask
  sizes <- ctxSizes <$> ask

  let notTheSame :: (VName, Names) -> Bool
      notTheSame (kmem, _vars) = kmem /= xmem

  let noneInterfere :: (VName, Names) -> Bool
      noneInterfere (_kmem, vars) = S.null $ S.intersection vars x_interferences

  let sizesMatch :: (VName, Names) -> Bool
      sizesMatch (kmem, _vars) = equalSizeSubExps (sizes M.! kmem) (sizes M.! xmem)

  let debug = unsafePerformIO $ when usesDebugging $ do
        putStrLn $ replicate 70 '-'
        putStrLn "Handle new array."
        print x
        print xmem
        print uses
        print sizes
        putStrLn $ replicate 70 '-'

  let canBeUsed t = notTheSame t && noneInterfere t && sizesMatch t

  case L.find canBeUsed $ M.assocs uses of
    Just (kmem, _vars) -> do
      insertUse kmem x
      saveRecord x kmem
    Nothing ->
      insertUse xmem x

  debug `seq` return ()

handleNewArray _ = return ()

-- FIXME: Less conservative, please.  Would require some more state.
equalSizeSubExps :: SubExp -> SubExp -> Bool
equalSizeSubExps x y =
  let eq = (x == y)

      debug = unsafePerformIO $ when usesDebugging $ do
        putStrLn $ replicate 70 '-'
        putStrLn "Equal sizes?"
        print x
        print y
        putStrLn $ replicate 70 '-'

  in debug `seq` eq

-- FIXME: Generalise the one from DataStructs.
-- watch out for copy and concat
createsNewArrOK :: Exp ExpMem.ExplicitMemory -> Bool
createsNewArrOK (BasicOp Partition{}) = True
createsNewArrOK (BasicOp Replicate{}) = True
createsNewArrOK (BasicOp Iota{}) = True
createsNewArrOK (BasicOp Manifest{}) = True
createsNewArrOK (BasicOp ExpMem.Copy{}) = True
createsNewArrOK (BasicOp Concat{}) = True
createsNewArrOK (BasicOp ArrayLit{}) = True
createsNewArrOK (BasicOp Scratch{}) = True
createsNewArrOK (Op (ExpMem.Inner ExpMem.Kernel{})) = True
createsNewArrOK _ = False
